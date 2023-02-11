#! /usr/bin/perl
use strict;
use warnings;
use FindBin;
use Test::More;
use IO::Select;
use Socket;
use Email::MTA::Toolkit::SSL qw( ssl_get_error new_ssl_context new_ssl_server new_ssl_client new_mem_bio ssl_croak_if_error );
use Log::Any::Adapter 'Stderr';

my $data_dir= "$FindBin::RealBin/data";

subtest bio_mem => sub {
   my $bio= new_mem_bio;
   is( $bio->write("Test"), 4, 'write' );
   is( $bio->read, "Test", 'read' );
   is( $bio->read, undef, 'empty read' );
};

subtest socket_client_server => sub {
	socketpair(my $client_fd, my $server_fd, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
		or die "socketpaair: $!";
   $client_fd->blocking(0);
   $server_fd->blocking(0);

   my $server_ssl= new_ssl_server(
      key  => "$data_dir/cert.key",
      cert => "$data_dir/cert.crt",
      fd   => $server_fd,
   );
   is( $server_ssl->fd, fileno($server_fd), 'server fd' );

   my $client_ssl= new_ssl_client(
      fd   => $client_fd,
   );
   is( $client_ssl->fd, fileno($client_fd), 'client fd' );

   my @sv_script= (
      [ do_handshake => 1 ],
      [ write => 'Test', 1 ],
      [ read => 'Test2' ],
   );
   my @cl_script= (
      [ do_handshake => 1 ],
      [ read => 'Test' ],
      [ write => 'Test2', 1 ],
   );
   while (@sv_script || @cl_script) {
      for ([ $server_ssl, 'server', \@sv_script ], [ $client_ssl, 'client', \@cl_script ]) {
         my ($ssl, $name, $script)= @$_;
         if (@$script) {
            my ($method, @args)= $script->[0]->@*;
            my $expected= pop @args;
            my $ret= $ssl->$method(@args);
            if (defined $ret && $ret >= 0) {
               shift @sv_script;
               is( $ret, $expected, "$name $method(@args)" );
            } else {
               my $err= $server_ssl->get_last_error;
               note "$name $method(@args): ${\($ret || 'undef')} ($err)";
               if ($err == Net::SSLeay::ERROR_SSL()) {
                  fail("ERROR_SSL");
                  die;
               }
            }
         }
      }
   }
   ssl_croak_if_error;
};

#my $server= new_ssl_server(
#   key => "$data_dir/cert.key",
#   cert => "$data_dir/cert.crt"
#);
#isa_ok($ctx, 'Email::MTA::Toolkit::SSL::Session', 'server');
#
#my $client= new_ssl_client();
#isa_ok($ctx, 'Email::MTA::Toolkit::SSL::Session', 'client');
#
##my $client_in=  Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
##my $client_out= Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
##my $server_in=  Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
##my $server_out= Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
##sub relay_io {
##   my ($data, $data2);
##   do {
##      $data= Net::SSLeay::BIO_read($server_out) // '';
##      Net::SSLeay::BIO_write($client_in, $data) if length $data;
##      $data2= Net::SSLeay::BIO_read($client_out) // '';
##      Net::SSLeay::BIO_write($server_in, $data2) if length $data2;
##   } while (length($data) + length($data2));
##}
##
##$server->set_bio($server_in, $server_out);
##$client->set_bio($client_in, $client_out);
#relay_io();
#$server->write("Test");
#relay_io();
#printf "client state = %s, server state = %s\n", $client->state, $server->state;
#printf "client peer cert = %s, server cert = %s\n", $client->peer_certificate, $server->certificate;
#is( $client->read(), "Test" );
#
#
#undef $server;
#undef $client;

done_testing;
