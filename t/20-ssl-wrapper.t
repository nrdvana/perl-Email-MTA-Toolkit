#! /usr/bin/perl
use strict;
use warnings;
use FindBin;
use Test::More;

use Email::MTA::Toolkit::SSL;
use Email::MTA::Toolkit::SSL::Context;
use Email::MTA::Toolkit::SSL::Session;

my $data_dir= "$FindBin::RealBin/data";

my $ctx= new_ok( 'Email::MTA::Toolkit::SSL::Context' );
ok( $ctx->set_private_key_file("$data_dir/cert.key"), 'set key' );
ok( $ctx->set_certificate_file("$data_dir/cert.crt"), 'set cert' );

my $server= new_ok( 'Email::MTA::Toolkit::SSL::Session', [ context => $ctx ] );
undef $ctx;

my $client= new_ok( 'Email::MTA::Toolkit::SSL::Session', [ context => Email::MTA::Toolkit::SSL::Context->new ] );

my $client_in=  Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
my $client_out= Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
my $server_in=  Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
my $server_out= Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
sub relay_io {
   my ($data, $data2);
   do {
      $data= Net::SSLeay::BIO_read($server_out) // '';
      Net::SSLeay::BIO_write($client_in, $data) if length $data;
      $data2= Net::SSLeay::BIO_read($client_out) // '';
      Net::SSLeay::BIO_write($server_in, $data2) if length $data2;
   } while (length($data) + length($data2));
}

$server->set_bio($server_in, $server_out);
$client->set_bio($client_in, $client_out);
$server->set_accept_state;
$client->set_connect_state;
relay_io();
$server->write("Test");
relay_io();
printf "client state = %s, server state = %s\n", $client->state, $server->state;
printf "client peer cert = %s, server cert = %s\n", $client->peer_certificate, $server->certificate;
is( $client->read(), "Test" );


undef $server;
undef $client;

done_testing;
