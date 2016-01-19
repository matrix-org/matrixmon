#!/usr/bin/perl

use strict;
use warnings;
use 5.010;

use IO::Async::Loop;

use Net::Async::Matrix;

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

$room->configure(
   on_message => sub {
      my ( undef, $member, $content ) = @_;
      say "Received message $content->{body}";
   },
);

$room->send_message( "Ping at " . time() )->get;

$loop->delay_future( after => 20 )->get;
