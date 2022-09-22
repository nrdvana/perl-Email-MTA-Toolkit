package Email::MTA::Toolkit::SMTP;
use Exporter::Extensible -exporter_setup => 1;
use Carp;

=head1 SYNOPSIS

  my $server= Email::MTA::Toolkit::SMTP->new_server;
  my $client= Email::MTA::Toolkit::SMTP->new_client;
  
  # This module doesn't even require a socket!
  # It can talk SMTP and SSL right inside of byte buffers.
  # This leaves you free to use any I/O engine.
  sub do_io {
    $client->io->{rbuf} .= $server->io->{wbuf};
    $server->io->{wbuf}= '';
    $client->process;
    $server->io->{rbuf} .= $client->io->{wbuf};
    $client->io->{wbuf}= '';
    $server->process;
  }
  
  # Highest level API, whole messages
  
  $server->on_message(sub ($self, $mail_msg) {
    use Data::Printer; p $mail_msg;
  });
  my $res= $client->send_message({
    to => ...,      # envelope
    from => ...,    # envelope
    data => $email, # MIME encoded string or Email::MIME 
  });
  do_io while $res->is_pending;
  $res->assert_ok;
  
  # Medium level API, SMTP commands
  
  $server->on_request(sub ($self, $req) {
    my $res= $self->dispatch_request($req);
    if ($req->command eq 'AUTH') {
      $self->data_size_limit(512*1024*1024) if $res->is_success;
    }
    return $res;
  });

  my $res= $client->helo;
  do_io while $res->pending;
  $res->assert_ok;
  $res= $client->mail_from($envelope_sender);
  do_io while $res->pending;
  $res->assert_ok;
  $res= $client->rcpt_to($envelope_recipient);
  do_io while $response->pending;
  $res->assert_ok;
  $res= $client->data($email->as_string);
  do_io while $response->pending;
  $res->assert_ok;
  
  # Low level API, SMTP with manual dispatch
  
  $client->request('HELO client.example.com');
  $server->io->{rbuf} .= $client->io->{wbuf};
  $client->io->{wbuf}= '';
  my $req= $server->parse_request;
  if ($req->command eq 'HELO') {
    $server->respond(250, 'server.example.com Hello client.example.com');
  }
  else {
    $server->dispatch_request($req);
  }
  $client->io->{rbuf} .= $server->io->{wbuf};
  $server->io->{wbuf}= '';
  my $res= $client->parse_response;
  
=cut

our %COMMANDS;

require Email::MTA::Toolkit::SMTP::Request;
our $request_class= 'Email::MTA::Toolkit::SMTP::Request';

sub request_class {
   my $self= shift;
   if (ref $self) {
      $self->{request_class}= shift if @_;
      return $self->{request_class} if $self->{request_class};
      $self= ref $self;
   }
   $self eq __PACKAGE__? $request_class : $self->_get_inherited_class_attr('request_class');
}
sub _get_inherited_class_attr {
   my ($class, $attr)= @_;
   for (@{ mro::get_linear_isa($class) }) {
      no strict 'refs';
      return ${"${class}::$attr"} if defined ${"${class}::$attr"};
   }
   return undef;
}

sub new_request {
   my $self= shift;
   return $self->request_class->new(protocol => $self, %{ $_[0] });
}

=head1 PARSE FUNCTIONS

Each of these functions operates on C<$_> starting at C<pos($_)> (using the \G
feature of the regex engine).  The first argument must be a class, where related
parse methods can be found.

=head2 parse_cmd_if_complete

  for ($buffer) { my $out= $class->parse_cmd_if_complete }

If the buffer C<$_> from C<pos> does not contain a '\n' character, assume the
command is incomplete and return C<undef> instead of an error.  Else parse the
command and return a hashref, where errors are reported as C<< $result->{error} >>.

=cut

sub parse_cmd_if_complete {
   my $class= shift;
   return undef unless /\G((\S*).*?(\r?\n))/gc;
   my ($line, $cmd, $eol)= ($1, uc $2, $3);
   my $ret;
   if (my $m= $class->can("parse_cmd_$cmd")) {
      $ret= $class->$m for $line;
   } else {
      $ret= { error => qq{500 Unknown command "$cmd"} };
   }
   push @{$ret->{warnings}}, 'Missing CR at end of line'
      unless $eol eq "\r\n";
   return $ret;
}

=head2 parse_domain

Match C<$_> from C<pos> vs. the RFC 5321 specification of a 'Domain', returning
the domain on a match, or undef otherwise.

=cut

sub parse_domain {
   /\G( \w[-\w]* (?: \. \w[-\w]* )* )/gcx? $1 : undef;
}

=head2 parse_host_addr

Match C<$_> from C<pos> vs. the RFC 5321 specification of literal IP address
notation in '[]' brackets.  Returns the address including brackets on success,
or undef on failure.

=cut

sub parse_host_addr {
   # TODO: implement a proper parse that fails on errors
   /\G (\S+) /gcx? $1 : undef;
}

=head2 parse_forward_path

Match C<$_> from C<pos> vs. the RFC 5321 specification for the 'forward-path'
of the RCPT command.  Returns an arrayref of the path components on success,
or undef on mismtch.

=cut

sub parse_forward_path {
   my $self= shift;
   my @path;
   /\G < /gcx or return undef;
   if (/\G \@ /gcx && defined(my $d= $self->parse_domain)) {
      push @path, $d;
      while (/\G ,\@ /gcx && defined($d= $self->parse_domain)) {
         push @path, $d;
      }
      /\G : /gcx or return undef;
   }
   my $m= $self->parse_mailbox
      or return undef;
   /\G > /gcx or return undef;
   push @path, $m;
   return \@path;
}

=head2 parse_reverse_path

Match C<$_> from C<pos> vs. the rFC 5321 specification for the 'reverse-path'
of the MAIL command.  (this is the same as the forward-path except it may be
an empty list, returning an empty arrayref).

=cut

sub parse_reverse_path {
   my $self= shift;
   /\G <> /gcx? [] : $self->parse_forward_path
}

=head2 parse_mail_parameters

Match C<$_> from C<pos> vs. the RFC 5321 specification for the "esmtp mail
parameters" which are optional arguments to the MAIL and RCPT commands.

Returns a hashref of C<< { name => value } >> where value is undef for
parameters lacking an equal sign.  Returns undef on a parse error.

=cut

sub parse_mail_parameters {
   # TODO: implement this as a proper parse that fails on errors
   { map { my $p= index $_, '='; $p > 0? (substr($_,0,$p) => substr($_,$p+1)) : ($_ => undef) } split / /, substr($_, pos) }
}

sub format_mail_parameters {
   my ($self, $p)= @_;
   join ' ', map { defined $p->{$_}? "$_=$p->{$_}" : "$_" } keys %$p;
}
*parse_rcpt_parameters= *parse_mail_parameters;
*format_rcpt_parameters= *format_mail_parameters;
sub parse_mailbox {
   # TODO
   /\G( \S+ \@ \w[-\w]* (?: \. \w[-\w]* )* )/gcx? $1 : undef;
}

=head2 format_cmd

=cut

sub format_cmd {
   my ($self, $req)= @_;
   my $m= $self->can("format_cmd_$req->{command}")
      or croak "Don't know how to format a $req->{command} message";
   $m->($self, $req);
}

=head1 COMMANDS

=head2 EHLO

The modern session-initiation command.

=over

=item parse_cmd_EHLO

Returns a hash of C<< { command => 'EHLO', host => $host } >>

=item format_cmd_EHLO

=back

=cut

sub parse_cmd_EHLO {
   my $self= shift;
   my $host;
   /\GEHLO /gci
   && defined($host= ($self->parse_host_addr // $self->parse_domain))
   && /\G *(?=\r?\n)/gc
      or return { error => "500 Invalid EHLO syntax" };
   return { command => 'EHLO', host => $host }
}

sub format_cmd_EHLO {
   "EHLO ".$_[1]{host};
}

=head2 HELO

The classic session-initiation command.  Servers must still support it,
but all clients should use EHLO.

=over

=item parse_cmd_HELO

Returns a hash of C<< { command => 'HELO', host => $host } >>

=item format_cmd_EHLO

=back

=cut

sub parse_cmd_HELO {
   my $self= shift;
   my $host;
   /\GHELO /gci
   && defined($host= $self->parse_domain)
   && /\G *(?=\r?\n)/gc
      or return { error => "500 Invalid HELO syntax" };
   return { command => 'HELO', host => $host }
}

sub format_cmd_HELO {
   "HELO ".$_[1]{host};
}

=head2 MAIL

  "MAIL FROM:" Reverse-path [SP Mail-parameters] CRLF

L<https://datatracker.ietf.org/doc/html/rfc5321#section-4.1.1.2>

Declare the envelope sender of the message.

=over

=item mail_from

  $request= $smtp->mail_from($mailbox, \%parameters);
  $request= $smtp->mail_from(\@path, \%parameters);

Shortcut for calling L</send_command>.

=item format_cmd_MAIL

Returns the canonical MAIL command string (without CRLF) from a hashref.

=item parse_cmd_MAIL

Parses C<$_> from C<pos>.
Returns a hashref of C<< { command => 'MAIL', path => \@path, parameters => \%params } >>.
C<parameters> are C<undef> if not present.

=item handle_cmd_MAIL

If not in one of the valid states, it returns a 503 reply.
It sets the C<from> attribute and clears the C<to> attribute
and C<data> file handle, then returns a 250 reply.

=back

=cut

$COMMANDS{MAIL}= {
   states => { session => 1 },
};

sub mail_from {
   my ($self, $path, $parameters)= @_;
   $path= [ $path ] unless ref $path eq 'ARRAY';
   $self->send_command({ command => 'MAIL', path => $path, parameters => $parameters });
}

sub parse_cmd_MAIL {
   my $self= shift;
   my ($path, $params);
   /\GMAIL FROM:/gci
   && defined($path= $self->parse_reverse_path)
   && (!/\G *(?=\S)/gc || ($params= $self->parse_mail_parameters))
   && /\G *(?=\r?\n)/gc
      or return { error => [ 500, "Invalid MAIL syntax" ] };
   return { command => 'MAIL', path => $path, parameters => $params }
}

sub format_cmd_MAIL {
   my $self= shift;
   my ($path,$params)= @{$_[0]}{'path','parameters'};
   $path= join ',', @$path if ref $path eq 'ARRAY';
   !$params || !keys %$params? "MAIL FROM:<$path>"
      : "MAIL FROM:<$path> ".$self->format_mail_parameters($params)
}

sub handle_cmd_MAIL {
   my ($self, $command)= @_;
   return [ 503, "Bad sequence of commands" ]
      unless $self->commands->{MAIL}{states}{$self->state};
   $self->from($command->{path});
   $self->to([]);
   $self->data(undef);
   return [ 250, 'OK' ];
}

=head2 RCPT

  "RCPT TO:" ( "<Postmaster@" Domain ">" / "<Postmaster>" /
               Forward-path ) [SP Rcpt-parameters] CRLF

L<https://datatracker.ietf.org/doc/html/rfc5321#section-4.1.1.3>

Declare another recipient for the current message.

=over

=item rcpt_to

  $request= $smtp->rcpt_to($mailbox, \%parameters);
  $request= $smtp->rcpt_to(\@path, \%parameters);

Shortcut for calling L</send_command>.

=item format_cmd_RCPT

Returns the canonical RCPT command string (without CRLF) from a hashref.

=item parse_cmd_RCPT

Parses C<$_> from C<pos>.
Returns a hashref of C<< { command => 'RCPT', path => \@path, parameters => \%params } >>.
C<parameters> are C<undef> if not present.

=item handle_cmd_RCPT

If not in one of the valid states, it returns a 503 reply.
It pushes the new path onto the C<to> attribute, then returns a 250 reply.

=cut

sub rcpt_to {
   my ($self, $path, $params)= @_;
   $path= [ $path ] unless ref $path eq 'ARRAY';
   $self->send_command({ command => 'RCPT', path => $path, parameters => $params });
}

sub parse_cmd_RCPT {
   my $self= shift;
   my ($path, $params);
   /\GRCPT TO:/gci
   && defined($path= $self->parse_forward_path)
   && (!/\G *(?=\S)/gc || ($params= $self->parse_rcpt_parameters))
   && /\G *(?=\r?\n)/gc
      or return { error => "500 Invalid RCPT syntax" };
   return { command => 'RCPT', path => $path, parameters => $params }
}

sub format_cmd_RCPT {
   my $self= shift;
   my ($path, $params)= @{$_[0]}{'path','parameters'};
   $path= join ',', @$path if ref $path eq 'ARRAY';
   !$params || !keys %$params? "RCPT TO:<$path>"
      : "RCPT TO:<$path> ".$self->format_rcpt_parameters($params)
}

sub handle_cmd_RCPT {
   my ($self, $command)= @_;
   return [ 503, 'Bad sequence of commands' ]
      unless $self->commands->{RCPT}{states}{$self->state};
   push @{$self->to}, $command->{path};
   return [ 250, 'OK' ];
}

=head2 QUIT

=over

=item parse_cmd_QUIT

=item format_cmd_QUIT

=back

=cut

sub parse_cmd_QUIT {
   /\GQUIT *(?=\r?\n)/gc
      or return { error => "500 Invalid QUIT syntax" };
   return { command => 'QUIT' }
}
sub format_cmd_QUIT {
   "QUIT";
}

1;
