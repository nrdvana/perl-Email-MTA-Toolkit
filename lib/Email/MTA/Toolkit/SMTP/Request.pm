package Email::MTA::Toolkit::SMTP::Request;
use Moo;
use Carp;
use overload '""' => \&format;

=head1 CONSTRUCTORS

=head2 new

  $req= ...->new( %attributes )

=head2 parse

  my ($request_obj, $error)= CLASS->parse($buffer);

Return a new Request object parsed from a buffer starting from C<< pos($buffer) >>.
If the buffer does not contain a LF (\n), this returns an empty list, assuming
there just isn't a full command in the buffer yet.  If the command contains an
invalid character (anything outside of ASCII, or a control character) this returns
an error.  If the command is not recognized, it returns an error.  Any warnings
(like if the line terminator was not the official CRLF) are returned as part of
the object.

If anything is returned, C<< pos($buffer) >> will be updated to the character beyond
the LF that was used as the end-of-line marker.

(The standard insists that only CRLF should be accepted, but Postfix allows LF on
 its own, and it is useful for debugging from the terminal, so this module just
 treats bare LF as a warning.)

=cut

sub parse {
   my $class= shift;
   # Match a full line, else don't change anything
   return () unless $_[0] =~ /\G( [^\n]*? )(\r?\n)/gcx;
   my $self= $class->new(
      original => $1,
      warnings => [ $2 eq "\r\n"? () : ( 'Wrong line terminator' ) ],
   );
   $self->{original} =~ /[^\t\x20-\x7E]/
      and return undef, "500 Invalid characters in command";
   $self->{original} =~ /^ (\w[^ ]*) /gcx
      or return undef, "500 Invalid command syntax";
   my $m= $class->can('_parse_'.uc($1))
      or return undef, "500 Unknown command '$1'";
   $self->command(uc $1);
   return $self->$m for $self->{original};
}

=head1 ATTRIBUTES

=head2 original

The original line of text as sent by the client, not including line terminator.

=head2 command

The main verb of the command, in uppercase.  Usually 4 characters; for example "MAIL",
not "MAIL FROM".

=head2 host

The hostname of the HELO and EHLO commands.

=head2 address

The 'From:' address of the MAIL command or 'To:' address of the RCPT command.
The angle brackets '< >' are removed during parsing, and automatically applied
when stringifying.

=head2 parameters

The optional mail/rcpt parameters following the address.

=cut

has original   => ( is => 'rw' );
has command    => ( is => 'rw' );
has host       => ( is => 'rw' );
has path       => ( is => 'rw' );
has mailbox    => ( is => 'rw' );
has parameters => ( is => 'rw' );
has warnings   => ( is => 'rw' );

=head1 METHODS

=head2 format

Return the command as a string of SMTP protocol, not including the CRLF terminator.

=cut

sub format {
   my $self= shift;
   my $m= $self->can("_format_".$self->command)
      or croak "Don't know how to format a ".$self->command." message";
   $m->($self);
}


sub _parse_domain {
   /\G( \w[-\w]* (?: \. \w[-\w]* )* )/gcx? $1 : undef;
}
sub _parse_host_addr {
   # TODO
   /\G (\S+) /gcx? $1 : undef;
}
sub _parse_forward_path {
   my $self= shift;
   my @path;
   /\G < /gcx or return undef;
   if (/\G \@ /gcx && defined(my $d= $self->_parse_domain)) {
      push @path, $d;
      while (/\G ,\@ /gcx && defined($d= $self->_parse_domain)) {
         push @path, $d;
      }
      /\G : /gcx or return undef;
   }
   my $m= $self->_parse_mailbox
      or return undef;
   /\G > /gcx or return undef;
   push @path, $m;
   return \@path;
}
sub _parse_reverse_path {
   my $self= shift;
   /\G <> /gcx? [] : $self->_parse_forward_path
}
sub _parse_mail_parameters {
   # TODO
   { map { my $p= index $_, '='; $p > 0? (substr($_,0,$p) => substr($_,$p+1)) : ($_ => undef) } split / /, substr($_, pos) }
}
sub _format_mail_parameters {
   my ($self, $p)= @_;
   join ' ', map { defined $p->{$_}? "$_=$p->{$_}" : "$_" } keys %$p;
}
*_parse_rcpt_parameters= *_parse_mail_parameters;
*_format_rcpt_parameters= *_format_mail_parameters;
sub _parse_mailbox {
   # TODO
   /\G( \S+ \@ \w[-\w]* (?: \. \w[-\w]* )* )/gcx? $1 : undef;
}

sub _parse_HELO {
   my $self= shift;
   my $host= /\G /gc? $self->_parse_domain : undef;
   defined $host && /\G \s* $/gcx
      or return undef, "500 Invalid HELO syntax";
   $self->host($host);
   return $self;
}
sub _format_HELO {
   my $self= shift;
   "HELO ".$self->host;
}

sub _parse_EHLO {
   my $self= shift;
   my $host= /\G /gc? ($self->_parse_host_addr // $self->_parse_domain) : undef;
   defined $host && /\G \s* $/gcx
      or return undef, "500 Invalid EHLO syntax";
   $self->host($host);
   return $self;
}
sub _format_EHLO {
   my $self= shift;
   "EHLO ".$self->host;
}

# https://datatracker.ietf.org/doc/html/rfc5321#section-4.1.1.2
# "MAIL FROM:" Reverse-path [SP Mail-parameters] CRLF

sub _parse_MAIL {
   my $self= shift;
   /\G FROM:/gc
      or return undef, "500 Invalid MAIL syntax";
   my $path= $self->_parse_reverse_path
      or return undef, "500 Invalid MAIL reverse-path syntax";
   my $params= $self->_parse_mail_parameters;
   /\G \s* $/gcx
      or return undef, "500 Invalid MAIL syntax";
   $self->path($path);
   $self->mailbox($path->[-1]);
   $self->parameters($params);
   return $self;
}
sub _format_MAIL {
   my $self= shift;
   my $addr= $self->mailbox;
   $addr= "<$addr>" unless $addr =~ /^</;
   my $params= $self->parameters;
   $params && keys %$params? "MAIL FROM:$addr ".$self->_format_mail_parameters($params)
      : "MAIL FROM:$addr";
}

# https://datatracker.ietf.org/doc/html/rfc5321#section-4.1.1.3
# "RCPT TO:" ( "<Postmaster@" Domain ">" / "<Postmaster>" /
#              Forward-path ) [SP Rcpt-parameters] CRLF
#
#    Note that, in a departure from the usual rules for
#    local-parts, the "Postmaster" string shown above is
#    treated as case-insensitive.

sub _parse_RCPT {
   my $self= shift;
   /\G TO:/gc
      or return undef, "500 Invalid RCPT syntax";
   my $path= $self->_parse_forward_path
      or return undef, "500 Invalid RCPT forward-path syntax";
   my $params= $self->_parse_rcpt_parameters;
   /\G \s* $/gcx
      or return undef, "500 Invalid RCPT syntax";
   $self->path($path);
   $self->mailbox($path->[-1]);
   $self->parameters($params);
   return $self;
}
sub _format_RCPT {
   my $self= shift;
   my $addr= $self->mailbox;
   $addr= "<$addr>" unless $addr =~ /^</;
   my $params= $self->parameters;
   $params && keys %$params? "RCPT TO:$addr ".$self->_format_rcpt_parameters($params)
      : "RCPT TO:$addr";
}

use 5.026;
sub _parse_QUIT {
   /\G \s* $/gcx
      or return undef, "500 Invalid QUIT syntax";
   return shift;
}
sub _format_QUIT {
   "QUIT";
}

1;
