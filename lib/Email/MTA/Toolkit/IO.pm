package Email::MTA::Toolkit::IO;
use strict;
use warnings;
use Carp;

=head1 DESCRIPTION

IO objects help isolate algorithm input/output from the underlying transport.

For the code consuming input and generating output, the read-buffer L</rbuf>
contains a string of bytes which have already been received, and the L</wbuf>
is the write-buffer where output bytes are stored until the code is ready to
flush them to whatever transport mechanism is being used.

The code requests additional bytes for the C<rbuf> using L</fill>, and
indicates the wbuf is ready to be written by calling L</flush>.  These may
be implemented in a blocking or non-blocking or event-driven manner.  C<fill>
should return the number of bytes that were added to C<rbuf> immediately.
Code that needs additional bytes should return gracefully if it can't get
enough bytes from one call to C<fill>, leaving the algorithm on hold, to be
resumed later.  C<fill> may also remove the portions of the buffer before
C<< pos($io->{rbuf}) >> in order to avoid enlarging the C<rbuf> beyond
C<rbuf_limit>.

Likewise, C<flush> should return the number of bytes written, and remove them
from the start of the C<wbuf> (or advance pos($io->{wbuf}) if it makes more
sense to do that for some reason).

The default implementation of fill() and flush() read from C<src> and write to
C<dst>.  Those attributes can be undefined (no action), a file handle (blocking
or nonblocking read/write), or coderefs (which receive the IO object as the
only parameter, and can take any action desired).  You can also make a subclass
with your own implementation of fill() and flush().

=head1 ATTRIBUTES

=head2 rbuf

Read-buffer, for end algorithm.  Bytes up to C<< pos($io->rbuf) >> should be
considered already used.

This is an "lvalue" attribute, meaning you can assign and make changes to it
like a normal variable, such as C<< $io->rbuf =~ /\G([0-9]+)/gc >> which
updates the C<pos> of the buffer.

=head2 rbuf_pos

Shorthand for C<< pos($io->{rbuf}) >>

=head2 rbuf_avail

Shorthand for C<< length($io->{rbuf}) - pos($io->{rbuf}) >>

=head2 wbuf

Write-buffer, for end algorithm.  Bytes up o C<< pos($io->wbuf) >> should be
considered already written to the underlying transport.

Like L</rbuf>, this is also an lvalue.

=head2 wbuf_pos

Shorthand for C<< pos($io->{wbuf}) >>.

=head2 wbuf_avail

Shorthand for C<< length($io->{wbuf}) - pos($io->{wbuf}) >>

=head2 src

A file handle (for blocking or nonblocking reads) or a coderef (for callbacks)
which will be used when L</fill> is requested.

=head2 dst

A file handle (for blocking or nonblocking writes) or a coderef (for callbacks)
which will be used when L</flush> is requested.

=cut

sub rbuf       :lvalue { croak "rbuf is an lvalue" if @_ > 1; $_[0]{rbuf} }
sub rbuf_pos   :lvalue { croak "rbuf_pos is an lvalue" if @_ > 1; pos $_[0]{rbuf} }
sub rbuf_avail         { length($_[0]{rbuf}) - (pos($_[0]{rbuf}) || 0) }
sub eof                { $_[0]{eof}= $_[1] if @_ > 1; $_[0]{eof} }
sub wbuf       :lvalue { croak "wbuf is an lvalue" if @_ > 1; $_[0]{wbuf} }

sub src                { $_[0]{src}= $_[1] if @_ > 1; $_[0]{src} }
sub dst                { $_[0]{dst}= $_[1] if @_ > 1; $_[0]{dst} }

sub new {
	my $class= shift;
	my $self= {
		@_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]}
		: @_
	};
	$self->{rbuf} //= '';
	pos($self->{rbuf})= 0;
	$self->{wbuf} //= '';
	pos($self->{wbuf})= 0;
	bless $self, $class;
}

sub fill {
	my $self= shift;
	my $src= $self->src;
	if (!defined $src) {
		return 0;
	} elsif (ref($src) eq 'GLOB' or ref($src)->can('read')) {
		my $p= pos $self->{rbuf};
		if ($p > (length($self->{rbuf}) >> 1)) {
			substr($self->{rbuf}, 0, $p)= '';
			$p= 0;
		}
		my $got= $src->sysread($self->{rbuf}, 65536, length $self->{rbuf});
		if (defined $got) {
			pos($self->{rbuf})= $p;
			$self->eof(1) if $got == 0;
			return $got;
		}
		die "read: $!" unless $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
		return 0;
	} else {
		return $self->src->($self);
	}
}

sub flush {
	my $self= shift;
	my $dst= $self->dst;
	if (!defined($dst) or !length($self->{wbuf})) {
		return 0;
	} elsif (ref($dst) eq 'GLOB' or ref($dst)->can('write')) {
		my $put= $dst->syswrite($self->{wbuf});
		if (defined $put) {
			substr($self->{wbuf}, 0, $put)= '';
			return $put;
		}
		die "write: $!" if $put < 0 && !($!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK});
		return 0;
	} else {
		return $self->dst->($self);
	}
}

1;
