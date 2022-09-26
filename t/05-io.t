#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Socket;
use Email::MTA::Toolkit::IO;

my $class= 'Email::MTA::Toolkit::IO';

subtest socket_io => sub {
	socketpair(my $client, my $server, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
		or die "socketpaair: $!";
	$client->blocking(0);
	$server->blocking(0);
	my $client_io= new_ok( $class, [ src => $client, dst => $client ] );
	my $server_io= new_ok( $class, [ src => $server, dst => $server ] );
	$client_io->wbuf .= "Test";
	is( $client_io->flush, 4, "client flush" );
	is( $server_io->fill, 4, "server fill" );
	is( $server_io->rbuf, "Test", 'server read "Test"');
};

done_testing;
