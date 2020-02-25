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
use POSIX qw( strftime );
use Struct::Dumb;
use Time::HiRes qw( time gettimeofday tv_interval );
use YAML qw( LoadFile );

my $CONFIG;

if (defined $ENV{'MATRIXMON_CONFIG_PATH'}) {
  $CONFIG = LoadFile( $ENV{'MATRIXMON_CONFIG_PATH'} );
} else {
  $CONFIG = LoadFile( "mon.yaml" );
}

$CONFIG->{send_deadline} //= 5;
$CONFIG->{recv_deadline} //= 20;

$CONFIG->{interval} //= 30;

$CONFIG->{metrics_port} //= 8090;

$CONFIG->{horizon} //= "10m";

$CONFIG->{timestamp} //= "[%Y/%m/%d %H:%M:%S]";

# Prefix a timestamp on warnings; useful for logging
my $oldwarn = $SIG{__WARN__};
$SIG{__WARN__} = sub {
   local $SIG{__WARN__} = $oldwarn;
   warn join " ", strftime( $CONFIG->{timestamp}, localtime ), @_;
};

my $HORIZON = $CONFIG->{horizon};

my $BUCKETS = $CONFIG->{buckets};

# convert units
$HORIZON =~ m/^(\d+)m$/ and $HORIZON = $1 * 60;

struct Stat => [qw( timestamp points )];
my @stats;

my $loop = IO::Async::Loop->new;

my $matrix = Net::Async::Matrix->new(
   server => $CONFIG->{homeserver},
   SSL => $CONFIG->{ssl},
   # Just warn so errors don't become fatal to the process
   on_error => sub {
      my ( undef, $message ) = @_;
      warn "NaMatrix failure: $message\n";
   },
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
   max( grep { defined } map { $_->points->{send_rtt} } @stats ) // "Nan"
});
$group->new_gauge(
   name => "recv_rtt_seconds_max$horizon",
   help => "Maximum receive round-trip time observed recently",
)->set_function( sub {
   max( grep { defined } map { $_->points->{recv_rtt} } @stats ) // "Nan"
});

$loop->add( my $server = Net::Async::HTTP::Server::PSGI->new(
   app => $prometheus->psgi_app,
));

$server->listen(
   socktype => 'stream',
   service => $CONFIG->{metrics_port}
)->get;

warn "Listening for metrics on http://[::0]:" . $server->read_handle->sockport . "\n";

warn "Logging in to $CONFIG->{homeserver} as $CONFIG->{user_id}...\n";

my %login_details;
if ($CONFIG->{password}) {
  warn "Using password to do the login...\n";
  %login_details = (
    'user_id' => $CONFIG->{user_id}, 'password' => $CONFIG->{password},
  );
} else {
  warn "Using access_token to do the login...\n";
  %login_details = (
    'user_id' => $CONFIG->{user_id}, 'access_token' => $CONFIG->{access_token},
  );
}
$matrix->login(%login_details)->get;

warn "Logged in; fetching room...\n";

my $room = $matrix->start
   ->then( sub { $matrix->join_room( $CONFIG->{room_id} ) } )
   ->get;

warn "Got room\n";

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

      warn +( defined $send_rtt ? "Sent in $send_rtt" : "Send timed out" ),
         "; ",
           ( defined $recv_rtt ? "received in $recv_rtt" : "receive timed out" ),
           "\n";

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
