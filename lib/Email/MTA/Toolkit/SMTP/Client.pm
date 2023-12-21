package Email::MTA::Toolkit::SMTP::Client;
use Moo;
use Carp;
use Scalar::Util 'weaken';
use Email::MTA::Toolkit::SMTP::EnvelopeRoute;
use Email::MTA::Toolkit::SMTP::Response;
use Log::Any '$log';
extends 'Email::MTA::Toolkit::SMTP::Protocol';
use namespace::clean;

=head1 METHODS

=head2 send_command

  my $response= $client->send_command($verb, \%parameters);

This writes a command onto the output buffer.  The command must be listed in the
L</commands> set.  On a blocking I/O target, this method blocks until the command is
written and the response is read.  On a nonblocking I/O target, this immediately
returns a Response object which is (most likely) empty and will be filled later when
the event loop receives a response.  Use C<< $response->pending >> to check the status,
or C<< $response->then(...) >> to hook into the event of it being filled.

=cut

sub send_command {
   my ($self, $verb, $params)= @_;
   my $cmdinfo= $self->commands->{uc $verb}
      or croak "Unknown command '$verb'";
   $cmdinfo->{states}{$self->state}
      or croak "Can't call command $verb in state ".$self->state;
   my $req= { command => $verb, %$params };
   my $n= length $self->io->obuf;
   $self->io->obuf .= $self->render_command($req);
   $log->tracef("SMTP Client out: '%s'", _dump_buf(substr($self->io->obuf, $n)))
      if $log->is_trace;
   $self->io->flush;
   my $q_item= { request => $req };
   push $self->_pending_request_queue->@*, $q_item;
   $self->handle_io;
   # If caller wants to see results of this command, create a Response object for them
   if (defined wantarray) {
      my $response_obj= Email::MTA::Toolkit::SMTP::Response->new(%$q_item, protocol => $self);
      # If the response is pending, link the internal record to the external object
      # so that it can be updated on completion.
      if (!defined $q_item->{code}) {
         weaken($q_item->{response_obj}= $response_obj);
      }
      return $response_obj;
   }
}

has _pending_request_queue => ( is => 'rw', default => sub { [
   # Expect the initial server 220 response to the connection itself.
   { request => undef },
]});

=head2 handle_io

  $progress= $client->handle_io;

Try parsing command responses from the I/O buffer and return true if there were one or more
responses (or errors) generated.  False means that there isn't enough data in the buffer to
continue, and you should return to a wait loop for more data to arrive.

=cut

sub handle_io {
   my $self= shift;
   my $forward_progress= 0;
   if ($self->_pending_request_queue->@*) {
      $self->io->fetch;
      $log->tracef("SMTP Client input buf: '%s'", _dump_buf(substr($self->io->ibuf, $self->io->ibuf_pos)))
         if $log->is_trace && $self->io->ibuf_avail;
      while ($self->_pending_request_queue->@*) {
         $self->last_parse_error(undef);
         my $res= $self->parse_response_if_complete($self->io->ibuf);
         # Come back later if it can't parse more because temporarily out of data
         last if !$res && !defined $self->last_parse_error && !$self->io->ifinal;
         # Else we will resolve at least one command
         $forward_progress= 1;
         my $q_item= shift $self->_pending_request_queue->@*;
         if ($res) {
            %$q_item= (%$q_item, %$res);
         } elsif (defined $self->last_parse_error) {
            $q_item->{error}= $self->last_parse_error;
         } else {
            $q_item->{error}= 'Unexpected end of stream';
         }
         $self->_update_state_after_response($q_item);
         $self->_dispatch_response($q_item);
      }
   }
   if ($self->io->ifinal && !$self->io->ibuf_avail) {
      # TODO: handle termination of connection
      $self->state('abort');
   }
   return $forward_progress;
}

sub _update_state_after_response {
   my ($self, $q_item)= @_;
   my $command= $q_item->{request}? $q_item->{request}{command} : undef;
   my $code= $q_item->{code};
   # Any command can result in 421 if the server needs to shut down
   if ($code == 421) {
      $self->state('quit');
   }
   elsif (!defined $command) {
      # Response to connection (no command sent yet)
      if ($code == 220) {
         $self->state('handshake');
         $self->greeting(join "\n", $q_item->{message_lines}->@*);
      }
      else {
         ...
      }
   }
   elsif ($command eq 'EHLO' || $command eq 'HELO') {
      if ($code == 250) {
         $self->server_helo($q_item->{message_lines}[0]);
         $self->state('ready');
      }
      else {
         ...
      }
   }
}

sub _dispatch_response {
   my ($self, $q_item)= @_;
   # If caller is watching objects we gave them, update those objects
   if (defined $q_item->{response_obj} || defined $q_item->{promise}) {
      my $response_obj= delete $q_item->{response_obj};
      if (defined $response_obj) {
         $response_obj->code($q_item->{code});
         $response_obj->message_lines($q_item->{message_lines});
      } else {
         $response_obj= Email::MTA::Toolkit::SMTP::Response->new($q_item);
      }
      # in case someone subclasses this, provide access to the same response
      # object that the promise saw. (now a strong reference)
      $q_item->{response_obj}= $response_obj;
      for (grep defined, $q_item->{promise}, $response_obj->promise) {
         # TODO: check for various types of Future or Promise APIs.
         if ($q_item->{error}) {
            $_->reject($response_obj);
         } else {
            $_->resolve($response_obj);
         }
      }
   }
}

=head1 COMMAND METHODS

These methods send SMTP commands and return a Response object.  The Response will be an
empty placeholder if the socket is nonblocking or an event loop is being used.

=over

=item ehlo

  $request= $server->ehlo($domain); # sets $self->client_helo
  $request= $server->ehlo;          # uses $self->client_helo

=item helo

  $request= $server->ehlo($domain); # sets $self->client_helo
  $request= $server->ehlo;          # uses $self->client_helo

=cut

sub ehlo {
   my ($self, $domain)= @_;
   $domain //= $self->client_helo // $self->client_domain
      || $self->client_address && '['.$self->client_address.']'
      || croak("EHLO command requires domain parameter, or 'client_helo', 'client_domain', or 'client_address' attribute");

   my $ret= $self->send_command(EHLO => { domain => $domain });
   $self->client_helo($domain);
   return $ret;
}

sub helo {
   my ($self, $domain)= @_;
   $domain //= $self->client_helo // $self->client_domain
      || $self->client_address && '['.$self->client_address.']'
      || croak("HELO command requires domain parameter, or 'client_helo', 'client_domain', or 'client_address' attribute");

   my $ret= $self->send_command(HELO => { domain => $domain });
   $self->client_helo($domain);
   return $ret;
}

=item mail_from

  $request= $smtp->mail_from($mailbox);
  $request= $smtp->mail_from($envelope_route);

Shortcut for calling L</send_command>.

=cut

sub mail_from {
   my ($self, $envelope_route)= @_;
   $envelope_route= Email::MTA::Toolkit::SMTP::EnvelopeRoute->coerce($envelope_route);
   $self->send_command(MAIL => { from => $envelope_route });
}

=item rcpt_to

  $request= $smtp->rcpt_to($mailbox);
  $request= $smtp->rcpt_to($envelope_route);

Shortcut for calling L</send_command>.

=cut

sub rcpt_to {
   my ($self, $envelope_route)= @_;
   $envelope_route= Email::MTA::Toolkit::SMTP::EnvelopeRoute->coerce($envelope_route);
   $self->send_command(RCPT => { to => $envelope_route });
}

=item data

  $request= $smtp->data($text);
  $request= $smtp->data(\$text);
  $request= $smtp->data($filehandle);
  $request= $smtp->data(\@lines);

Send the DATA command.  Arguments will be queued like from the L</more_data>
command, but no data lines will be sent until the server replies a 354
"continue" response to the DATA command.  After the data transfer is complete,
the C<$request> gets updated again with either a success or failure reply.

If you supply data arguments to this method, it is assumed they hold the
complete data, and you cannot then call L</more_data> or L</end_data>.

=item more_data

  $smtp->more_data($text);
  $smtp->more_data(\$text);
  $smtp->more_data($filehandle);
  $smtp->more_data(\@lines);

Queue additional data or data lines.

Parameters of C<$text> or C<\$text> are treated as a buffer.  The buffer is
split on "\n", and all lines get "upgraded" to "\r\n" line endings.

A parameter of C<$filehandle> gets read and split like a literal data buffer.

An arrayref parameter gets treated as individual text lines, where each line
is upgraded to end with "\r\n" (even if it had no previous line ending) and
occurrence of "\n" or "\r" anywhere in the middle of the string is an error.

All strings should be 7-bit ascii, unless an 8-bit extension was negotiated.

=item end_data

  $smtp->end_data

Call this after the last L</more_data>, to indicate the end of the data and
allow the terminating line to be sent.

=cut

sub data {
   my $self= shift;
   my $req= $self->send_command({ command => 'DATA' });
   if (@_) {
      $self->more_data(@_);
      $self->end_data;
   }
   return $req;
}

sub more_data {
   my $self= shift;
   $self->state eq 'data'
      or croak "more_data can only be called after sending DATA command";
   if (@_ == 1 && (!ref $_[0] || ref $_[0] eq 'SCALAR')) {
      push @{$self->mail_transaction->{data_queue}}, $_[0];
   } elsif (@_ == 1 && ref $_[0] eq 'ARRAY') {
      my @data= @{$_[0]};
      for (@data) {
         /[\r\n]./ and croak "Embedded newline in lines of text";
         s/\r?\n?$/\r\n/
      }
      push @{$self->mail_transaction->{data_queue}}, join '', @data;
   } else {
      croak "Too many arguments to more_data: ".scalar(@_) if @_ > 1;
      croak "Unhandled more_data arguments  (@_)";
   }
}

sub end_data {
   my $self= shift;
   $self->state eq 'data'
      or croak "end_data can only be called after sending DATA command";
   $self->mail_transaction->{data_complete}= 1;
}

=item quit

  $smtp->quit

Gracefully terminate the session.  This sends the command then shuts down writes
on the socket, then the server writes the response and also shuts down its write-end,
then the socket is closed by both.

=back

=cut

sub quit {
   my $self= shift;
   my $req= $self->send_command(QUIT => {});
   $self->io->flush('EOF');
   return $req;
}

sub _dump_buf {
   my $buf= shift;
   $buf =~ s/([\0-\x1F\\\x7F-\xFF])/
      $1 eq "\n"? "\\n"
      : $1 eq "\r"? "\\r"
      : $1 eq "\t"? "\\t"
      : $1 eq "\\"? "\\\\"
      : sprintf("\\x%02X", ord $1)
      /ge;
   $buf;
}

1;
