package Email::MTA::Toolkit::SSL::BIO;
use strict;
use warnings;
use Email::MTA::Toolkit::SSL 'ssl_croak_if_error';

=head1 DESCRIPTION

This is a wrapper around the libssl BIO objects.

=cut

sub new {
   my $class= shift;
   my %attrs= @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]} : @_;
   my $bio= Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
   ssl_croak_if_error('Net::SSLeay::BIO_new');
   my $self= bless \$bio, $class;
   $attrs{autoclose} //= delete $attrs{close};
   $self->autoclose($attrs{autoclose}) if defined $attrs{autoclose};
   $self;
}

sub DESTROY {
   my $self= shift;
   Net::SSLeay::BIO_free($$self);
   ssl_croak_if_error('Net::SSLeay::BIO_free');
}

sub autoclose {
   my $self= shift;
   if (@_) {
      Net::SSLeay::BIO_set_close($$self, $_[0]? Net::SSLeay::BIO_CLOSE() : Net::SSLeay::BIO_NOCLOSE());
   }
   my $flag= Net::SSLeay::BIO_get_close($$self);
   return $flag == Net::SSLeay::BIO_CLOSE()? 1
      : $flag == Net::SSLeay::BIO_NOCLOSE()? 0
      : Carp::croak("Unknown close flag received from BIO_get_close");
}

sub fd {
   my $self= shift;
   if (@_) {
      my $close_flag= Net::SSLeay::BIO_get_close($$self);
      my $fh= shift;
      Net::SSLeay::BIO_set_fd($$self, ref $fh? fileno($fh) : $fh, $close_flag);
   }
   return Net::SSLeay::BIO_get_fd($$self);
}

sub read {
   my $self= shift;
   Net::SSLeay::BIO_read($$self);
}

sub write {
   my $self= shift;
   Net::SSLeay::BIO_write($$self, $_[0]);
}

1;
