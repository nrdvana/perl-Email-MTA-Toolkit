package Email::MTA::Toolkit::SMTP;
use Moo;
use Carp;

=head1 SYNOPSIS

The Email::MTA::Toolkit::SMTP package provides quick access to the objects
in the ::SMTP namespace.  See individual classes for more details.

The most notable design decision of this SMTP implementation is that it
doesn't require any particular I/O mehanism.  You can read/write blocking
handles, nonblocking handles, or plain buffers that get relayed between
client and server however you like.

High level API, whole messages:
  
  use Email::MTA::Toolkit::SMTP ':all';
  my $server= new_smtp_server(
    io => ..., # any object that implements Email::MTA::Toolkit::IO::IBuf and ::OBuf
    on_message => sub ($self, $mail_transaction) {
      use Data::Printer; p $mail_transaction;
    }
  );
  my $client= new_smtp_client(io => ...);
  my $res= $client->send_message({
    to   => ...,    # envelope address
    from => ...,    # envelope address
    data => $email, # MIME encoded string or Email::MIME 
  });
  # If nonblocking, use your favorite event library here, or pump IO manually...
  while ($res->pending) { $server->handle_io; $client->handle_io; }
  $res->assert_ok;
  
Low level API, SMTP commands:
  
  my $server= new_smtp_server(
    io => ...,
    on_request => sub ($self, $req) {
      # inspect command before default dispatch
      ...
      my $res= $self->dispatch_request($req);
      # inspect response before delivering to client
      ...
      return $res;
    }
  );

  # pump I/O however appropriate for your program inbetween each call
  my $client= new_smtp_client(io => ...);
  $res= $client->ehlo($my_hostname);
  $res= $client->mail($envelope_sender);
  $res= $client->rcpt($envelope_recipient);
  $res= $client->data($email->as_string);

=head1 EXPORTS

=head2 new_smtp_client

Shortcut for L<Email::MTA::Toolkit::SMTP::Client/new> and also loads that module.

=head2 new_smtp_server

Shortcut for L<Email::MTA::Toolkit::SMTP::Server/new> and also loads that module.

=head2 envelope_route

Shortcut for L<Email::MTA::Toolkit::SMTP::EnvelopeRoute/coerce> and also loads that module.

=cut

sub new_smtp_client :Export {
   require Email::MTA::Toolkit::SMTP::Client;
   Email::MTA::Toolkit::SMTP::Client->new(@_);
}

sub new_smtp_server :Export {
   require Email::MTA::Toolkit::SMTP::Server;
   Email::MTA::Toolkit::SMTP::Server->new(@_);
}

sub envelope_route :Export {
   require Email::MTA::Toolkit::SMTP::EnvelopeRoute;
   Email::MTA::Toolkit::SMTP::EnvelopeRoute->coerce(@_);
}

1;
