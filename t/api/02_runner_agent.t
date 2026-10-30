#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use JSON::PP qw(decode_json encode_json);
use lib "$Bin";
use TestAPI;
use Test::More;

TestAPI::setup_inc();
my ($real, $why) = TestAPI::real_pve();
plan skip_all => "PVE real não disponível: $why" unless $real;

require MMPve::Core::Runner;
require MMPve::Module::Restore;
my $upid = MMPve::Core::Runner->extract_upid(TestAPI::fixture('move-disk-reassign.stdout'));
is($upid, 'UPID:node1:0002FC33:00556E41:6AE4E513:qmmove:9000-scsi0>9001-scsi0:root@pam:',
    'extrai a última UPID do output misto sem perder >');
ok(MMPve::Module::Restore->can('result_key_for_upid'), 'módulo restore carregado');

my @argv;
my $status_count = 0;
{
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($cmd) = @_;
        @argv = @$cmd;
        return { rc => 0, out => TestAPI::fixture('agent-exec-ok.stdout') } if $cmd->[1] eq 'create';
        $status_count++;
        return { rc => 0, out => $status_count == 1
            ? TestAPI::fixture('agent-exec-status-running.stdout')
            : TestAPI::fixture('agent-exec-status-exited.stdout') };
    };
    local $MMPve::Module::Restore::POLL_DELAY = 0;
    my $out = MMPve::Module::Restore->gw_exec('node1', 9000, ['gw-restore', 'selfcheck'], timeout => 2,
        input_data => { contract => 1, note => 'sem segredo' });
    is($out, "ola \r\n", 'gw_exec lê out-data do status real');
    unlike(join(' ', @argv), qr/password|secret|token/i, 'input-data não contém segredo');
}

{
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($cmd) = @_;
        return { rc => 0, out => TestAPI::fixture('agent-exec-ok.stdout') } if $cmd->[1] eq 'create';
        return { rc => 0, out => TestAPI::fixture('agent-exec-status-failed.stdout') };
    };
    eval { MMPve::Module::Restore->gw_exec('node1', 9000, ['gw-restore', 'selfcheck'], timeout => 2) };
    like($@, qr/gw-restore falhou \(exit 3\)/, 'gw_exec propaga exitcode real');
    unlike($@, qr/password|secret/i, 'erro não vaza segredo');
}

{
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($cmd) = @_;
        return { rc => 0, out => TestAPI::fixture('agent-exec-ok.stdout') } if $cmd->[1] eq 'create';
        return { rc => 0, out => TestAPI::fixture('agent-exec-status-running.stdout') };
    };
    local $MMPve::Module::Restore::POLL_DELAY = 0;
    eval { MMPve::Module::Restore->gw_exec('node1', 9000, ['gw-restore', 'selfcheck'], timeout => 0) };
    like($@, qr/timeout .*esperando o gateway/, 'gw_exec limita poll que nunca termina');
}

done_testing();
