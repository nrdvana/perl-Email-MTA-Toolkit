#! /usr/bin/env perl
use Test2::V0;
use Email::MTA::Toolkit::SMTP::Request;

my $CLASS= 'Email::MTA::Toolkit::SMTP::Request';

my @tests= (
   [ 'HELO example.com' => 'HELO example.com' ],
   [ 'EHLO example.com' => 'EHLO example.com' ],
   [ 'MAIL FROM:<foo@example.com>' => 'MAIL FROM:<foo@example.com>' ],
   [ 'RCPT TO:<bar@example.com>'   => 'RCPT TO:<bar@example.com>' ],
   [ 'QUIT' => 'QUIT' ],
);

for (@tests) {
   my ($orig, $canonical)= @$_;
   my ($msg, $err)= $CLASS->parse($orig."\r\n");
   is( (defined $msg? "$msg" : $err), $canonical, $orig );
}

done_testing;
