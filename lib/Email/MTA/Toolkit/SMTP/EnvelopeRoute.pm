package Email::MTA::Toolkit::SMTP::EnvelopeRoute;
use v5.36;
use Moo;
use Carp;
use Scalar::Util 'blessed';
use namespace::clean;

=head1 DESCRIPTION

The SMTP "MAIL FROM" and "RCPT TO" commands allow optional parameters in addition to the
host route and mailbox.  This class makes it simpler to use the mailbox, route, and
parameters as a single entity.

Note that the route is deprecated by the RFC and parameters are almost never used in practice.
These attributes are included for completeness.

This objects stringifies to the same format used in the SMTP commands.

=head1 ATTRIBUTES

=over

=item mailbox

An email address, or case-insensite string 'Postmaster' in the special case for forward-path,
or C<undef> in the special case of an empty return-path.

=item route

C<undef>, or an arrayref of host names which the mail was requested to be routed.

=item parameters

C<undef>, or a hashref representing the "name=value" parameters.

=cut

require Email::MTA::Toolkit::SMTP::Protocol;
use overload '""' => sub {
   Email::MTA::Toolkit::SMTP::Protocol->render_mail_route_with_params($_[0])
};

has mailbox       => ( is => 'rw', required => 1 );
has route         => ( is => 'rw' );
has parameters    => ( is => 'rw' );

=head1 CLASS METHODS

=head2 new

Standard Moo constructor

=head2 coerce

Convert the argument to an instance of this class if it wasn't already.
It treats plain scalars as the L</mailbox> attribute.  It treats hashrefs as attributes
to pass to L</new>.  Other types generate an exception.

=cut

sub coerce {
   my $class= shift;
   return $class->new(mailbox => $_[0]) unless ref $_[0];
   return $_[0] if blessed($_[0]) && $_[0]->can('mailbox');
   return $class->new($_[0]) if ref $_[0] eq 'HASH';
   croak "Don't know how to convert '".ref($_[0])."' to EnvelopeRoute";
}

1;
