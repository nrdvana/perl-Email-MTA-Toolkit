#! /usr/bin/env perl
use Test::More;
use Socket;
use Log::Any::Adapter 'TAP';
use Email::MTA::Toolkit::SMTP::Protocol;
use Email::MTA::Toolkit::SMTP::Server;
use Email::MTA::Toolkit::SMTP::Client;

subtest simple_helo_session => sub {
   socketpair(my $client_sock, my $server_sock, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
      or die "socketpair: $!";
   $client_sock->blocking(0);
   $server_sock->blocking(0);
   my $client= new_ok( 'Email::MTA::Toolkit::SMTP::Client', [ io => $client_sock ] );
   my $server= new_ok( 'Email::MTA::Toolkit::SMTP::Server', [ io => $server_sock, server_domain => 'example.com' ] );
   my $do_io= sub { while ($client->handle_io | $server->handle_io) {} };
   &$do_io;
   my $res= $client->ehlo('client.example.com');
   &$do_io;
   ok( $res->is_success, 'client EHLO command' ) or note explain $res;
   $res= $client->quit;
   &$do_io;
   ok( $res->is_success, 'client QUIT command' ) or note explain $res;
};

done_testing;
