package Email::MTA::Toolkit::SMTP::Response;
use Moo;
use Carp;
use overload '""' => \&render;

has protocol => ( is => 'rw', required => 1 );
has code     => ( is => 'rw' );
has messages => ( is => 'rw' );

sub render {
   my $self= shift;
   return $self->protocol->render_response($self);
}

sub TO_JSON {
   my $ret= { %{$_[0]} };
   delete $ret->{protocol};
   $ret;
}

1;
