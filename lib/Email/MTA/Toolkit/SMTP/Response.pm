package Email::MTA::Toolkit::SMTP::Response;
use Moo;
use Carp;
use overload '""' => \&render;

=head1 DESCRIPTION

The Server's response to an SMTP command has a code, and optional messages.
Each message is written on its own line, repeating the code with an indication
of whether the response continues or not.

For most replies, the message is irrelevant, though for some (like EHLO) there
is a specific syntax involved.  This object does not handle the details of
encoding/decoding those special messages.

=head1 ATTRIBUTES

=head2 protocol

A reference to an SMTP protocol class or object instance.

=head2 code

The numeric 3-digit code of the response.

=head2 messages

An arrayref of message lines, pre-fomatted (but without CRLF terminators).

=cut

has protocol => ( is => 'rw', required => 1 );
has code     => ( is => 'rw' );
has messages => ( is => 'rw' );

=head1 METHODS

=head2 render

Convert a mesage to lines of protocol ending with CRLF.
(returned as a single string)

=cut

sub render {
   my $self= shift;
   return $self->protocol->render_response($self);
}

=head2 TO_JSON

Return the code and message attributes as a hashref.

=cut

sub TO_JSON {
   my $ret= { %{$_[0]} };
   delete $ret->{protocol};
   $ret;
}

1;
