package Email::MTA::Toolkit::SSL;
use Exporter::Extensible -exporter_setup => 1;
use Net::SSLeay;
use Carp;

# SSLeay code taken from great example at
# http://devpit.org/wiki/OpenSSL_with_nonblocking_sockets_%28in_Perl%29

BEGIN {
   Net::SSLeay::library_init();
}

# OpenSSL's error functions are annoying. These are a bit more convenient.
sub ssl_get_errors :Export(:util) {
   my @errors;
   while(my $errno = Net::SSLeay::ERR_get_error()) {
      my $msg= Net::SSLeay::ERR_error_string($errno);
      push @errors, Scalar::Util::dualvar($errno, $msg);
   }
   return @errors;
}

sub ssl_get_error :Export(:util) {
   my @errors= ssl_get_errors();
   return join ', ', map { (0+$_).' '.$_ } ssl_get_errors();
}

sub ssl_croak_if_error :Export(:util) {
   my ($message)= @_;
   my $err= ssl_get_error();
   croak "$message: $err" if length $err;
   return;
}

1;
