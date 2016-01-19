#!/usr/bin/perl

use strict;
use warnings;
use 5.010;

use IO::Async::Loop;

use Net::Async::Matrix;

use Struct::Dumb;
use Time::HiRes qw( time gettimeofday tv_interval );
use YAML qw( LoadFile );

my $CONFIG = LoadFile( "mon.yaml" );

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

# TODO: Work out how to stop this growing without bounds...
my %txns;

struct Txn => [qw( recv_f )];

$room->configure(
   on_message => sub {
      my ( undef, $member, $content, $event ) = @_;
      my $txn_id = $content->{txn_id};
      my $txn = $txns{$txn_id} or return;
      $txn->recv_f->done( $event );
   },
);

my $txn_id = $next_txn_id++;

my $txn = $txns{$txn_id} = Txn(
   my $recv_f = Future->new,
);

my $start = [ gettimeofday ];

# TODO: deadline, cancellation on failure, etc...

Future->needs_all(
   $room->send_message(
      type => "m.text",
      body => "Ping at " . time(),
      txn_id => $txn_id,
   )->on_done( sub {
      say "Sent in " . tv_interval( $start );
   }),

   $recv_f->on_done( sub {
      say "Received in " . tv_interval( $start );
   }),
)->get;
