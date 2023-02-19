package Email::MTA::Toolkit::IO::OBuf;
use Moo::Role;
use Carp;
use namespace::clean;

=head1 DESCRIPTION

This abstract role-like class is an "Output Buffer" which might be associated
with an output stream.  The user of the buffer can indicate to other layers
that it is time to deliver the data in the buffer by calling L</flush>, but
the writer should not expect an immediate effect from doing this, and should
just return when it has written everything it wants to write.

=head1 ATTRIBUTES

=head2 obuf

This returns an lvalue of the buffer scalar itself.  It acceps one optional
argument of a scalar to B<overwrite> the output buffer with, but the scalar
used as the buffer does not change.

You may modify the buffer however you like.  Any data in the buffer may be
written and removed from the buffer across calls to L</flush>.

=head2 ofinal

Error or shutdown status of the stream connected to the buffer.

Shutdown is indicated by C<"0 but true">, and any other value is the system's
errno of the fatal error.  Transient errors are not reported here, because the
buffer could still flush in the future.

=cut

has obuf => ( is => 'rw', accessor => undef, default => '' );
sub obuf :lvalue {
   if (@_ > 1) {
      croak("too many arguments") if @_ > 2;
      $_[0]{obuf}= $_[1];
   }
   $_[0]{obuf}
}

has ofinal => ( is => 'rw' );

=head1 METHODS

=head2 flush

  $io->flush;

Inticate to other layers that the buffered data should be written to its
destination.  This has no guarantee that it will immediately affect the L</obuf>.
Essentially, the code that calls C<flush> is not responsible for reporting errors
in the transport of the message.

=cut

sub flush { 0 }

1;
