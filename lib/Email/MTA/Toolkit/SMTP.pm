package Email::MTA::Toolkit::SMTP;


=head1 SYNOPSIS

  my $server= Email::MTA::Toolkit::SMTP->new_server;
  my $client= Email::MTA::Toolkit::SMTP->new_client;
  
  # This module doesn't even require a socket!
  # It can talk SMTP and SSL right inside of byte buffers.
  # This leaves you free to use any I/O engine.
  sub do_io {
    $client->io->{rbuf} .= $server->io->{wbuf};
    $server->io->{wbuf}= '';
    $client->process;
    $server->io->{rbuf} .= $client->io->{wbuf};
    $client->io->{wbuf}= '';
    $server->process;
  }
  
  # Highest level API, whole messages
  
  $server->on_message(sub ($self, $mail_msg) {
    use Data::Printer; p $mail_msg;
  });
  my $res= $client->send_message({
    to => ...,      # envelope
    from => ...,    # envelope
    data => $email, # MIME encoded string or Email::MIME 
  });
  do_io while $res->is_pending;
  $res->assert_ok;
  
  # Medium level API, SMTP commands
  
  $server->on_request(sub ($self, $req) {
    my $res= $self->dispatch_request($req);
    if ($req->command eq 'AUTH') {
      $self->data_size_limit(512*1024*1024) if $res->is_success;
    }
    return $res;
  });

  my $res= $client->helo;
  do_io while $res->pending;
  $res->assert_ok;
  $res= $client->mail_from($envelope_sender);
  do_io while $res->pending;
  $res->assert_ok;
  $res= $client->rcpt_to($envelope_recipient);
  do_io while $response->pending;
  $res->assert_ok;
  $res= $client->data($email->as_string);
  do_io while $response->pending;
  $res->assert_ok;
  
  # Low level API, SMTP with manual dispatch
  
  $client->request('HELO client.example.com');
  $server->io->{rbuf} .= $client->io->{wbuf};
  $client->io->{wbuf}= '';
  my $req= $server->parse_request;
  if ($req->command eq 'HELO') {
    $server->respond(250, 'server.example.com Hello client.example.com');
  }
  else {
    $server->dispatch_request($req);
  }
  $client->io->{rbuf} .= $server->io->{wbuf};
  $server->io->{wbuf}= '';
  my $res= $client->parse_response;
  
=cut
