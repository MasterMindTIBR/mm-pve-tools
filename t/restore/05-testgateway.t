#!/usr/bin/env perl
# test-gateway: selfcheck from gw-restore reporting pass/fail items.
use strict;
use warnings;
use utf8;
use lib 't/restore';
use RestoreTest;
use Test::More;

BEGIN { use_ok('MMPve::Module::Restore') }

my $R = 'MMPve::Module::Restore';
RestoreTest::setup();
local $MMPve::Module::Restore::POLL_DELAY = 0;

local $MMPve::Core::Runner::OVERRIDE = RestoreTest::make_override(
    gw_out => "PASS plugin ntfs3g ok\nPASS PBS reachable\nFAIL token unauthorized\nPASS sysctls ok\n");
my $res = $R->test_gateway;
is($res->{gateway_vmid}, 9000, 'gateway_vmid');
is($res->{node}, 'pvegwdon', 'node do gateway');
is(scalar @{ $res->{items} }, 4, 'quatro itens');
is($res->{items}[0]{ok}, 1, 'item ok');
is($res->{items}[2]{ok}, 0, 'item falho');
like($res->{items}[2]{line}, qr/token/, 'linha do item');

# tudo ok
local $MMPve::Core::Runner::OVERRIDE = RestoreTest::make_override(
    gw_out => "PASS a\nPASS b\n");
$res = $R->test_gateway;
is(scalar(grep { !$_->{ok} } @{ $res->{items} }), 0, 'selfcheck todo verde');

done_testing();
