
has '+server_ehlo_keywords' => ( default => sub { +{} } );

has on_handshake => ( is => 'rw' );


=item handle_cmd_EHLO

This sets the C<client_domain> attribute and clears any current transaction,
and runs the C<on_handshake> callback (if set).  Then it returns a 250 reply
including all the keywords in the L</ehlo_keywords> attribute.

=cut

sub handle_cmd_EHLO {
   my ($self, $command)= @_;
   $self->client_helo($command->{domain}) if defined $command->{domain};
   $self->clear_mail_transaction;
   if ($self->listeners->{handshake}) {
      $self->on_handshake->($self, $command);
   }
   my $domain= $self->server_helo // $self->server_domain // '['.$self->server_address.']';
   my @ret= ( 250, $domain );
   for (sort keys %{ $self->ehlo_keywords }) {
      my ($k, $v)= ($_, $self->ehlo_keywords->{$_});
      push @ret, join ' ', $_,
         ref $v eq 'ARRAY'? @$v
         : defined $v && length $v? ($v)
         : ();
   }
   return \@ret;
}

1;
