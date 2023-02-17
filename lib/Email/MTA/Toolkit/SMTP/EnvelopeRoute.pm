package Email::MTA::Toolkit::SMTP::EnvelopeRoute;
use v5.36;
use Moo;

=head1 DESCRIPTION

The SMTP "MAIL FROM" and "RCPT TO" commands allow optional parameters in addition to the
host route and address.  This class makes it simpler to use the mailbox, route, and
parameters as a single entity.

Also, since the route is deprecated and parameters are almost never used in practice, this
object stringifies to the address, so it can be treated just like an email address if the
consumer doesn't care about route or parameters.

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

use overload '""' => sub { '' . shift->address };

has mailbox       => ( is => 'rw', required => 1 );
has route         => ( is => 'rw' );
has parameters    => ( is => 'rw' );

1;
