package Email::MTA::Toolkit::IO::BufferedHandle;
use strict;
use warnings;
use parent 'Email::MTA::Toolkit::IO::IBuf', 'Email::MTA::Toolkit::IO::OBuf';

sub new {
   my $class= shift;
   my $self= {
      @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]}
      : @_
   };
   $self->{ihandle} //= $self->{handle};
   $self->{ohandle} //= $self->{handle};
   defined $self->{ihandle}
      && $self->{ihandle}->can('sysread')
      or Carp::croak("Expected attribute 'handle' or 'ihandle' with ->sysread method");
   defined $self->{ohandle}
      && $self->{ohandle}->can('syswrite')
      or Carp::croak("Expected attribute 'handle' or 'ohandle' with ->syswrite method");
   $self->{ibuf} //= '';
   pos($self->{ibuf}) //= 0;
   $self->{ifinal} //= undef;
   $self->{obuf} //= '';
   $self->{ofinal} //= undef;
   bless $self, $class;
}

sub ifinal { $_[0]{ifinal} }

sub fetch {
   my ($self, $readhint)= @_;
   my $ibuf= \$self->{ibuf};
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
      $self->{ifinal}= Scalar::Util::dualvar(0, "EOF") if $got == 0;
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
