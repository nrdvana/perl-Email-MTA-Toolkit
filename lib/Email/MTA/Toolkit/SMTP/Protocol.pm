package Email::MTA::Toolkit::SMTP;
use Moo;
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

has state                => ( is => 'rw', default => '' );
has io                   => ( is => 'rw' );
has server_domain        => ( is => 'rw' );
has server_address       => ( is => 'rw' );
has server_helo          => ( is => 'rw' );
has server_ehlo_keywords => ( is => 'rw' );
has client_domain        => ( is => 'rw' );
has client_address       => ( is => 'rw' );
has client_helo          => ( is => 'rw' );
has mail_transaction     => ( is => 'rw', clearer => 1, lazy => 1, default => sub { +{} } );

has line_length_limit  => ( is => 'rw', default => 1000 );
has message_size_limit => ( is => 'rw', default => 10*1024*1024 );
has recipient_limit    => ( is => 'rw', default => 1024 );

our %COMMANDS;

=head1 RELATED OBJECTS

Parts of the SMTP protocol can be wrapped with objects, for the higher level APIs,
such as requests and responses.  These wrapper objects refer back to the SMTP
instance to perform any protocol-related work.  The SMTP object has attributes
to configure which class gets used for the wrapper objects.

=head2 Request

This object wraps a command sent from client to server.
See L<Email::MTA::Toolkit::SMTP::Request>.

=over

=item request_class

The name of the class to create for Requests.
This is both a read-only class attribute and a read/write instance attribute.

=item new_request

  ->new_request( \%attributes );
  ->new_request( %attributes );
  ->new_request( $protocol_line );

This is a convenient way to create Request objects.  When given %attributes,
it is just a short-hand for C<< $smtp->request_class->new(...) >>.  When given
a C<$protocol_line> it first parses the line (dying if the parse fails) and
then uses the attributes from the parse.  Unlike the parse methods, this does
not modify the caller's buffer.

=back

=cut

require Email::MTA::Toolkit::SMTP::Request;
sub _build_request_class { 'Email::MTA::Toolkit::SMTP::Request' }

sub request_class {
   my $self= shift;
   if (ref $self) {
      $self->{request_class}= shift if @_;
      return $self->{request_class} ||= $self->_build_request_class;
   } else {
      croak "Read-only accessor" if @_;
      no strict 'refs';
      ${"${self}::request_class"} ||= $self->_build_request_class;
   }
}

sub new_request {
   my $self= shift;
   my @attrs= @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]}
      # Convenience helper: passing a single string means to parse that string.
      : @_ == 1 && !ref $_[0]? do {
         my $line= shift;
         $line .= "\n" unless $line =~ /\n\Z/;
         my $req= $self->parse_cmd_if_complete($line);
         croak "Failed to parse command: ".$req->{error}
            if defined $req->{error};
         %$req;
      }
      : @_;
   $self->request_class->new(@attrs, protocol => $self);
}

=head2 Response

This object wraps a reply sent from server to client.
See L<Email::MTA::Toolkit::SMTP::Response>.

=over

=item response_class

The name of the class to use for wrapping Responses.
This is both a read-only class attribute and a read/write instance attribute.

=item new_response

  ->new_response( \%attributes );
  ->new_response( %attributes );
  ->new_response( $code, @messages );

This is a convenient way to create Response objects.  When given %attributes,
it is just a short-hand for C<< $smtp->response_class->new(...) >>.  When given
a C<$code> and C<@messages>, these are used as the C<code> and C<messages>
attributes.

=back

=cut

require Email::MTA::Toolkit::SMTP::Response;
sub _build_response_class { 'Email::MTA::Toolkit::SMTP::Response' }

sub response_class {
   my $self= shift;
   if (ref $self) {
      $self->{response_class}= shift if @_;
      return $self->{response_class} ||= $self->_build_response_class;
   } else {
      croak "Read-only accessor" if @_;
      no strict 'refs';
      ${"${self}::response_class"} ||= $self->_build_response_class;
   }
}

sub new_response {
   my $self= shift;
   my @attrs= @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]}
      : @_ > 0 && length($_[0]) == 3 && $_[0] =~ /[0-9]{3}/? ( code => $_[0], messages => [ @_[1..$#_] ] )
      : @_;
   $self->response_class->new(@attrs, protocol => $self);
}

=head1 PARSE METHODS

Each of these class methods operates on C<$_> starting at C<pos($_)>
(using the \G feature of the regex engine).
They modify the C<pos> of C<$_>, allowing you to continue parsing a
buffer without modifying it.

=head2 parse_cmd_if_complete

  for ($buffer) { my $out= $class->parse_cmd_if_complete }
  # or
  my $out= $class->parse_cmd_if_complete($buffer);

If the buffer C<$_> from C<pos> does not contain a '\n' character, assume the
command is incomplete and return C<undef> instead of an error.  Else parse the
command and return a hashref, where errors are reported as C<< $result->{error} >>.

=cut

sub parse_cmd_if_complete {
   my $self= shift;
   if (@_) {
      # Function operates on $_, not @_, but be nice to callers who try
      # to pass the buffer as an argument.
      return $self->parse_cmd_if_complete for $_[0];
   }
   return undef unless /\G( (\S*) \  (.*?) (\r?\n) )/gcx;
   my ($line, $cmd, $args, $eol)= ($1, uc $2, $3, $4);
   my $ret;
   if (ref $self) {
      my $cmdinfo= $self->commands->{$cmd}
         or return {
            error => $self->can("parse_cmd_args_$cmd")
               ? [ 502, qq{Unimplemented} ]
               : [ 500, qq{Unknown command "$cmd"} ]
         };
      my $m= $cmdinfo->{parse} || $class->can("parse_cmd_args_$cmd");
      $ret= $self->$m($args) for $args;
   } else {
      if (my $m= $self->can("parse_cmd_args_$cmd")) {
         $ret= $self->$m($args) for $args;
      } else {
         $ret= { error => [ 500, qq{Unknown command "$cmd"} ] };
      }
   }
   $ret->{command}= $cmd;
   $ret->{original}= $line;
   push @{$ret->{warnings}}, 'Missing CR at end of line'
      unless $eol eq "\r\n";
   return $ret;
}

=head2 parse_domain

Class method.
Match C<$_> from C<pos> vs. the RFC 5321 specification of a 'Domain', returning
the domain on a match, or undef otherwise.

=cut

sub parse_domain {
   /\G( \w[-\w]* (?: \. \w[-\w]* )* )/gcx? $1 : undef;
}

=head2 parse_host_addr

Class method.
Match C<$_> from C<pos> vs. the RFC 5321 specification of literal IP address
notation in '[]' brackets.  Returns the address including brackets on success,
or undef on failure.

=cut

sub parse_host_addr {
   # TODO: implement a stricter parse
   /\G( \[ (?:
      [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+    # ipv4
      | [0-9A-Fa-f]*:[0-9A-Fa-f:]+      # ipv6
   ) \] )/gcx? $1 : undef;
}

sub parse_domain_or_host_addr {
   /\G(?=\[)/gc? $_[0]->parse_host_addr : $_[0]->parse_domain
}

=head2 parse_forward_path

Class method.
Match C<$_> from C<pos> vs. the RFC 5321 specification for the 'forward-path'
of the RCPT command.  Returns an arrayref of the path components on success,
or undef on mismtch.

=cut

sub parse_forward_path {
   my $class= shift;
   my @path;
   /\G < /gcx or return undef;
   if (/\G \@ /gcx && defined(my $d= $class->parse_domain)) {
      push @path, $d;
      while (/\G ,\@ /gcx && defined($d= $class->parse_domain)) {
         push @path, $d;
      }
      /\G : /gcx or return undef;
   }
   my $m= $class->parse_mailbox
      or return undef;
   /\G > /gcx or return undef;
   push @path, $m;
   return \@path;
}

=head2 parse_reverse_path

Class method.
Match C<$_> from C<pos> vs. the rFC 5321 specification for the 'reverse-path'
of the MAIL command.  (this is the same as the forward-path except it may be
an empty list, returning an empty arrayref).

=cut

sub parse_reverse_path {
   my $class= shift;
   /\G <> /gcx? [] : $class->parse_forward_path
}

=head2 parse_mail_parameters

Class method.
Match C<$_> from C<pos> vs. the RFC 5321 specification for the "esmtp mail
parameters" which are optional arguments to the MAIL and RCPT commands.

Returns a hashref of C<< { name => value } >> where value is undef for
parameters lacking an equal sign.  Returns undef on a parse error.

=cut

sub parse_mail_parameters {
   # TODO: implement this as a proper parse that fails on errors
   { map {
      my $p= index $_, '=';
      $p > 0? (substr($_,0,$p) => substr($_,$p+1))
         : ($_ => undef)
   } split / /, substr($_, pos) }
}

sub render_mail_parameters {
   my ($class, $p)= @_;
   join ' ', map { defined $p->{$_}? "$_=$p->{$_}" : "$_" } keys %$p;
}
*parse_rcpt_parameters= *parse_mail_parameters;
*render_rcpt_parameters= *render_mail_parameters;
sub parse_mailbox {
   # TODO
   /\G( \S+ \@ \w[-\w]* (?: \. \w[-\w]* )* )/gcx? $1 : undef;
}

=head2 render_cmd

Return the command as a canonical line of text ending with C<"\r\n">.

=cut

sub render_cmd {
   my ($self, $req)= @_;
   my $cmd= ref $self && $self->commands->{uc $req->{command}};
   my $m= ($cmd? $cmd->{render} : undef)
      || $self->can("render_cmd_$req->{command}")
      or croak "Don't know how to render a $req->{command} message";
   $self->$m($req);
}

=head1 STATES

The SMTP protocol has a 'state' attribute, with the following possible values:

=over

=item C<''>

The empty initial state means nothing has happened yet.  It can transition to
'handshake' or 'reject'.
L<https://datatracker.ietf.org/doc/html/rfc5321#section-3.1>

=item C<'handshake'>

For the server, sending a 220 transitions to 'handshake',
and for the client, receiving 220 transitions to 'handshake'.
The client replies with HELO or EHLO and the server waits for it.
The following state is 'ready'.

=item C<'reject'>

If the server opens communication with an initial 554, this state means the
server has rejected the client, and no commands are allowed except 'QUIT'.

=item C<'ready'>

After the server receives HELO/EHLO and the client receives a '250' reply, both
transition to state 'ready'.  This means mail transactions can begin with the
'MAIL' command.  It also arrives at this state after RSET.

=item C<'mail'>

After the server receives the 'MAIL' command and the client receives the '250'
reply, the state changes to 'mail'.  The client can then send any number of
RCPT commands to build the rest of the envelope address list.  The next state
is 'data'.

=item C<'data'>

After the server receives the 'DATA' command and the client receives the 354
reply, the state changes to 'data'. The command parsing changes here to accept
lines of raw 8-bit with the special "leading dot" terminator.  After the final
line, the server makes a decision whether to accept the mail and the state
transitions back to 'ready' (for a new transaction).

=item C<'quit'>

After the client sends a 'QUIT' command and the server receives it, the state
transitions to 'QUIT' and all further commands are rejected.

=back

=head1 COMMANDS

=head2 EHLO

The modern session-initiation command.  This is allowed in any state except
'reject', 'starttls', 'auth', and 'quit'.

=cut

package Email::MTA::Toolkit::SMTP::Protocol::EHLO {
   use Moo;
   extends 'Email::MTA::Toolkit::SMTP::Request';
   sub states { qw( handshake ready mail data ) }

   has domain  => ( is => 'rw' );

   sub BUILD {
      # If the domain is pure numeric, then it's an address and needs wrapped with []
      if ($_[0]->domain =~ /^(?: [0-9.]+ | [0-9A-Fa-f]*:[0-9A-Fa-f:]+ )$/x) {
         $_[0]->domain('[' . $_[0]->domain . ']');
      }
   }

   sub render {
      'EHLO '.shift->domain
   }
   sub parse_params {
      my $self= shift;
      my $domain= $self->protocol->parse_domain_or_host_addr
         or return { error => [ 501, 'invalid EHLO host' ] };
      /\G *$/gc
         or return { error => [ 501, 'unexpected extra arguments' ] };
      return { domain => $domain };
   }
}

register_command('EHLO');

=head2 HELO

The classic session-initiation command.  Servers must still support it,
but all clients should use EHLO.

=over

=item helo

  $request= $smtp->helo($domain);

Shortcut for calling L</send_command>.

=item render_cmd_HELO

Returns the canonical HELO string (without CRLF) from a hashref.

=item parse_cmd_args_HELO

Returns a hash of C<< { domain => $host } >>

=item handle_cmd_HELO

This sets the C<client_domain> attribute and sets the C<ehlo_keywords>
to an empty hashref, clears any current transaction, and runs the
C<on_handshake> callback (if set).  Then it returns a 250 reply.

=back

=cut

$COMMANDS{HELO}= {
   states => { handshake => 1, ready => 1, mail => 1, data => 1 },
   render => 'render_cmd_HELO',
   parse  => 'parse_cmd_args_HELO',
   handle => 'handle_cmd_HELO',
};

sub helo {
   my ($self, $domain)= @_;
   $self->send_command({ command => 'HELO', domain => $domain });
}

sub render_cmd_HELO {
   "HELO ".$_[1]{host};
}

sub parse_cmd_args_HELO {
   my $self= shift;
   my $domain= $self->parse_domain
      // return { error => [ 501, 'invalid HELO domain' ] };
   /\G *$/gc
      or return { error => [ 501, 'unexpected extra arguments' ] };
   return { domain => $domain }
}

sub handle_cmd_HELO {
   my ($self, $command)= @_;
   $self->client_domain($command->{domain});
   $self->ehlo_keywords({});
   $self->clear_transaction();
   my $ret= $self->call_event('handshake', $command);
   return $ret // [ 250, $self->get_helo_domain ];
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

=item render_cmd_MAIL

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
   states => { ready => 1 },
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

sub render_cmd_MAIL {
   my $self= shift;
   my ($path,$params)= @{$_[0]}{'path','parameters'};
   $path= join ',', @$path if ref $path eq 'ARRAY';
   !$params || !keys %$params? "MAIL FROM:<$path>"
      : "MAIL FROM:<$path> ".$self->render_mail_parameters($params)
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

=item render_cmd_RCPT

Returns the canonical RCPT command string (without CRLF) from a hashref.

=item parse_cmd_RCPT

Parses C<$_> from C<pos>.
Returns a hashref of C<< { command => 'RCPT', path => \@path, parameters => \%params } >>.
C<parameters> are C<undef> if not present.

=item handle_cmd_RCPT

If not in one of the valid states, it returns a 503 reply.
It pushes the new path onto the C<to> attribute, then returns a 250 reply.

=cut

$COMMANDS{MAIL}= {
   states => { mail => 1 },
};

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

sub render_cmd_RCPT {
   my $self= shift;
   my ($path, $params)= @{$_[0]}{'path','parameters'};
   $path= join ',', @$path if ref $path eq 'ARRAY';
   !$params || !keys %$params? "RCPT TO:<$path>"
      : "RCPT TO:<$path> ".$self->render_rcpt_parameters($params)
}

sub handle_cmd_RCPT {
   my ($self, $command)= @_;
   return [ 503, 'Bad sequence of commands' ]
      unless $self->commands->{RCPT}{states}{$self->state};
   push @{$self->to}, $command->{path};
   return [ 250, 'OK' ];
}

=head2 DATA

=over

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

=item render_cmd_DATA

Always returns "DATA\r\n"

=item parse_cmd_DATA

Parses C<$_> from C<pos>, accepting only "DATA\r\n".

=item handle_cmd_DATA

If there is a sender and at least one recipient, this changes the server state
to 'data', and sends a 354 response.  Else it returns an appropriate error code.
State 'data' changes from parsing commands to parsing data lines
(L</parse_data>, L</handle_data>, L</handle_data_end>).

=item parse_data

  $found= $smtp->parse_data_lines($buffer);
  # {
  #   literal_blocks => [ $start_pos, $length, $start_pos2, $length2, ... ],
  #   complete => $bool,
  # }

Inspects a buffer and identifies contiguous strings of data that can be copied
to the output.  The positions and lengths are intended for C<substr($buffer, $pos, $len)>,
or for calls to C<syswrite>.  If the end of data marker is found, this also
sets the 'complete' flag to a true value.

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

=back

=cut

$COMMANDS{DATA}= {
   states => { mail => 1 },
};

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

sub render_cmd_DATA {
   "DATA\r\n";
}

sub parse_cmd_DATA {
   /\GDATA *(?=\r?\n)/gc
      or return { error => "500 Invalid DATA syntax" };
   return { command => 'DATA' };
}

sub handle_cmd_DATA {
   my $self= shift;
   @{$self->mail_transaction->{recipients}}
      or return [ 503, 'Require RCPT before DATA' ];
   $self->state('data');
   return [ 354, 'Start mail input; end with <CRLF>.<CRLF>' ]
}

=head2 QUIT

=over

=item parse_cmd_QUIT

=item render_cmd_QUIT

=back

=cut

sub parse_cmd_QUIT {
   /\GQUIT *(?=\r?\n)/gc
      or return { error => "500 Invalid QUIT syntax" };
   return { command => 'QUIT' }
}
sub render_cmd_QUIT {
   "QUIT";
}

1;
