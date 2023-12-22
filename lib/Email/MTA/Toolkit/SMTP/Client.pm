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
         # If the item got re-queued, don't resolve the promise yet.
         # This happens when the DATA command was successful and the user
         # already supplied the data to send.
         $self->_dispatch_response($q_item)
            unless $q_item == ($self->_pending_request_queue->[0] || 0);
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
      } else {
         ...
      }
   }
   elsif ($command eq 'EHLO' || $command eq 'HELO') {
      if ($code == 250) {
         $self->server_helo($q_item->{message_lines}[0]);
         $self->state('ready');
      } else {
         ...
      }
   }
   elsif ($command eq 'MAIL') {
      if ($code == 250) {
         $self->state('mail');
      } else {
         ...
      }
   }
   elsif ($command eq 'DATA') {
      if ($self->state eq 'mail') {
         if ($code == 354) {
            $self->state('data');
            # if the user already supplied the data, send it now,
            # and re-queue this item.
            if (defined $q_item->{data}) {
               unshift @{$self->_pending_response_queue}, $q_item;
               $q_item->{_write_data_state}= 0;
               $self->_write_data for delete $q_item->{data};
               $self->_write_data_end;
            }
         } else {
            ...
         }
      } elsif ($self->state eq 'data_complete') {
         #if ($code == 250) {
            $self->state('ready');
         #} elsif ($code >= 400) {
         #}
      } else {
         ...
      }
   }
   elsif ($command eq 'QUIT') {
      if ($code == 221) {
         $self->state('quit');
      } else {
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

  $request= $smtp->data();
  $request= $smtp->data($mail_message);

Send the DATA command.  If you supply a C<$mail_message>, it will be held until
a successful response is received for the DATA command and then transmitted as
per the L</write_data> and L</end_data> methods.  In this case, the C<$request>
will not be updated until sending is complete, and the response code will be
the server's response to the completed message.  C<$mail_message> must also be
the complete data to send.

If you do I<not> supply C<$mail_message>, the C<$request> will be updated with
the server's response to your request to send mail, and you need to wait for
that (and have a successful response) before calling C<write_data>.

=item write_data

  $smtp->write_data($text);

Queue additional data or data lines into the obuf, correctly "do-stuffing"
them.  After a successful response to the DATA command, you may begind writing
the message body, but you can't just append it to the C<< io->obuf >> because
the protocol requires you to double any leading C<'.'> characters, and always
use "\r\n" line endings.  This function correctly encodes the data, and keeps
track of the state so that you can write chunks that might break in the middle
of a line of text and still get it encoded correctly.

When you are done writing data, call L</end_data>, which writes the trailing
C<".\r\n"> to signal the end of the data to the server.

If you C<don't> call C<end_data>, this does not call C<< ->io->flush >> and
you should consider whether you want to do that.

All text should be 7-bit ASCII unless you have negotiated 8-bit with the server.

=item end_data

  $smtp->end_data

Call this after the last L</write_data> to indicate the end of the data and
allow the terminating line to be sent.  This also calls C<< ->io->flush >>.

=cut

sub data {
   my $self= shift;
   my $req= $self->send_command(DATA => {});
   if (defined $_[0]) {
      $self->_pending_request_queue->[-1]{data}= shift;
   }
   return $req;
}

sub write_data {
   my $self= $_[0];
   @_ == 2 or croak "Expected a single data parameter";
   $self->state eq 'data'
      or croak "write_data can only be called after sending DATA command";
   # If there is not a data command on the queue, put one there
   if (@{$self->_pending_request_queue}) {
      my $q_item= $self->_pending_request_queue->[0];
      croak "can't call write_data when another request is queued"
         unless $q_item && defined $q_item->{_write_data_state};
   } else {
      push @{$self->_pending_request_queue}, {
         request => { command => 'DATA' },
         _write_data_state => 0,
      };
   }
   $self->_write_data for $_[1];
   $self;
}

sub end_data {
   my $self= shift;
   $self->state eq 'data'
      or croak "end_data can only be called after sending DATA command";
   my $q_item= $self->_pending_request_queue->[0];
   defined $q_item && defined $q_item->{_write_data_state}
      or croak "end_data can only be called after write_data";
   $self->_write_data_end;
   # If caller wants to see results of this command, create a Response object for them
   if (defined wantarray) {
      my $response_obj= $q_item->{response_obj};
      if (!defined $response_obj) {
         $response_obj= Email::MTA::Toolkit::SMTP::Response->new(%$q_item, protocol => $self);
         weaken($q_item->{response_obj}= $response_obj);
      }
      return $response_obj;
   }
}

sub _write_data {
   my $self= shift;
   # Push data from $_ onto the buffer.
   # If the previous write did not end with a \r\n,
   # the state is recorded in ->{_write_maildata_state}.
   #  0 = start of a new line
   #  1 = within a new line
   #  2 = wrote a \r but not the \n yet
   #  3 = finished
   my $state= $self->_pending_request_queue->[0]{_write_data_state} || 0;
   croak "Can't write more data after finished" if $state > 2;
   pos //= 0;
   while (length > pos) {
      if ($state == 2) {
         /\G \n /xgc; # consume the newline if any
         $self->io->obuf .= "\n";
         $state= 0;
      }
      # common case: complete lines that don't start with dot.
      # match as many as possible all at once.
      if (/\G (?: (?: [^.\r\n] [^\r\n]* )? \r\n )+ /xgc) {
         $self->io->obuf .= $&;
         $state= 0;
      }
      if (length > pos) {
         # something interrupted the regex above:
         # leading dot?
         if ($state == 0 && /\G \. /xgc) {
            $self->io->obuf .= '..';
            $state= 1;
         }
         # now match anything other than a line terminator
         if (/\G [^\r\n]+ /xgc) {
            $self->io->obuf .= $&;
            $state= 1;
         }
         # incomplete line terminator?
         if (/\G \n /xgc) {
            $self->io->obuf .= "\r\n";
            $state= 0;
         } elsif (/\G \r \Z/xgc) {
            $self->io->obuf .= "\r";
            $state= 2;
         }
      }
   }
   $self->_pending_request_queue->[0]{_write_data_state}= $state;
}
sub _write_data_end {
   my $self= shift;
   if ($self->_pending_request_queue->[0]{_write_data_state}) {
      croak "Mail data ended with incomplete line!";
   }
   $self->state('data_complete');
   $self->_pending_request_queue->[0]{_write_data_state}= 3;
   $self->io->obuf .= ".\r\n";
   $self->io->flush;
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
