package Email::MTA::Toolkit::SSL::Context;
use strict;
use warnings;
use Email::MTA::Toolkit::SSL qw( ssl_croak_if_error );

=head1 DESCRIPTION

An SSL Context ("SSLeay CTX") can be shared by multiple SSL sessions.
Each context can represent only one server certificate.

=cut

# SSLeay code taken from great example at
# http://devpit.org/wiki/OpenSSL_with_nonblocking_sockets_%28in_Perl%29
# Other portions taken from AnyEvent::TLS

sub new {
   my $class= shift;
   my $ctx= Net::SSLeay::CTX_new;
   ssl_croak_if_error("SSL CTX_new");
   bless \$ctx, $class;
}

sub DESTROY {
   Net::SSLeay::CTX_free(${$_[0]});
}

sub new_server_context {
   my ($class, %opts)= @_;
   my $self= $class->new;
   # OP_ALL enables all harmless work-arounds for buggy clients.
   $self->set_options(Net::SSLeay::OP_ALL());
   # Modes:
   # 0x1: SSL_MODE_ENABLE_PARTIAL_WRITE
   # 0x2: SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER
   # 0x4: SSL_MODE_AUTO_RETRY
   # 0x8: SSL_MODE_NO_AUTO_CHAIN
   # 0x10: SSL_MODE_RELEASE_BUFFERS (ignored before OpenSSL v1.0.0)
   $self->set_mode(0x11);
   $self->set_private_key_file($opts{private_key_file}) if $opts{private_key_file};
   $self->set_certificate_file($opts{certificate_file}) if $opts{certificate_file};
   return $self;
}

sub pointer { ${$_[0]} }

sub set_options {
   my ($self, $options)= @_;
   Net::SSLeay::CTX_set_options($$self, $options);
   ssl_croak_if_error("SSL CTX_set_options");
   return $self;
}

sub set_mode {
   my ($self, $mode)= @_;
   Net::SSLeay::CTX_set_mode($$self, $mode);
   ssl_croak_if_error("SSL CTX_set_mode");
   return $self;
}

sub set_private_key_file {
   my ($self, $file, $file_type)= @_;
   $file_type //= Net::SSLeay::FILETYPE_PEM();
   # Load certificate. This will prompt for a password if necessary.
   Net::SSLeay::CTX_use_RSAPrivateKey_file($$self, $file, $file_type);
   ssl_croak_if_error("SSL CTX_use_RSAPrivateKey_file");
   return $self;
}

sub set_certificate_file {
   my ($self, $file, $file_type)= @_;
   $file_type //= Net::SSLeay::FILETYPE_PEM();
   Net::SSLeay::CTX_use_certificate_file($$self, $file, $file_type);
   ssl_croak_if_error("SSL CTX_use_certificate_file");
   return $self;
}


1;
