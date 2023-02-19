package Email::MTA::Toolkit::IO::IBuf;
use Moo::Role;
use Carp;
use Scalar::Util 'dualvar';
use namespace::clean;

=head1 DESCRIPTION

This abstract role-like class is an "Input Buffer" which might be associated
with an input stream which can fill it.  Consumption of the buffer should be
tracked using perl's internal C<< pos( $ibuf->ibuf ) >>.  Subclasses may
choose to implement the C<< ->fill >> method to allow the buffer to grow.

=head1 SYNOPSIS

Usage of the input buffer should follow this pattern:

  # Parser checks to see if there is a complete message component in the buffer.
  # If so, consume it by moving pos(ibuf) and continue processing.
  # Regexes with the /gc flag in scalar context move pos() for you.
  if ($io->ibuf =~ /.../gc) {
    # process the message
    # then return to caller, or continue a loop.
  } else {
    # Check if it is possible to request more bytes
    redo if $io->fetch;
  
    # ifinal is true if no more bytes will arrive.  It is "0 but true" on
    # natural EOF, and the system errno if it was a fatal error.
    return !$io->ifinal? "Please Wait"
      : $io->ifinal == 0? "Closed by client"
      : "fatal error ".$io->ifinal;
  }

=head1 ATTRIBUTES

=head2 ibuf

This returns an lvalue of the buffer scalar itself.  You may modify the buffer and
change its C<pos> however you like.  Any bytes before the C<pos> are considered to
be "consumed" and may be removed from the buffer by calls to L</fetch>.

You may pass one argument to this accessor to assign a new value to the buffer.
(but this does not change which scalar is used as the buffer)

=head2 ibuf_pos

Convenient accessor for C<< pos( $io->ibuf ) >>.  This is also an lvalue accessor.
You may pass one argument to this accessor to alter the pos.

=head2 ibuf_avail

Convenient accessor for C<< length($io->ibuf) - pos($io->ibuf) >>.

=head2 ifinal

Error or EOF status of the stream connected to the buffer.  EOF (or lack of an
associated stream) is indicated by a dualvar with string value C<"EOF"> and numeric
value C<0> (and evaluates as boolean true).  Any other value is the system's C<$!>
(aso a dualvar) of the fatal error.  Transient errors are not reported here, because
the buffer could still grow on future calls to L</fetch>.  Buffers that cannot grow
will always have the EOF value C<"0 but true">.

=cut

has ibuf => ( is => 'rw', accessor => undef, default => '' );
sub ibuf :lvalue {
   if (@_ > 1) {
      croak("too many arguments") if @_ > 2;
      $_[0]{ibuf}= $_[1];
   }
   $_[0]{ibuf}
}
sub ibuf_pos :lvalue {
   if (@_ > 1) {
      croak("too many arguments") if @_ > 2;
      pos($_[0]{ibuf})= $_[1];
   }
   pos $_[0]{ibuf}
}

sub ibuf_avail { length($_[0]{ibuf}) - (pos($_[0]{ibuf})||0) }

our $EOF= dualvar(0, 'EOF');
has ifinal => ( is => 'rw', default => $EOF );

=head1 METHODS

=head2 fetch

  $bytes_added= $io->fetch($size_hint=undef);

Try reading bytes from the associated stream into L</ibuf>.

The fetch method in this abstract base class always returns 0. Other subclasses
may perform a blocking or nonblocking read.  In all cases, errors or EOF or
otherwise, the return value is simply the number of bytes added, and users can
check L</ifinal> to see if an error of EOF condition was reached.

=cut

sub fetch { 0 }

1;
