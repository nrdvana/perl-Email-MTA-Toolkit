=item ehlo

  $request= $server->ehlo($domain); # sets $self->client_domain
  $request= $server->ehlo;          # uses $self->client_domain

=cut

sub ehlo {
   my ($self, $domain)= @_;
   $domain //= $self->client_helo // $self->client_domain // $self->client_address;
   my $ret= $self->send_command(EHLO => ( domain => $domain ));
   $self->client_helo($ret->domain);
   return $ret;
}

1;
