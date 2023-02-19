package Email::MTA::Toolkit::SMTP::Request;
use Moo;
use Carp;
use namespace::clean;

=head1 CONSTRUCTORS

=head2 new

Standard Moo constructor.

=head1 ATTRIBUTES

=head2 original_line

The original line of text as sent by the client, not including line terminator.
This is typically C<undef> if the Request object didn't come from parsing the protocol.

=head2 command

The main verb of the command, in uppercase.  Usually 4 characters; for example "MAIL",
not "MAIL FROM".

=head2 attributes

Arbitrary attributes available or defined for this command.  Any member of this hashref
may also be accessed as an attribute accessor on the object.

=cut

use overload '""' => \&render;

has protocol      => ( is => 'ro', required => 1 );
has command       => ( is => 'rw' );
has commandinfo   => ( is => 'lazy' );
has original_line => ( is => 'rw' );
has warnings      => ( is => 'rw' );

sub _build_commandinfo {
   $Email::MTA::Toolkit::SMTP::Protocol::commands->{uc $_[0]{command}} // {}
}

our $AUTOLOAD;
sub AUTOLOAD {
   my ($attr_name)= ($AUTOLOAD =~ /:(\w+)$/) or die "Invalid attribute accessor '$AUTOLOAD'";
   my $self= shift;
   exists $self->commandinfoattributes->{$attr_name}
      or croak("No such attribute '$attr_name' for SMTP command '$self->{command}'");
   eval 'sub Email::MTA::Toolkit::SMTP::Request::'.$attr_name.' {'
      .'exists $_[0]{attributes}{'.$attr_name.'} or Carp::croak("No such attribute \''
         .$attr_name.'\' for SMTP command \'$_[0]{command}\'");'
         .'@_>1? ($_[0]{attributes}{'.$attr_name.'}=$_[1]):($_[0]{attributes}{'.$attr_name.'})'
         .'}';
   goto $self->can('Email::MTA::Toolkit::SMTP::Request::'.$attr_name);
}

=head1 METHODS

=head2 format

Return the command as a string of SMTP protocol, not including the CRLF terminator.

=cut

sub render {
   my $self= shift;
   $self->protocol->render_cmd($self)
}

1;
