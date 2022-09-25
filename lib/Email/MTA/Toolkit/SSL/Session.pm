package Email::MTA::Toolkit::SSL::Session;
use strict;
use warnings;
use Email::MTA::Toolkit::SSL 'ssl_croak_if_error';
use Carp;

=head1 DESCRIPTION

This object is a simple wrapper around a SSL instance.  It holds a reference
to the wrapper around the Context instance so that destruction runs in the
right order.

=head1 CONSTRUCTOR

=head2 new

  $session= $class->new(context => $ssl_context);

=cut

sub new {
   my $class= shift;
   my %attrs= @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]} : @_;
   my $ctx= $attrs{context} or croak "context is required";
   $ctx= $ctx->pointer if ref $ctx;
   $attrs{pointer}= Net::SSLeay::new($ctx);
   ssl_croak_if_error('Net::SSLeay::new');
   bless \%attrs, $class;
}

sub new_server {
   my $class= shift;
   my %attrs= @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]} : @_;
   my $context= $attrs{context} || Email::MTA::Toolkit::SSL::Context->new_server(
      private_key_file => $attrs{private_key_file},
      certificate_file => $attrs{certificate_file},
   );
   my $self= $class->new(%attrs, context => $context);
   $self->set_accept_state;
   $self;
}

sub DESTROY {
	Net::SSLeay::free($_[0]{pointer});
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

sub set_bio {
   my $ret= Net::SSLeay::set_bio($_[0]{pointer}, $_[1], $_[2]);
   ssl_croak_if_error('set_bio');
   $ret;
}

sub read {
   my $data= @_ > 1? Net::SSLeay::read($_[0]{pointer}, $_[1])
      : Net::SSLeay::read($_[0]{pointer});
   ssl_croak_if_error('set_connect_state');
   $data;
}

sub write {
   Net::SSLeay::write($_[0]{pointer}, $_[1]);
   ssl_croak_if_error('set_connect_state');
}

1;
