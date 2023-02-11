package Email::MTA::Toolkit::SSL::Session;
use strict;
use warnings;
use Carp ();
use Log::Any '$log';
use Email::MTA::Toolkit::SSL 'ssl_croak_if_error';
use Email::MTA::Toolkit::SSL::Context;
use Errno qw( EWOULDBLOCK EAGAIN ETIMEDOUT EINTR EPIPE );
our %ssl_error;
BEGIN {
   %ssl_error= (
      Net::SSLeay::ERROR_NONE()        => 'SSL_ERROR_NONE',
      Net::SSLeay::ERROR_ZERO_RETURN() => 'SSL_ERROR_ZERO_RETURN',
      Net::SSLeay::ERROR_WANT_READ()   => 'SSL_ERROR_WANT_READ',
      Net::SSLeay::ERROR_WANT_WRITE()  => 'SSL_ERROR_WANT_WRITE',
      Net::SSLeay::ERROR_SSL()         => 'SSL_ERROR_SSL',
      Net::SSLeay::ERROR_SYSCALL()     => 'SSL_ERROR_SYSCALL',
   )
}
use constant { reverse %ssl_error };

=head1 DESCRIPTION

This object is a simple wrapper around a SSL instance.  It holds a reference
to the wrapper around the Context instance so that destruction runs in the
right order.

=head1 CONSTRUCTOR

=head2 new

  $session= $class->new(context => $ssl_context);

=cut

our %ssl_pointer_map;

sub new {
   my $class= shift;
   my %attrs= @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]} : @_;
   my $ctx= $attrs{context} or Carp::croak("context is required");
   $ctx= $ctx->pointer if ref $ctx;
   $attrs{pointer}= Net::SSLeay::new($ctx);
   ssl_croak_if_error('Net::SSLeay::new');
   my $self= bless \%attrs, $class;
   Scalar::Util::weaken($ssl_pointer_map{$self->pointer}= $self);
   $self->set_fd($attrs{fd}) if defined $attrs{fd};
   $self->set_bio($attrs{bio}) if defined $attrs{bio};
   Net::SSLeay::set_info_callback($self->pointer, \&_info_callback);
   $self;
}

sub new_client {
   my $class= shift;
   my %attrs= @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]} : @_;
   $attrs{context} ||= Email::MTA::Toolkit::SSL::Context->new(\%attrs);
   my $self= $class->new(\%attrs);
   $self->set_connect_state;
   $self;
}

sub new_server {
   my $class= shift;
   my %attrs= @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]} : @_;
   defined $attrs{cert} || defined $attrs{certificate_file}
      or Carp::croak("Require 'cert' or 'certificate_file' parameter");
   defined $attrs{key}  || defined $attrs{private_key_file}
      or Carp::croak("Require 'key' or 'private_key_file' parameter");
   $attrs{context} ||= Email::MTA::Toolkit::SSL::Context->new(\%attrs);
   my $self= $class->new(\%attrs);
   $self->set_accept_state;
   $self;
}

sub DESTROY {
	Net::SSLeay::free($_[0]{pointer});
   delete $ssl_pointer_map{$_[0]{pointer}}
}

=head1 ATTRIBUTES

=head2 context

The Email::MTA::Toolkit::SSL::Context instance passed to the constructor.

=head2 pointer

The integer representing the SSLeay session which gets passed to all SSLeay
functions.

=head2 state

The current SSL state from L<Net::SSLeay/state>.

=head2 mode

The mode bitmask from L<Net::SSLeay/get_mode>.

=cut

sub context { $_[0]{context} }
sub pointer { $_[0]{pointer} }

sub state {
   Net::SSLeay::state($_[0]{pointer});
}

sub certificate {
   Net::SSLeay::get_certificate($_[0]{pointer});
}
sub peer_certificate {
   Net::SSLeay::get_peer_certificate($_[0]{pointer});
}
sub peer_cert_chain {
   Net::SSLeay::get_peer_cert_chain($_[0]{pointer});
}

sub mode {
   if (@_ > 1) {
      my $ret= Net::SSLeay::set_mode($_[0]{pointer}, $_[1]);
      ssl_croak_if_error('set_mode');
      return $ret;
   }
   return Net::SSLeay::get_mode($_[0]{pointer});
}

sub set_accept_state {
   my $ret= Net::SSLeay::set_accept_state($_[0]{pointer});
   ssl_croak_if_error('set_accept_state');
   $ret;
}

sub set_connect_state {
   my $ret= Net::SSLeay::set_connect_state($_[0]{pointer});
   ssl_croak_if_error('set_connect_state');
   $ret;
}

sub _info_callback {
   my ($ssl, $where, $ret)= @_;
   return unless $log->is_debug;
   if (my $self= $ssl_pointer_map{$ssl}) {
      my $prefix= ($where & Net::SSLeay::ST_CONNECT())? 'SSL connect: '
         : ($where & Net::SSLeay::ST_ACCEPT())? 'SSL accept: '
         : 'SSL: ';
      if ($where & Net::SSLeay::CB_LOOP()) {
         $log->debug($prefix . $self->state_string_long);
      } elsif ($where & Net::SSLeay::CB_ALERT()) {
         $log->debug($prefix . 'alert '
            . ($where & Net::SSLeay::CB_READ()? 'read ':'write ')
            . Net::SSLeay::alert_type_string_long($ret) . ' '
            . Net::SSLeay::alert_desc_string_long($ret)
         );
      } elsif ($where & Net::SSLeay::CB_EXIT()) {
         $log->debug($prefix . $self->state_string_long . ' exit ' . $ret);
      } else {
         $log->debug($prefix . ' (unknown event type)');
      }
   } else {
      print "Unknown ssl pointer $ssl\n";
   }
}

sub fd {
   $_[0]->set_fd($_[1]) if @_ > 1;
   Net::SSLeay::get_fd($_[0]{pointer});
}
sub set_fd {
   my ($self, $fd)= @_;
   my $fileno= ref $fd? fileno($fd)
      : $fd =~ /^[0-9]+$/? $fd
      : Carp::croak("Expected file handle or descriptor integer, but got: '$fd'");
   Net::SSLeay::set_fd($_[0]{pointer}, $fileno)
      or ssl_croak_if_error('set_fd');
   $self->{fd}= $fd; # hold reference to ensure socket remains open
}

sub set_bio {
   Net::SSLeay::set_bio($_[0]{pointer}, $_[1], $_[2]);
}

sub state_string_long {
   Net::SSLeay::state_string_long($_[0]{pointer});
}

sub get_last_error {
   my $last_ret= defined $_[0]{last_error_return}? delete $_[0]{last_error_return} : -1;
   my $err= Net::SSLeay::get_error($_[0]{pointer}, $last_ret);
   $ssl_error{$err}? Scalar::Util::dualvar($err, $ssl_error{$err}) : $err;
}

sub do_handshake {
   $_[0]{last_error_return}= Net::SSLeay::do_handshake($_[0]{pointer});
}

sub read {
   $_[0]{last_error_return}= @_ > 1
      ? Net::SSLeay::read($_[0]{pointer}, $_[1])
      : Net::SSLeay::read($_[0]{pointer});
}

sub sysread {
   # ($self, $buffer, $length, $offset)
   # Logic derived from IO::Socket::SSL _generic_read and _skip_rw_error
   $!= undef;
   my $data= Net::SSLeay::read($_[0]{pointer}, $_[2]);
   if (defined $data) {
      substr($_[1], $_[3] || 0, length $data, $data);
      return length $data;
   }
   else {
      my $syserr= $!;
      my $err= Net::SSLeay::get_error($_[0]{pointer}, -1);
      # Detect cases that mean more OpenSSL packets need exchanged before data will be available.
      if ($err == SSL_ERROR_WANT_READ || $err == SSL_ERROR_WANT_WRITE) {
         $syserr ||= EWOULDBLOCK;
      }
      # Detect cases that indicate end of stream.
      elsif (not $! and ($err == SSL_ERROR_SSL || $err == SSL_ERROR_SYSCALL)) {
         return 0;
      }
      # Set errno like sysread would.
      $!= $syserr;
      undef;
   }
}

sub write {
   $_[0]{last_error_return}= Net::SSLeay::write($_[0]{pointer}, $_[1]);
}

sub syswrite {
   # ($self, $buffer, $length, $offset)
   $!= undef;
   my $wrote= Net::SSLeay::write($_[0]{pointer}, $_[2] || $_[3]? substr($_[1], $_[3]||0, $_[2]||0) : $_[1] );
   return $wrote if $wrote > 0;
   
   my $syserr= $!;
   my $err= Net::SSLeay::get_error($_[0]{pointer}, -1);
   # Detect cases that mean more OpenSSL packets need exchanged before data will be available.
   if ($err == SSL_ERROR_WANT_READ || $err == SSL_ERROR_WANT_WRITE) {
      $syserr ||= EWOULDBLOCK;
   }
   # Detect cases that indicate end of stream.
   elsif (not $! and ($err == SSL_ERROR_SYSCALL)) {
      $syserr ||= EPIPE;
   }
   # Set errno like syswrite would.
   $!= $syserr;
   undef;
}

1;
