#!/usr/bin/perl

use strict;
use warnings;
use 5.010;

use IO::Async::Loop;
use IO::Async::Timer::Periodic;

use Net::Async::HTTP::Server::PSGI;
use Net::Async::Matrix;

use Net::Prometheus;

use HTTP::Response;

use List::Util 1.29 qw( pairmap max sum );
use Struct::Dumb;
use Time::HiRes qw( time gettimeofday tv_interval );
use YAML qw( LoadFile );

my $CONFIG = LoadFile( "mon.yaml" );

$CONFIG->{send_deadline} //= 5;
$CONFIG->{recv_deadline} //= 20;

$CONFIG->{interval} //= 30;

$CONFIG->{metrics_port} //= 8090;

$CONFIG->{horizon} //= "10m";

my $HORIZON = $CONFIG->{horizon};

my $BUCKETS = $CONFIG->{buckets};

# convert units
$HORIZON =~ m/^(\d+)m$/ and $HORIZON = $1 * 60;

struct Stat => [qw( timestamp points )];
my @stats;

my $loop = IO::Async::Loop->new;

my $matrix = Net::Async::Matrix->new(
   server => $CONFIG->{homeserver},
);
$loop->add( $matrix );

my $prometheus = Net::Prometheus->new;

# Register the metrics

my $group = $prometheus->new_metricgroup( namespace => "matrixmon" );

my $attempts = $group->new_counter(
   name => "attempts_total",
   help => "Count of roundtrip attempts made",
);
my $send_failures = $group->new_counter(
   name => "send_failures_total",
   help => "Count of send attempts that never succeed",
);
my $recv_failures = $group->new_counter(
   name => "recv_failures_total",
   help => "Count of receive attempts that never succeed",
);

my $send_rtt_histogram = $group->new_histogram(
   name => "send_rtt_seconds",
   help => "Distribution of send round-trip time",
   buckets => $BUCKETS,
);
my $recv_rtt_histogram = $group->new_histogram(
   name => "recv_rtt_seconds",
   help => "Distribution of receive round-trip time",
   buckets => $BUCKETS,
);

my $horizon = $CONFIG->{horizon};

$group->new_gauge(
   name => "send_rtt_seconds_max$horizon",
   help => "Maximum send round-trip time observed recently",
)->set_function( sub {
   max( map { $_->points->{send_rtt} } @stats )
});
$group->new_gauge(
   name => "recv_rtt_seconds_max$horizon",
   help => "Maximum receive round-trip time observed recently",
)->set_function( sub {
   max( map { $_->points->{recv_rtt} } @stats )
});

$loop->add( my $server = Net::Async::HTTP::Server::PSGI->new(
   app => $prometheus->psgi_app,
));

$server->listen(
   socktype => 'stream',
   service => $CONFIG->{metrics_port}
)->get;

say "Listening for metrics on http://[::0]:" . $server->read_handle->sockport;

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
            Future->done( tv_interval( $start ) );
         }),

         $loop->delay_future( after => $CONFIG->{send_deadline} )->then( sub {
            $send_failures->inc;
            Future->done( undef );
         }),
      ),

      # Recv RTT
      Future->needs_any(
         $recv_f->then( sub {
            Future->done( tv_interval( $start ) );
         }),

         $loop->delay_future( after => $CONFIG->{recv_deadline} )->then( sub {
            $recv_failures->inc;
            Future->done( undef );
         }),
      ),
   )->then( sub {
      my ( $send_rtt, $recv_rtt ) = @_;

      say +( defined $send_rtt ? "Sent in $send_rtt" : "Send timed out" ),
         "; ",
           ( defined $recv_rtt ? "received in $recv_rtt" : "receive timed out" );

      $attempts->inc;

      $send_rtt_histogram->observe( $send_rtt ) if defined $send_rtt;
      $recv_rtt_histogram->observe( $recv_rtt ) if defined $recv_rtt;

      my $now = time();

      push @stats, Stat( $now, {
         send_rtt => $send_rtt,
         recv_rtt => $recv_rtt,
      });

      # Expire old ones
      shift @stats while @stats and $stats[0]->timestamp < ( $now - $HORIZON );

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
