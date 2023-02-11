package Email::MTA::Toolkit::IO;
use Exporter::Extensible -exporter_setup => 1;

sub iobuf :Export {
   if (ref $_[0] && $_[0]->can('sysread')) {
      require Email::MTA::Toolkit::IO::BufferedHandle;
      Email::MTA::Toolkit::IO::BufferedHandle->new(handle => $_[0]);
   }
   else {
      Carp::croak("don't know how to wrap $_[0] as an iobuf");
   }
}

1;
