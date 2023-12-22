package Email::MTA::Toolkit::SMTP::Response;
use Moo;
use Carp;
use Scalar::Util 'blessed';
use namespace::clean;

=head1 DESCRIPTION

The Server's response to an SMTP command has a code, and optional messages.
Each message is written on its own line, repeating the code with an indication
of whether the response continues or not.

For most replies, the message is irrelevant, though for some (like EHLO) there
is a specific syntax involved.  This object does not handle the details of
encoding/decoding those special messages.

=head1 ATTRIBUTES

=head2 protocol

A weak reference to an SMTP protocol class or object instance.

=head2 code

The numeric 3-digit code of the response.

=head2 message_lines

An arrayref of message lines, without the code prefix or CRLF terminators.

=cut

use overload '""' => sub { $_[0]->render };

has protocol      => ( is => 'rw', required => 1 );
has request       => ( is => 'rw', accessor => undef );
has promise       => ( is => 'rw' );
has code          => ( is => 'rw' );
has message_lines => ( is => 'rw' );

# This accessor inflates the request into an object, on demand.
sub request {
   my $self= shift;
   $self->{request}= shift if @_;
   if ($self->{request} && !blessed($self->{request})) {
      $self->{request}{protocol}= $self->protocol;
      $self->{request}{commandinfo} ||= $self->protocol->commands->{$self->{request}{command}};
      $self->{request}= Email::MTA::Toolkit::SMTP::Request->new($self->{request});
   }
   return $self->{request}
}

sub is_success {
   my $code= $_[0]->code;
   defined $code && $code >= 200 && $code < 400
}

=head1 METHODS

=head2 render

Convert a mesage to lines of protocol ending with CRLF.
(returned as a single string)

=cut

sub render {
   my $self= shift;
   return defined $self->code? $self->protocol->render_response($self)
      : '(pending)';
}

1;
