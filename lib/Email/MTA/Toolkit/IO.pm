package Email::MTA::Toolkit::IO;
use Exporter::Extensible -exporter_setup => 1;

sub new_iobuf :Export {
   unshift @_, 'handle'
      if @_ == 1 && ref $_[0] && $_[0]->can('sysread');
   require Email::MTA::Toolkit::IO::BufferedHandle;
   Email::MTA::Toolkit::IO::BufferedHandle->new(@_)
}

sub coerce_io :Export {
   my $x= shift;
   if (ref $x && (
         $x->can('ibuf') && $x->can('fetch')
      || $x->can('obuf') && $x->can('flush')
   )) {
      return $x;
   }
   elsif (ref $x && $x->can('sysread')) {
      require Email::MTA::Toolkit::IO::BufferedHandle;
      Email::MTA::Toolkit::IO::BufferedHandle->new(handle => $x);
   }
   else {
      Carp::croak("don't know how to wrap $x as an IO object");
   }
}

1;
