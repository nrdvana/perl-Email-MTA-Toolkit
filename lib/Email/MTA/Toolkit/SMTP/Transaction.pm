package Email::MTA::Toolkit::SMTP::Transaction;
use v5.36;
use Moo;

=head1 DESCRIPTION

In SMTP, a client opens a connection to a server, establishes a session, then delivers
one or more mail transactions.  This class represents one transaction of the session.

The attributes L</server_helo>, L</server_ehlo_keywords>, L</server_domain>, L</server_address>,
L</client_helo>, L</client_domain>, and L</client_address> are copied from the SMTP session.

The attribute L</reverse_path> (envelope from) comes from the MAIL command.  The attribute
L</forward_paths> is an arrayref of paths from the RCPT command(s).  When the
default handler is used, the L</data> attribute is a seekable file handle that collects the
lines of text after the DATA command.

This transaction object may be shown to callbacks in an incomplete state, as the transaction is
being assembled.  So, each parameter may be C<undef> depending on circumstances.

=head1 ATTRIBUTES

=over

=item server_helo

The string given by the server during session setup

=item server_ehlo_keywords

The hashref of name=value optionally given by the server during session setup

=item server_domain

The DNS name of the server

=item server_address

The ascii representation of the server's IP address and port

=item client_helo

The string given by the client during session setup

=item client_domain

The DNS name of the client

=item client_address

The ascii representation of the client's IP address and port

=item reverse_path

The "envelope From" address reported by the client.
Instance of L<Email::MTA::Toolkit::SMTP::MailPath>

=item forward_paths

An arrayref of the "envelope To" address(es).
Each is an instance of L<Email::MTA::Toolkit::SMTP::MailPath>

=item data

A scalarref or file handle of the data lines that followed the DATA command.

=cut

has server_helo          => ( is => 'rw' );
has server_ehlo_keywords => ( is => 'rw' );
has server_domain        => ( is => 'rw' );
has server_address       => ( is => 'rw' );
has client_helo          => ( is => 'rw' );
has client_domain        => ( is => 'rw' );
has client_address       => ( is => 'rw' );
has reverse_path         => ( is => 'rw' );
has forwrd_paths         => ( is => 'rw' );
has data                 => ( is => 'rw' );

1;
