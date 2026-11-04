#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json encode_json);
use POSIX qw(_exit WEXITSTATUS);
use lib "$Bin", "$Bin/../restore";
use TestAPI;
use RestoreTest;
use Test::More;

TestAPI::setup_inc();
my ($real, $why) = TestAPI::real_pve();
plan skip_all => "PVE real não disponível: $why" unless $real;

require MMPve::Core::Config;
require MMPve::Module::Restore;
my $R = 'MMPve::Module::Restore';

my $tmp = tempdir('mm-api-restore-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_ROOT} = "$tmp/root";
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/cfg";
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;
my $cfg = MMPve::Core::Config->default;
$cfg->{restore} = {
    gateway_vmid => 9000,
    vlans => { 120 => { gw_ip => '10.20.120.250', prefix => 24 } },
    session_default_hours => 24,
    session_max_hours => 168,
    max_sessions => 3,
};
MMPve::Core::Config->save($cfg);

my $upid = 'UPID:node1:0002FC33:00556E41:6AE4E513:qmmove:9000-scsi0>9001-scsi0:root@pam:';
my $key = $R->result_key_for_upid($upid);
like($key, qr/^[a-f0-9]{64}$/, 'result_key é SHA-256 hexadecimal');
unlike($key, qr/[:>]/, 'result_key não contém a UPID');
$R->save_result($key, 'owner@pve', { password => 'secret', unc => 'u' });
my $file = "$ENV{MM_PVE_ROOT}/run/mm-pve-tools/results/$key.json";
ok(-f $file, 'resultado salvo sob nome opaco');
eval { $R->fetch_result($key, 'intruder@pve') };
like($@, qr/RESULT_FORBIDDEN|só o dono/, 'não-dono recebe recusa');
ok(-f $file, 'recusa não consome nem bloqueia resultado');

my $pid1 = fork();
die "fork falhou\n" unless defined $pid1;
if (!$pid1) {
    eval { $R->fetch_result($key, 'owner@pve') };
    _exit($@ ? 1 : 0);
}
my $pid2 = fork();
die "fork falhou\n" unless defined $pid2;
if (!$pid2) {
    eval { $R->fetch_result($key, 'owner@pve') };
    _exit($@ ? 1 : 0);
}
waitpid($pid1, 0);
my $rc1 = WEXITSTATUS($?);
waitpid($pid2, 0);
my $rc2 = WEXITSTATUS($?);
is($rc1 + $rc2, 1, 'duas leituras autorizadas: exatamente uma vence');

my $pending_key = $R->result_key_for_upid('UPID:node1:pending:root@pam:');
$R->register_pending_result($pending_key, 'UPID:node1:pending:root@pam:', 'owner@pve');
eval { $R->fetch_result($pending_key, 'owner@pve') };
like($@, qr/RESULT_UNFINISHED/, 'tarefa sem resultado ainda está 503-pendente');
my $old = "$ENV{MM_PVE_ROOT}/run/mm-pve-tools/results/$pending_key.pending";
utime(time - 7200, time - 7200, $old);
is($R->gc_results(ttl => 3600), 1, 'gc remove pending expirado');

my $path = RestoreTest::b64('/drive-scsi1.img.fidx/part/2/Dados/Financeiro');
my $backup = 'pbs1:backup/vm/100/2026-10-26T02:00:03Z';
my @payloads;
my %sessions;
my @last_command;
my $pid = 7000;
local $MMPve::Core::Runner::OVERRIDE = sub {
    my ($argv) = @_;
    my $cmd = join(' ', @$argv);
    if ($cmd =~ m{/agent/exec(?:\s|$)}) {
        @last_command = grep { defined } map { $argv->[$_] eq '--command' ? $argv->[$_ + 1] : () } 0 .. $#$argv - 1;
        my ($input) = grep { defined } map { $argv->[$_] eq '--input-data' ? $argv->[$_ + 1] : () } 0 .. $#$argv - 1;
        push @payloads, decode_json($input) if defined $input;
        return { rc => 0, out => encode_json({ pid => ++$pid }) };
    }
    if ($cmd =~ /exec-status/) {
        my $out;
        if (($last_command[1] // '') eq 'publish') {
            my $p = $payloads[-1];
            my $id = substr($p->{request_id}, 0, 12);
            $sessions{$p->{request_id}} //= {
                id => "r-$id", target_vmid => $p->{target_vmid}, source_vmid => $p->{source_vmid},
                vlan => $p->{vlan}, vm_ip => $p->{vm_ip}, expires_at => '2026-10-28T10:00:00Z',
            };
            $out = encode_json({ request_id => $p->{request_id}, unc => '\\\\10.20.120.250\\r-' . $id,
                user => 'gwr-' . $id, password => 'gateway-secret', expires_at => '2026-10-28T10:00:00Z' });
        } elsif (($last_command[1] // '') eq 'list') {
            $out = encode_json({ contract => 1, sessions => [values %sessions] });
        } else {
            $out = "ok\n";
        }
        return { rc => 0, out => encode_json({ exited => 1, exitcode => 0,
            'out-data' => $out, 'err-data' => '' }) };
    }
    return { rc => 0, out => encode_json([
        { vmid => 100, node => 'node1', type => 'qemu' },
        { vmid => 150, node => 'node1', type => 'qemu' },
        { vmid => 9000, node => 'gateway', type => 'qemu' },
    ]) } if $cmd =~ /cluster\/resources/;
    if ($cmd =~ /qemu\/(100|150)\/config/) {
        return { rc => 0, out => encode_json({ net1 => 'virtio=AA,bridge=vmbr1,tag=120', tags => '' }) };
    }
    return { rc => 0, out => encode_json({ result => [{ 'ip-addresses' => [
        { 'ip-address-type' => 'ipv4', 'ip-address' => '10.20.120.77' },
    ] }] }) } if $cmd =~ /network-get-interfaces/;
    return { rc => 0, out => 'null' } if $cmd =~ /qemu\/(100|150)\/config/;
    return { rc => 1, out => '', err => "mock sem rota: $cmd" };
};
local $MMPve::Module::Restore::POLL_DELAY = 0;
local $MMPve::Module::Restore::GW_TIMEOUT = 3;
my $original_save = \&MMPve::Module::Restore::save_result;
my $crash = 1;
{
    no warnings 'redefine';
    local *MMPve::Module::Restore::save_result = sub {
        die "simulated crash after gateway\n" if $crash--;
        return $original_save->(@_);
    };
    my $first_key = $R->result_key_for_upid('UPID:node1:publish-100:root@pam:');
    my $failed = eval { $R->publish(backup => $backup, path_b64 => $path, vmid => 100,
        user => 'owner@pve', result_key => $first_key,
        storage_config => { ids => { pbs1 => { datastore => 'bkp01', namespace => '' } } }) };
    ok(!$failed && $@, 'falha simulada depois do publish deixa journal');
    my ($journal) = glob("$ENV{MM_PVE_CONFIG_DIR}/journal/restore-publish-100-*.json");
    ok($journal, 'journal inclui VMID destino');
    my $raw = do { open(my $fh, '<', $journal) or die $!; local $/; <$fh> };
    my $j = decode_json($raw);
    like($j->{meta}{request_id}, qr/^[0-9a-f-]{36}$/, 'request_id UUID no journal');
    is($j->{meta}{vmid}, 100, 'VMID destino no journal');
    unlike($raw, qr/gateway-secret/, 'segredo não entra no journal');
    my $resumed = $R->publish(backup => $backup, path_b64 => $path, vmid => 100,
        user => 'owner@pve', resume => 1, result_key => $first_key,
        storage_config => { ids => { pbs1 => { datastore => 'bkp01', namespace => '' } } });
    ok($resumed->{ok}, 'resume reconcilia a sessão existente');
}
is($payloads[0]{request_id}, $payloads[1]{request_id}, 'resume reutiliza request_id');
is(scalar keys %sessions, 1, 'resume não cria segunda sessão');

my $second_key = $R->result_key_for_upid('UPID:node1:publish-150:root@pam:');
my $second = $R->publish(backup => $backup, path_b64 => $path, vmid => 150,
    user => 'owner@pve', result_key => $second_key,
    storage_config => { ids => { pbs1 => { datastore => 'bkp01', namespace => '' } } });
ok($second->{ok}, 'mesma pasta em outro VMID publica');
is(scalar keys %sessions, 2, 'VMIDs diferentes não compartilham journal/request_id');
isnt($payloads[1]{request_id}, $payloads[2]{request_id}, 'VMIDs diferentes recebem request_id diferente');

done_testing();
