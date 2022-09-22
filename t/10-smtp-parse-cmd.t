#! /usr/bin/env perl
use Test::More;
use Email::MTA::Toolkit::SMTP;

my $smtp= 'Email::MTA::Toolkit::SMTP';

my @tests= (
   [ 'HELO example.com' => 'HELO example.com' ],
   [ 'EHLO example.com' => 'EHLO example.com' ],
   [ 'MAIL FROM:<foo@example.com>' => 'MAIL FROM:<foo@example.com>' ],
   [ 'RCPT TO:<bar@example.com>'   => 'RCPT TO:<bar@example.com>' ],
   [ 'QUIT' => 'QUIT' ],
);

for (@tests) {
   my ($orig, $canonical)= @$_;
   my $req;
   $req= $smtp->parse_cmd_if_complete for $orig."\r\n";
   if ($req->{command}) {
      is_deeply( $smtp->format_cmd($req), $canonical, $orig );
   } else {
      diag explain $req;
      fail( $orig );
   }
}

done_testing;
