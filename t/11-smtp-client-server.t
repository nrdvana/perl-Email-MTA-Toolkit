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

subtest simple_message_delivery => sub {
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
   is( $client->state, 'ready', 'client ready' );
   is( $server->state, 'ready', 'server ready' );
   $res= $client->mail_from('username@client.example.com');
   &$do_io;
   ok( $res->is_success, 'client MAIL command' ) or note explain $res;
   $res= $client->rcpt_to('peer@example.com');
   &$do_io;
   ok( $res->is_success, 'client RCPT command' ) or note explain $res;
   $res= $client->data;
   &$do_io;
   ok( $res->is_success, 'client DATA command' ) or note explain $res;
   is( $client->state, 'data', 'client state data' );
   is( $server->state, 'data', 'server state data' );
   ok( $client->write_data(<<'END'), 'write_data' );
To: peer@example.com
From: username@client.example.com
Subject: Test

Foo
.Line starting with dot
. Line starting with dot-space
END
   ok( $client->end_data, 'end_data' );
   &$do_io;
   ok( $res->is_success, 'client DATA command' ) or note explain $res;
   $res= $client->quit;
   &$do_io;
   ok( $res->is_success, 'client QUIT command' ) or note explain $res;
};

done_testing;
