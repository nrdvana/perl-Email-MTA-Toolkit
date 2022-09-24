package Email::MTA::Toolkit::SMTP::Request;
use Moo;
use Carp;
use overload '""' => \&render;

=head1 CONSTRUCTORS

=head2 new

  $req= ...->new( %attributes )

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

has protocol   => ( is => 'ro', required => 1 );
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

sub render {
   my $self= shift;
   $self->protocol->render_cmd($self)
}

sub TO_JSON {
   my $ret= { %{$_[0]} };
   delete $ret->{protocol};
   $ret;
}

1;
