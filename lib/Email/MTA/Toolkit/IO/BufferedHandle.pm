package Email::MTA::Toolkit::IO::BufferedHandle;
use Moo;
use namespace::clean;
with 'Email::MTA::Toolkit::IO::IBuf', 'Email::MTA::Toolkit::IO::OBuf';

has ihandle => ( is => 'rw', isa => \&_type_readable_handle );
has ohandle => ( is => 'rw', isa => \&_type_writable_handle );

sub BUILD {
   my ($self, $args)= @_;
   if ($args->{handle}) {
      $self->ihandle($args->{handle}) unless defined $self->ihandle;
      $self->ohandle($args->{handle}) unless defined $self->ohandle;
   }
   pos($self->{ibuf}) //= 0;
   $self->{ifinal} //= undef;
   $self->{ofinal} //= undef;
}

sub _type_readable_handle {
   defined $_[0]
      && $_[0]->can('sysread')
      or croak("Expected attribute 'handle' or 'ihandle' with ->sysread method");
}
sub _type_writable_handle {
   defined $_[0]
      && $_[0]->can('syswrite')
      or croak("Expected attribute 'handle' or 'ohandle' with ->syswrite method");
}

sub fetch {
   my ($self, $readhint)= @_;
   my $ibuf= \$self->ibuf;
   $readhint //= 65536;
   my $p= pos $$ibuf;
   # Shift the buffer if more than half of it is already consumed.
   # else don't, to avoid the memcpy.
   if ($p > (length($$ibuf) >> 1)) {
      substr($$ibuf, 0, $p)= '';
      $p= 0;
   }
   my $got= $self->{ihandle}->sysread($$ibuf, $readhint, length $$ibuf);
   if (defined $got) {
      pos($$ibuf)= $p;  # restore the pos, which gets lost after a read
      $self->{ifinal}= $Email::MTA::Toolkit::IO::IBuf::EOF if $got == 0;
      return $got;
   }
   $self->{ifinal}= $! # relying on $! being a dualvar
      unless $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
   return 0;
}

sub flush {
   my $self= shift;
   my $put= $self->{ohandle}->syswrite($self->{obuf});
   if (defined $put) {
      substr($self->{obuf}, 0, $put, '');
      return $put;
   }
   $self->{ofinal}= $!
      unless $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
   return 0;
}

1;
