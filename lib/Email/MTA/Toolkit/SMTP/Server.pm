package Email::MTA::Toolkit::SMTP::Server;
use Moo;
use Carp;
use Log::Any '$log';
use namespace::clean;
extends 'Email::MTA::Toolkit::SMTP::Protocol';

# Use empty hashref as default so that users can apply keywords without
# having to initialize the attribute first.
has '+server_ehlo_keywords' => ( default => sub { +{} } );

has listeners => ( is => 'rw', default => sub { +{} } );

sub handle_io {
   my $self= shift;
   my $forward_progress= 0;
   if ($self->state eq 'connect') {
      # Send the 220 greeting
      $self->send_response(220, $self->greeting);
      $self->state('handshake');
      $forward_progress= 1;
   }
   $self->io->fetch;
   $log->tracef("SMTP Server input buf: '%s'", _dump_buf(substr($self->io->ibuf, $self->io->ibuf_pos)))
      if $log->is_trace && $self->io->ibuf_avail;
   while (1) {
      $self->last_parse_error(undef);
      my $req= $self->parse_command_if_complete($self->io->ibuf);
      # Come back later if it can't parse more because temporarily out of data
      last unless $req || defined $self->last_parse_error || $self->io->ifinal;
      $forward_progress= 1;
      if ($req) {
         $self->handle_command($req);
      } elsif (defined $self->last_parse_error) {
         my @err= ( $self->last_parse_error );
         @err= $err[0]->@* if ref $err[0] eq 'ARRAY';
         unshift @err, 500 unless $err[0] =~ /^[0-9]{3}/;
         $self->send_response(@err);
      } else {
         if ($self->state ne 'quit') {
            $self->send_response(503, 'Unexpected EOF, terminating connection');
            $self->state('abort');
         }
         return 0;
      }
   }
   return $forward_progress;
}

sub send_response {
   my ($self, $code, @message)= @_;
   length $code == 3 or croak("Code must be 3 digits");
   my @lines= map { split /\r?\n/ } @message;
   my $n= length $self->io->obuf;
   $self->io->obuf .= $code . ($_ == $#lines? ' ' : '-') . $lines[$_] . "\r\n"
      for 0..$#lines;
   $log->tracef("SMTP Server out: '%s'", _dump_buf(substr($self->io->obuf, $n)))
      if $log->is_trace;
   $self->io->flush($code == 221 || $code == 421? ('EOF') : ());
   return $code;
}

sub handle_command {
   my ($self, $req)= @_;
   my $cmdinfo= $req->{command_spec} # Anything parsed from the client is guaranteed to have this set.
      || $self->commands->{$req->{command}}
      || croak("Unknown command $req->{command}");
   return $self->send_response(503, "Bad sequence of commands")
      unless $cmdinfo->{states}{$self->state};
   my $handler= $self->can('handle_cmd_'.$req->{command})
      or return $self->send_response(502, "Command not implemented");
   my $res= $self->$handler($req);
   $self->send_response(@$res);
}

=item handle_cmd_EHLO

This sets the C<client_domain> attribute and clears any current transaction,
and runs the C<on_handshake> callback (if set).  Then it returns a 250 reply
including all the keywords in the L</ehlo_keywords> attribute.

=cut

sub handle_cmd_EHLO {
   my ($self, $command)= @_;
   $self->client_helo($command->{domain}) if defined $command->{domain};
   $self->clear_mail_transaction;
   $self->on_handshake->($self, $command) if $self->listeners->{handshake};

   my $domain= $self->server_helo // $self->server_domain
      || (defined $self->server_address && '['.$self->server_address.']')
      || Carp::croak('Must define server_helo, server_domain, or server_address');
   
   my @ret= ( 250, $domain );
   for (sort keys %{ $self->server_ehlo_keywords }) {
      my ($k, $v)= ($_, $self->server_ehlo_keywords->{$_});
      push @ret, join ' ', $_,
         ref $v eq 'ARRAY'? @$v
         : defined $v && length $v? ($v)
         : ();
   }
   return \@ret;
}

=item handle_cmd_HELO

Same as L</handle_cmd_EHLO> but does not reply with L</ehlo_keywords> and does
not fall back to L</server_address> as the HELO domain in the reply.

=cut

sub handle_cmd_HELO {
   my ($self, $command)= @_;
   $self->client_helo($command->domain) if defined $command->domain;
   $self->clear_mail_transaction;
   $self->on_handshake->($self, $command) if $self->listeners->{handshake};

   my $domain= $self->server_helo // $self->server_domain
      || Carp::croak('Must define server_helo or server_domain');
   return ( 250, $domain );
}

=item handle_cmd_MAIL

If not in one of the valid states, it returns a 503 reply.
It sets the C<from> attribute and clears the C<to> attribute
and C<data> file handle, then returns a 250 reply.

=cut

sub handle_cmd_MAIL {
   my ($self, $command)= @_;
   $self->from($command->{path});
   $self->to([]);
   $self->data(undef);
   return [ 250, 'OK' ];
}

=item handle_cmd_RCPT

If not in one of the valid states, it returns a 503 reply.
It pushes the new path onto the C<to> attribute, then returns a 250 reply.

=cut

sub handle_cmd_RCPT {
   my ($self, $command)= @_;
   return [ 503, 'Bad sequence of commands' ]
      unless $self->commands->{RCPT}{states}{$self->state};
   push @{$self->to}, $command->{path};
   return [ 250, 'OK' ];
}

=item handle_cmd_DATA

If there is a sender and at least one recipient, this changes the server state
to 'data', and sends a 354 response.  Else it returns an appropriate error code.
State 'data' changes from parsing commands to parsing data lines
(L</parse_data>, L</handle_data>, L</handle_data_end>).

=cut

sub handle_cmd_DATA {
   my $self= shift;
   @{$self->mail_transaction->{recipients}}
      or return [ 503, 'Require RCPT before DATA' ];
   $self->state('data');
   return [ 354, 'Start mail input; end with <CRLF>.<CRLF>' ]
}

=item handle_cmd_QUIT

This sends a shutdown request on the IO output handle.

=cut

sub handle_cmd_QUIT {
   my $self= shift;
   $self->state('quit');
   return [ 221, 'Goodbye' ]
}

=item handle_data

Takes the result of 'parse_data' and copies segments of the buffer into a
scalar if they are smaller than the "message_in_mem_limit", or writes them
out to a temporary file handle if they are greater than that limit.
The scalar or data handle are stored at C<< $smtp->mail_transaction->{data} >>.

=item handle_data_end

Upon completion of receiving the data, this method is called, and in turn
calls the on_data_end callback (if any).  It then assumes the transaction is
complete, and calls L</handle_mail_transaction>.

=item handle_mail_transaction

This first calls the on_message calback, which may return a response.  If it
doesn't (or no callback is set) this returns an error code that the message was
not accepted.  It also clears the L</mail_transaction> attribute and changes
the state from 'mail' to 'ready', before returning.

The user of this module must either supply a L</on_message> callback, or override
the return value of this method in order to accept any mail.

=cut

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
