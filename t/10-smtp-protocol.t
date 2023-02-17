#! /usr/bin/env perl
use Test::More;
use Email::MTA::Toolkit::SMTP::Protocol;

my $smtp= new_ok( 'Email::MTA::Toolkit::SMTP::Protocol' );

subtest parse_and_render_cmd => sub {
   my @tests= (
      'HELO example.com',
      'EHLO example.com',
      'MAIL FROM:<foo@example.com>',
      'RCPT TO:<bar@example.com>',
      'QUIT',
   );
   for (@tests) {
      my ($orig, $expected)= (ref $_? @$_ : ($_,$_));
      if (ok( my $cmd= $smtp->parse_cmd_if_complete("$orig\r\n"), "parse $orig" )) {
         is( $smtp->render_cmd($cmd), "$orig\r\n", "render $orig" )
            or note explain $cmd;
      } else {
         note explain $cmd;
      }
   }
};

done_testing;
