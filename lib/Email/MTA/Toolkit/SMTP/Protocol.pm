package Email::MTA::Toolkit::SMTP::Protocol;
use v5.36;
use Moo;
use Carp;
use Email::MTA::Toolkit::SMTP::EnvelopeRoute;
use Email::MTA::Toolkit::IO;
use namespace::clean;

=head1 DESCRIPTION

This class acts as a base class for ::SMTP::Server and ::SMTP::Client.  If you look at the
SMTP protocol as a series of commands that conveys client state to a server, the attributes of
this class are the ones that the client wants to write and the server wants to read and have
available for decision making.

For instance, when the client sends EHLO with a domain name, and the server responds to that
command with its own hostname, and list of "keywords" (supported extensions) the client and
server should now have matching values for the L</client_helo>, L</server_helo>, and
L</server_ehlo_keywords> attributes.

Any attribute unrelated to the shared state of the SMTP session live in the respective
::Client or ::Server subclass.

This class also contains all methods related to parsing and formatting commands and responses.

=head1 ATTRIBUTES

=head2 state

The state of the current session.  One of C<''>, C<'handshake'>, C<'reject'>,
C<'ready'>, C<'mail'>, C<'data'>, C<'quit'>.  See L</STATES> for details.

=head2 io

An object implementating both L<Email::MTA::Toolkit::IO::IBuf> and
L<Email::MTA::Toolkit::IO::OBuf>.

=head2 server_domain

DNS name of the server.  This should be populated before the protocol begins.

=head2 server_address

IP Address of the server.  This should be populated before the protocol begins.

=head2 server_helo

Name reported by the server to the client during HELO or EHLO commands.

=head2 server_ehlo_keywords

A hashref of options the server reports to the client during the response to EHLO command.

=head2 client_domain

The DNS name of the client.  This should be populated before the protocol begins.

=head2 client_address

The IP address of the client.  This should be populated before the protocol begins.

=head2 client_helo

Name reported by the client to the server during HELO or EHLO commands.

=head2 mail_transaction

An instance of L<Email::MTA::Toolkit::SMTP::Transaction>, which should be created using
L</new_transaction> in response to the "MAIL" command.

=cut

has state                => ( is => 'rw', default => 'connect' );
has io                   => ( is => 'rw', coerce => \&Email::MTA::Toolkit::IO::coerce_io );
has greeting             => ( is => 'rw', lazy => 1, builder => 1 );
has server_domain        => ( is => 'rw' );
has server_address       => ( is => 'rw' );
has server_helo          => ( is => 'rw' );
has server_ehlo_keywords => ( is => 'rw' );
has client_domain        => ( is => 'rw' );
has client_address       => ( is => 'rw' );
has client_helo          => ( is => 'rw' );
has mail_transaction     => ( is => 'rw', clearer => 1 );

sub _build_greeting {
   my $self= shift;
   "Email::MTA::Toolkit server"
      .($self->server_domain? " on ".$self->server_domain : '')
}

=head2 last_parse_error

The most recent error from one of the parse routines.  This may be a simple string,
or an arrayref where the first element is the SMTP error code.

=cut

has last_parse_error     => ( is => 'rw' );

# conveinence function for setting the error and returning undef
sub _undef_with_err($self, $err) {
   $self->last_parse_error($err);
   undef;
}

# convenience function for prefixing the error with a new string and/or SMTP code
# and returning undef.
sub _undef_prefix_err($self, $err) {
   my $prev= $self->last_parse_error;
   $self->last_parse_error($err);
   my $code= ref $err? $err->[0] : ref $prev? $prev->[0] : undef;
   my $msg= (ref $err? $err->[1] : $err);
   $msg .= ': '.(ref $prev? $prev->[1] : $prev)
      if defined $prev;
   $self->last_parse_error(defined $code? [ $code, $msg ] : $msg);
   undef;
}

=head2 line_length_limit

Configurable limit on command length / data line length.

=head2 message_size_limit

Configurable limit on maximum DATA size before aborting and returning an error.

=head2 recipient_limit

Configurable limit on number of recipient mailboxes for one mail transaction.

=cut

has line_length_limit    => ( is => 'rw', default => 1000 );
has message_size_limit   => ( is => 'rw', default => 10*1024*1024 );
has recipient_limit      => ( is => 'rw', default => 1024 );

=head2 commands

Hashref of available SMTP commands.  This can be modified to remove or add
commands available to a client.  It deefaults to all the commands defined in
this module.

=cut

our %commands;

has commands => ( is => 'lazy' );
sub _build_commands {
   return { %commands };
}

=head1 RELATED OBJECTS

Parts of the SMTP protocol can be wrapped with objects, for the higher level APIs,
such as requests and responses.  These wrapper objects refer back to the Protocol
instance to perform any protocol-related work.  The Protocol object has attributes
to configure which class gets used for the wrapper objects.

=head2 L<Email::MTA::Toolkit::SMTP::Transaction|Transaction>

This object wraps the delivery of one mail message.

=over

=item transaction_class

The name of the class to create for Transactions.

=item new_transaction

  ->new_transaction( %attributes );

Create a new transaction.  This automatically supplies the fields that get copied
from the session (this Protocol object) into the transaction: L</server_domain>,
L</server_address>, L</server_helo>, L</server_ehlo_keywords>, L</client_domain>,
L</client_address>, L</client_helo>.

=back

=cut

sub _build_transaction_class { 'Email::MTA::Toolkit::SMTP::Transaction' }

sub transaction_class {
   my $self= shift;
   my $field= \$self->{transaction_class};
   if (@_ or !defined $$field) {
      my $class= @_? shift : $self->_build_transaction_class;
      Module::Runtime::require_module($class)
         unless $class->can('new');
      $$field= $class;
   }
   return $$field;
}

sub new_transaction {
   my $self= shift;
   $self->transaction_class->new(
      server_domain        => $self->server_domain,
      server_address       => $self->server_address,
      server_helo          => $self->server_helo,
      server_ehlo_keywords => $self->server_ehlo_keywords,
      client_domain        => $self->client_domain,
      client_helo          => $self->client_helo,
      @_
   );
}

=head1 STATES

The SMTP protocol has a 'state' attribute, with the following possible values:

=over

=item C<'connect'>

The initial state means nothing has happened yet.  It can transition to
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

=item C<'abort'>

An unrecoverable protocol error has occurred, and the connection needs to be closed.

=back

=head1 COMMANDS

=head2 EHLO

  "EHLO" SP $domain CRLF

The modern session-initiation command.  This is allowed in any state except
'reject', 'starttls', 'auth', and 'quit'.

=cut

$commands{EHLO}= {
   states     => { handshake => 1, ready => 1, mail => 1, data => 1 },
   attributes => { domain => 1 },
   parse      => sub($self) {
      /^EHLO /gci
      && (my $domain= $self->parse_helo_domain)
      && /\G *$/gc
         or return _undef_with_err($self, [ 501, 'invalid EHLO syntax' ]);
      return { domain => $domain };
   },
   render     => sub($self, $cmd) {
      'EHLO '.$self->render_helo_domain($cmd->{domain})
   },
};

=head2 HELO

The classic session-initiation command.  Servers must still support it,
but all clients should use EHLO.

=cut

$commands{HELO}= {
   states     => { handshake => 1, ready => 1, mail => 1, data => 1 },
   attributes => { domain => 1 },
   parse      => sub($self) {
      /^HELO /gci
      && (my $domain= $self->parse_helo_domain)
      && /\G *$/gc
         or return _undef_with_err($self, [ 501, 'invalid HELO syntax' ]);
      return { domain => $domain };
   },
   render     => sub($self, $cmd) {
      'HELO '.$self->render_helo_domain($cmd->{domain})
   },
};

=head2 MAIL

  "MAIL FROM:" $reverse_path [SP $mail_parameters] CRLF

L<https://datatracker.ietf.org/doc/html/rfc5321#section-4.1.1.2>

Declare the envelope sender of the message.  This command sends or
receives the C<reverse_path> attribute of L</mail_transaction>.
(C<reverse_path> is an instance of L<Email::MTA::Toolkit::SMTP::EnvelopeRoute|EnvelopeRoute>
which can contain C<mail_parameters>)

=cut

$commands{MAIL}= {
   states     => { ready => 1 },
   attributes => { from => 1 },
   parse      => sub($self) {
      /^MAIL FROM:/gci
      && defined(my $addr= $self->parse_mail_route_with_params)
      && /\G *$/
         or return _undef_prefix_err($self, [ 500, "Invalid MAIL syntax" ]);
      return { from => $addr };
   },
   render     => sub($self, $cmd) {
      'MAIL FROM:'.$self->render_mail_route_with_params($cmd->{from})
   },
};

=head2 RCPT

  "RCPT TO:" ( $forward_path | "<Postmaster>" ) [SP $rcpt_parameters] CRLF

L<https://datatracker.ietf.org/doc/html/rfc5321#section-4.1.1.3>

Declare another recipient for the current message.  The default handler parses
and pushes another MailPath object onto the C<< mail_transaction->forward_path >>
attribute.

=cut

$commands{RCPT}= {
   states     => { ready => 1 },
   attributes => { to => 1 },
   parse      => sub($self) {
      /^RCPT TO:/gci
      && defined(my $forward_path= $self->parse_mail_route_with_params)
      && /\G *$/
         or return _undef_prefix_err($self, [ 500, "Invalid RCPT syntax" ]);
      return { to => $forward_path };
   },
   render     => sub($self, $cmd) {
      'RCPT TO:'.$self->render_mail_route_with_params($cmd->{to})
   },
};

=head2 DATA

  "DATA" CRLF

The data command changes the state to 'data' and switches the protocol to interpret
lines as data instead of commands, until a line contains a single period character.
This command has no attributes.

=cut

$commands{DATA}= {
   states     => { mail => 1 },
   attributes => { },
   parse      => sub($self) {
      /^DATA *$/gci
         or return _undef_with_err($self, [500, 'Invalid DATA syntax']);
      return {}
   },
   render     => sub { "DATA" },
};

=head2 QUIT

  "QUIT" CRLF

This command closes the connection gracefully.

=cut

$commands{QUIT}= {
   states     => { handshake => 1, reject => 1, ready => 1, mail => 1 },
   attributes => {},
   parse      => sub($self) {
      /^QUIT *$/gci
         or return _undef_with_err($self, [500, 'Invalid QUIT syntax']);
      return {};
   },
   render     => sub { 'QUIT' },
};

=head1 PARSE METHODS

Each of these class methods operates on C<$_> starting at C<pos($_)>
(using the \G feature of the regex engine).
They modify the C<pos> of C<$_>, allowing you to continue parsing a
buffer without modifying it.

On error, the methods return undef and set L</last_parse_error>.

=head2 parse_command_if_complete

  for ($buffer) { my $attrs= $class->parse_cmd_if_complete }
  # or
  my $attrs= $class->parse_cmd_if_complete($buffer);

If the buffer C<$_> from C<pos> does not contain a '\n' character, assume the
command is incomplete and return C<undef> instead of an error.  Else parse the
command and return a hashref, where errors are reported as C<< $result->{error} >>.

=cut

sub parse_command_if_complete {
   if (@_ > 1) {
      # Function operates on $_, not @_, but be nice to callers who try
      # to pass the buffer as an argument.
      return $_[0]->parse_command_if_complete for $_[1];
   }
   my $self= $_[0];
   my ($line, $cmd, $eol)= /\G( (\S*) .*?) (\r?\n)/gcx
      or $self->last_parse_error(undef), return undef;
   $cmd= uc $cmd;
   my $cmdinfo= $self->commands->{$cmd}
      or return _undef_with_err($self,
         defined $commands{$cmd}
            ? [ 502, qq{Unimplemented} ]
            : [ 500, qq{Unknown command "$cmd"} ]
      );
   my $ret;
   $ret= $cmdinfo->{parse}->($self) for $line;
   defined $ret or return undef;
   $ret->{command}= $cmd;
   $ret->{command_spec}= $cmdinfo;
   $ret->{original}= $line;
   push @{$ret->{warnings}}, 'Missing CR at end of line'
      unless $eol eq "\r\n";
   return $ret;
}

=head2 parse_response_if_complete

  my $attrs= $class->parse_response_if_complete($buffer);

If the buffer contains a complete response, this returns an array of the code followed by
one string for each line of the response, with end-of-line truncated.

=cut

has response_parsers => ( is => 'rw', default => sub { +{} } );
sub parse_response_if_complete {
   if (@_ > 1) {
      # Function operates on $_, not @_, but be nice to callers who try
      # to pass the buffer as an argument.
      return $_[0]->parse_response_if_complete for $_[1];
   }
   my $self= $_[0];
   my ($first_code, @lines);
   my ($orig_pos, $line_pos)= (pos($_), pos($_));
   while (my ($line, $eol)= /\G(.*?) (\r?\n)/gcx) {
      my ($code, $cont, $body)= ($line =~ /^([0-9]{3}) ([- ]) (.*)$/x)
         or do {
            pos($_)= $orig_pos;
            return _undef_with_err($self, "Malformed response line: '".substr($_, 0, 10)."'");
         };
      if (defined $first_code && $first_code != $code) {
         pos($_)= $line_pos;
         return _undef_with_err($self, "Malformed response: code $first_code was expected to continue on next line");
      }
      push @lines, $body;
      if ($cont eq ' ') {
         my $rp= $self->response_parsers->{$code};
         return $rp? $rp->($code, @lines)
            : { code => $code, lines => \@lines };
      }
      $first_code= $code;
      $line_pos= pos($_);
   }
   # buffer does not contain a complete response
   return undef;
}

sub render_response {
   my ($self, $res)= @_;
   my $code= $res->{code};
   my $lines= $res->{lines};
   my $out= '';
   $out .= $code . ($_ == $#$lines? ' ' : '-') . $lines->[$_] . "\r\n"
      for 0..$#$lines;
   return $out;
}

=head2 parse_domain

Match C<$_> from C<pos> vs. the RFC 5321 specification of a 'Domain', returning
the domain on a match, or undef otherwise.

=cut

sub parse_domain($self) {
   /\G( \w[-\w]* (?: \. \w[-\w]* )* )/gcx
      and return $1;
   return _undef_with_err($self, 'Invalid domain name');
}

=head2 parse_ip_addr

Match C<$_> from C<pos> vs. the RFC 5321 specification of literal IP address
notation.  Returns the address on success, or undef on failure.

=cut

sub parse_ip_addr($self) {
   # TODO: implement a stricter parse
   /\G(
      [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+    # ipv4
      | [0-9A-Fa-f]*:[0-9A-Fa-f:]+      # ipv6
   )/gcx
      and return $1;
   return _undef_with_err($self, 'Invalid IP address notation');
}

sub parse_helo_domain($self) {
   !/\G \[ /gcx? $self->parse_domain
      : $self->parse_host_addr && (/\G \] /gcx || _undef_with_err($self, 'Missing ] on address'))
}
sub render_helo_domain($self, $domain) {
   do { $self->parse_ip_addr for $domain }? '['.$domain.']'
      : $domain;
}

=head2 parse_mail_route_with_params

Match C<$_> from C<pos> vs. the RFC 5321 specification for the 'reverse-path'
of the MAIL command (or 'forward-path' of the RCPT command) where the first N-1
elements are domain names, and the final one is a mailbox@domain.  Then match
the optional name=value parameters for the RCPT and MAIL commands.

This function allows the special case of C<< <Postmaster> for the RCPT command
and the empty C<< <> >> path for the MAIL command, and the caller should verify
that they were used in the correct context.

Returns an instance of L<Email::MTA::Toolkit::SMTP::EnvelopeRoute>.

=cut

sub parse_mail_route_with_params($self) {
   my ($route, $mbox, $parameters);
   /\G < /gcx
      or return _undef_with_err($self, "Mail path must start with '<'");
   # Special case for 'MAIL FROM:<>'
   unless (/\G > /gcx) {
      if (/\G \@ /gcx) {
         # Path is one or more domain followed by colon "@domain,@domain,@domain:"
         do {
            defined(my $d= $self->parse_domain)
               or return _undef_prefix_err($self, "Invalid mail path");
            push @$route, $d;
         } while (/\G , \@ /gcx);
         /\G : /gcx
            or return _undef_with_err($self, "Mail path must have ':' before mailbox");
      }
      # Special case for 'RCPT TO:<postmaster>'
      if (/\G (postmaster) > /gcxi) {
         $mbox= $1;
      } else {
         $mbox= $self->parse_mailbox
            // return undef;
         /\G > /gcx
            or return _undef_with_err($self, "Mail path must end with '>'");
      }
   }
   # optional name=value parameters following mail path
   while (/\G [ ]+ ([^=\s]+) (?: = (\S*) )? /gcx) {
      $parameters->{$1}= $2;
   }
   return Email::MTA::Toolkit::SMTP::EnvelopeRoute->new(
      mailbox    => $mbox,
      route      => $route,
      parameters => $parameters,
   );
}

sub render_mail_route_with_params($self, $addr) {
   my ($route, $mbox, $params)= ($addr->route, $addr->mailbox, $addr->parameters);
   my $str= '<';
   $str .= join(',', map '@'.$_, @$route) . ':'
      if $route && @$route;
   $str .= $mbox if defined $mbox;
   $str .= '>';
   $str .= map { defined $params->{$_}? " $_=$params->{$_}" : " $_" } keys %$params
      if $params;
   return $str;
}

sub parse_mailbox($self) {
   # TODO
   /\G( \S+ \@ \w[-\w]* (?: \. \w[-\w]* )* )/gcx? $1
      : _undef_with_err($self, 'Invalid mailbox syntax');
}

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

=cut

# TODO

=head2 render_command

Return the command as a canonical line of text ending with C<"\r\n">.

=cut

sub render_command {
   my ($self, $req)= @_;
   my $cmdinfo= $self->commands->{uc $req->{command}}
      or croak "Don't know how to render a $req->{command} message";
   $cmdinfo->{render}->($self, $req)."\r\n";
}

1;
