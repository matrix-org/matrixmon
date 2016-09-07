#!/usr/bin/perl

use strict;
use warnings;
use 5.010;

use IO::Async::Loop;
use IO::Async::Timer::Periodic;

use Net::Async::HTTP::Server;
use Net::Async::Matrix;

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

my $loop = IO::Async::Loop->new;

my $matrix = Net::Async::Matrix->new(
   server => $CONFIG->{homeserver},
);
$loop->add( $matrix );

$loop->add( my $server = Net::Async::HTTP::Server->new(
   on_request => sub {
      my ( undef, $req ) = @_;

      my $response = HTTP::Response->new( 200 );

      $response->add_content(
         join "", pairmap {
            my $value = $b // "Nan";
            "$a $value\n"
         } gen_stats()
      );

      $response->content_type( "text/plain" );
      $response->content_length( length $response->content );

      $req->respond( $response );
   },
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

my $attempts = 0;

my $last_send_rtt;
my $last_recv_rtt;

my $send_failures = 0;
my $recv_failures = 0;

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
            $send_failures++;
            Future->done( undef );
         }),
      ),

      # Recv RTT
      Future->needs_any(
         $recv_f->then( sub {
            Future->done( tv_interval( $start ) );
         }),

         $loop->delay_future( after => $CONFIG->{recv_deadline} )->then( sub {
            $recv_failures++;
            Future->done( undef );
         }),
      ),
   )->then( sub {
      my ( $send_rtt, $recv_rtt ) = @_;

      say +( defined $send_rtt ? "Sent in $send_rtt" : "Send timed out" ),
         "; ",
           ( defined $recv_rtt ? "received in $recv_rtt" : "receive timed out" );

      $attempts++;
      $last_send_rtt = $send_rtt;
      $last_recv_rtt = $recv_rtt;

      push_stats(
         send_rtt => $send_rtt,
         recv_rtt => $recv_rtt,
      );

      Future->done;
   })->on_ready( sub {
      delete $txns{$txn_id};
   });
}

struct Stat => [qw( timestamp points )];
my @stats;

my %totals; # {$name} => $total
my %counts; # {$name} => $count
my %bucketed_counts; # {#name}{$bucket} => $count

sub push_stats
{
   my %stats = @_;

   my $now = time();

   push @stats, Stat( $now, \%stats );

   # Expire old ones
   shift @stats while @stats and $stats[0]->timestamp < ( $now - $HORIZON );

   foreach my $name ( keys %stats ) {
      next unless defined $stats{$name};
      my $value = $stats{$name};

      $totals{$name} += $value;
      $counts{$name} += 1;

      # Increment /all/ of the buckets whose bounds are at least the value
      foreach my $bucket ( @$BUCKETS ) {
         # Initialise the counters to zero so the first time we report we'll
         # create all the buckets, even if they're zero. This is politer on
         # prometheus
         $bucketed_counts{$name}{$bucket} //= 0;

         $bucketed_counts{$name}{$bucket} += 1 if $bucket >= $value;
      }
   }
}

sub nsort { sort { $a <=> $b } @_ }

sub _gen_bucket_stats
{
   my ( $name ) = @_;
   my $buckets = $bucketed_counts{$name};

   return map {
      +qq(${name}_within{le="$_"}), $buckets->{$_}
   } nsort keys %$buckets;
}

sub gen_stats
{
   my $horizon = $CONFIG->{horizon};

   my %values = map {
      my $field = $_;
      $field => [ map {
         my $v = $_->points->{$field};
         defined $v ? ( $v ) : ()
      } @stats ];
   } qw( send_rtt recv_rtt );

   return
      "last_send_rtt", $last_send_rtt,
      "last_recv_rtt", $last_recv_rtt,

      "attempts",      $attempts,
      "send_failures", $send_failures,
      "recv_failures", $recv_failures,

      ( map { +"${_}_${horizon}_max", max( @{ $values{$_} } ) } qw( send_rtt recv_rtt ) ),

      ( map { +"${_}_total", $totals{$_} } keys %totals ),
      ( map { +"${_}_count", $counts{$_} } keys %counts ),
      ( map { _gen_bucket_stats( $_ ) } keys %bucketed_counts ),
}

$loop->add( IO::Async::Timer::Periodic->new(
   interval => $CONFIG->{interval},
   first_interval => 0,

   on_tick => sub { ping() },
)->start );

$loop->run;
