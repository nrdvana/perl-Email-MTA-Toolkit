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



1;
