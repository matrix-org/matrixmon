#!/usr/bin/perl

use strict;
use warnings;
use 5.010;

use IO::Async::Loop;
use IO::Async::Timer::Periodic;

use Net::Async::Matrix;

use Struct::Dumb;
use Time::HiRes qw( time gettimeofday tv_interval );
use YAML qw( LoadFile );

my $CONFIG = LoadFile( "mon.yaml" );

$CONFIG->{send_deadline} //= 5;
$CONFIG->{recv_deadline} //= 20;

$CONFIG->{interval} //= 30;

my $loop = IO::Async::Loop->new;

my $matrix = Net::Async::Matrix->new(
   server => $CONFIG->{homeserver},
);
$loop->add( $matrix );

say "Logging in to $CONFIG->{homeserver} as $CONFIG->{user_id}...";

$matrix->login(
   user_id  => $CONFIG->{user_id},
   password => $CONFIG->{password},
)->get;

say "Logged in; fetching room...";

my $room = $matrix->start
   ->then( sub { $matrix->join_room( $CONFIG->{room_id} ) } )
   ->get;

say "Got room";

my $next_txn_id;

my %txns;

struct Txn => [qw( recv_f f )];

$room->configure(
   on_message => sub {
      my ( undef, $member, $content, $event ) = @_;
      my $txn_id = $content->{txn_id};
      my $txn = $txns{$txn_id} or return;
      $txn->recv_f->done( $event );
   },
);

sub ping
{
   my $txn_id = $next_txn_id++;

   my $txn = $txns{$txn_id} = Txn(
      my $recv_f = Future->new,
      undef,
   );

   my $start = [ gettimeofday ];

   # TODO: cancellation on failure, etc...

   $txn->f = Future->needs_all(
      # Send RTT
      Future->needs_any(
         $room->send_message(
            type => "m.text",
            body => "Ping at " . time(),
            txn_id => $txn_id,
         )->then( sub {
            my $rtt = tv_interval( $start );
            say "Sent in $rtt";
            Future->done( $rtt );
         }),

         $loop->delay_future( after => $CONFIG->{send_deadline} )->then( sub {
            say "Send deadline exceeded";
            Future->done( undef );
         }),
      ),

      # Recv RTT
      Future->needs_any(
         $recv_f->then( sub {
            my $rtt = tv_interval( $start );
            say "Received in $rtt";
            Future->done( $rtt );
         }),

         $loop->delay_future( after => $CONFIG->{recv_deadline} )->then( sub {
            say "Receive deadline exceeded";
            Future->done( undef );
         }),
      ),
   )->then( sub {
      my ( $send_rtt, $recv_rtt ) = @_;
      say "TODO: roll RTTs into moving average (send=$send_rtt recv=$recv_rtt)";

      Future->done;
   })->on_ready( sub {
      delete $txns{$txn_id};
   });
}

$loop->add( IO::Async::Timer::Periodic->new(
   interval => $CONFIG->{interval},
   first_interval => 0,

   on_tick => sub { ping() },
)->start );

$loop->run;
