#! /usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Socket;
use Email::MTA::Toolkit::IO 'iobuf';

subtest socket_io => sub {
	socketpair(my $client, my $server, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
		or die "socketpaair: $!";
	$client->blocking(0);
	$server->blocking(0);
	my $client_io= iobuf($client);
	my $server_io= iobuf($server);
	$client_io->obuf .= "Test";
	is( $client_io->flush, 4, "client flush" );
	is( $server_io->fetch, 4, "server fill" );
	is( $server_io->ibuf, "Test", 'server read "Test"');
};

done_testing;
