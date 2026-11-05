#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use FindBin qw($Bin);

use lib "$Bin/../../lib", "$Bin/../../perl";
use MMPve::Core::Config;
use MMPve::Core::Runner;
use MMPve::Core::Util qw(write_file_atomic read_file);
use MMPve::Module::Updates;

my $tmp = tempdir('mm-pve-updates-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;
$ENV{MM_PVE_BIN} = '/usr/sbin/mm-pve';
my $active = 1;
my $apt_ok = 1;
my $kernel_output = "install ok installed\tpve-kernel-6.8.0-1-pve\t6.8.0\n"
    . "install ok installed\tpve-kernel-6.8.1-1-pve\t6.8.1\n";
local $MMPve::Core::Runner::OVERRIDE = sub {
    my ($argv) = @_;
    my $cmd = $argv->[0] // '';
    return { ok => 1, rc => 0, out => "6.8.0-1-pve\n", err => '' } if $cmd eq 'uname';
    return { ok => 1, rc => 0, out => $kernel_output, err => '' } if $cmd eq 'dpkg-query';
    if ($cmd eq 'dpkg' && $argv->[1] eq '--compare-versions') {
        return { ok => 1, rc => ($argv->[2] gt $argv->[4] ? 0 : 1), out => '', err => '' };
    }
    return { ok => $active ? 1 : 0, rc => $active ? 0 : 3, out => '', err => '' } if $cmd eq 'systemctl';
    return { ok => 1, rc => 0, out => '', err => '' } if $cmd eq 'systemd-run';
    return { ok => $apt_ok ? 1 : 0, rc => $apt_ok ? 0 : 1, out => "apt output\n", err => $apt_ok ? '' : "apt error\n" }
        if $cmd eq 'apt-get' || $cmd eq 'env';
    return { ok => 1, rc => 0, out => '[]', err => '' };
};

subtest 'defaults e schema estrito' => sub {
    my $def = MMPve::Core::Config->default;
    is($def->{modules}{updates}, 0, 'updates nasce desligado');
    is_deeply($def->{updates}, { job_timeout => 3600, dpkg_lock_timeout => 300, retention => 10 }, 'defaults');
    is(scalar MMPve::Core::Config->validate($def), 0, 'default válido');
    my @bad = MMPve::Core::Config->validate({ updates => { retention => 0 } });
    ok(grep(/retention.*>= 1/, @bad), 'retenção inválida recusada');
    @bad = MMPve::Core::Config->validate({ updates => { unknown => 1 } });
    ok(grep(/chave desconhecida/, @bad), 'chave extra recusada');
};

subtest 'reserva única, unit transitória, log e sucesso' => sub {
    my $job = MMPve::Module::Updates->request_run('node-a', actor => 'admin@pam!token');
    like($job, qr/^[0-9a-f-]{36}$/, 'id do job');
    my $state = decode_json(read_file(MMPve::Module::Updates->state_dir . '/node-a.json'));
    is($state->{requested_by}, 'admin@pam', 'token não vai para o estado');
    is($state->{state}, 'queued', 'estado inicial queued');
    is($state->{unit}, "mm-pve-update-$job", 'unit usa o id completo');
    ok(!eval { MMPve::Module::Updates->request_run('node-a', actor => 'admin@pam'); 1 }, 'segundo job recusado');
    like($@, qr/job ativo/, 'mensagem de reserva');
    ok(MMPve::Module::Updates->run_job('node-a', $job)->{ok}, 'worker conclui');
    my $status = MMPve::Module::Updates->status('node-a', pending_cb => sub { [] });
    is($status->{job}{state}, 'succeeded', 'estado final succeeded');
    is(scalar @{$status->{results}}, 1, 'resultado retido');
    my $log = MMPve::Module::Updates->log_page('node-a', $job, start => 0, limit => 100);
    ok($log->{total} >= 2, 'log paginado');
    unlike(join("\n", @{$log->{lines}}), qr/admin\@pam!token/, 'log não contém token');
};

subtest 'falha vira failed e job perdido vira lost' => sub {
    $apt_ok = 0;
    my $job = MMPve::Module::Updates->request_run('node-b', actor => 'root@pam');
    ok(!MMPve::Module::Updates->run_job('node-b', $job)->{ok}, 'apt falso falha');
    is(MMPve::Module::Updates->status('node-b', pending_cb => sub { [] })->{job}{state}, 'failed', 'failed persistido');
    $apt_ok = 1;
    my $lost = '11111111-1111-4111-8111-111111111111';
    my $state = { id => $lost, node => 'node-c', requested_by => 'root@pam', state => 'running',
        unit => 'mm-pve-update-11111111-1111-4111-8111', created => 'now', log => "$tmp/var/log/mm-pve-tools/updates/$lost.log" };
    write_file_atomic(MMPve::Module::Updates->state_dir . '/node-c.json', encode_json($state));
    $active = 0;
    is(MMPve::Module::Updates->status('node-c', pending_cb => sub { [] })->{job}{state}, 'lost', 'unit inativa vira lost');
    $active = 1;
};

subtest 'kernel e reboot fail-closed' => sub {
    my $s = MMPve::Module::Updates->status('node-d', pending_cb => sub { [] });
    ok($s->{kernel}{reboot_suggested}, 'kernel diferente sugere reboot');
    ok(!eval { MMPve::Module::Updates->reboot_preflight('node-d', confirm => 'outro', pending_cb => sub { [] }); 1 }, 'confirm errado recusa');
    like($@, qr/confirmação/, 'mensagem de confirmação');
    my $ctx = MMPve::Module::Updates->reboot_preflight('node-d', confirm => 'node-d', pending_cb => sub { [] });
    is($ctx->{node}, 'node-d', 'confirm correto aceita preflight');
    my $old = $MMPve::Core::Runner::OVERRIDE;
    my $filtered_output = join('',
        "install ok installed\tproxmox-kernel-helper\t9.0\n",
        "install ok installed\tproxmox-kernel-6.14\t9.0\n",
        "deinstall ok config-files\tproxmox-kernel-6.8.9-1-pve\t6.8.9\n",
        "install ok installed\tproxmox-kernel-6.8.1-1-pve-signed\t6.8.1\n",
        "install ok installed\tpve-kernel-6.8.0-1-pve\t6.8.0\n");
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($argv) = @_;
        return { ok => 1, rc => 0, out => "6.8.0-1-pve\n", err => '' } if $argv->[0] eq 'uname';
        return { ok => 1, rc => 0, out => $filtered_output, err => '' } if $argv->[0] eq 'dpkg-query';
        return $old->($argv);
    };
    my $filtered = MMPve::Module::Updates->status('node-d', pending_cb => sub { [] });
    is(scalar @{$filtered->{kernel}{installed}}, 2, 'só imagens instaladas entram no kernel state');
    is($filtered->{kernel}{newest_installed}{package}, 'proxmox-kernel-6.8.1-1-pve-signed', 'signed image é reconhecida');
    ok($filtered->{kernel}{reboot_suggested}, 'signed image nova sugere reboot');
    $filtered_output = "install ok installed\tpve-kernel-6.8.0-1-pve\t6.8.0\n";
    my $same = MMPve::Module::Updates->status('node-d', pending_cb => sub { [] });
    ok(!$same->{kernel}{reboot_suggested}, 'sem imagem nova não sugere reboot');
};

subtest 'bulk grava apenas lista autorizada e preflight bloqueia sem override' => sub {
    my $fail = sub { return { ok => 0, error => 'HA migrando' } };
    ok(!eval { MMPve::Module::Updates->run_bulk([qw(node-e node-f)], mode => 'sequential', actor => 'root@pam', preflight_cb => $fail); 1 }, 'preflight bloqueia');
    my $ok = MMPve::Module::Updates->run_bulk(['node-e', 'node-e', 'node-f'], mode => 'parallel', actor => 'root@pam', override => 1,
        preflight_cb => $fail);
    is_deeply($ok->{nodes}, [qw(node-e node-f)], 'lista deduplicada é a autorizada');
    is($ok->{mode}, 'parallel', 'modo paralelo persistido');
    my $bulk = MMPve::Module::Updates->status('node-e', pending_cb => sub { [] })->{bulk};
    ok($bulk && !$bulk->{orchestrator_lost}, 'heartbeat do orquestrador aparece no status');
};

subtest 'preflight pvesh recusa desconhecido e Ceph ruim' => sub {
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($argv) = @_;
        return { rc => 0, out => '[{"type":"node","name":"known","online":1}]', err => '' }
            if $argv->[0] eq 'pvesh' && $argv->[2] eq '/cluster/status';
        return { rc => 0, out => '{"health":{"status":"HEALTH_WARN"}}', err => '' }
            if $argv->[0] eq 'pvesh' && $argv->[2] eq '/cluster/ceph/status';
        return { rc => 0, out => '[]', err => '' };
    };
    ok(!eval { MMPve::Module::Updates->run_bulk(['missing'], actor => 'root@pam'); 1 }, 'node desconhecido recusa antes do bulk');
    like($@, qr/desconhecido/, 'motivo do node desconhecido');
    ok(!eval { MMPve::Module::Updates->run_bulk(['known'], actor => 'root@pam'); 1 }, 'Ceph ruim recusa o bulk');
    like($@, qr/Ceph/, 'motivo do Ceph');
    my $forced = MMPve::Module::Updates->run_bulk(['known'], actor => 'root@pam', override => 1,
        preflight_cb => sub { die "preflight: Ceph não está HEALTH_OK\n" });
    is($forced->{preflight}{ok}, 0, 'override mantém o resultado do preflight');
    my $forced_state = decode_json(read_file(MMPve::Module::Updates->state_dir . '/bulk-' . $forced->{bulk_id} . '.json'));
    is($forced_state->{override}, 1, 'override fica registrado no bulk');
};

subtest 'heartbeat durante espera e retenção de jobs/bulks' => sub {
    my ($cfg, $digest) = MMPve::Core::Config->load();
    $cfg->{updates}{retention} = 1;
    MMPve::Core::Config->save($cfg, digest => $digest);
    my $bulk = MMPve::Module::Updates->run_bulk(['node-h'], mode => 'parallel', actor => 'root@pam',
        override => 1, preflight_cb => sub { { ok => 1 } });
    my $bulk_path = MMPve::Module::Updates->state_dir . '/bulk-' . $bulk->{bulk_id} . '.json';
    my $bulk_state = decode_json(read_file($bulk_path));
    $bulk_state->{heartbeat_epoch} = time - 1000;
    write_file_atomic($bulk_path, encode_json($bulk_state));
    my $wait = MMPve::Module::Updates->_wait_for_node('node-h', bulk_path => $bulk_path,
        heartbeat_interval => 0, timeout => 0);
    is($wait->{state}, 'timed_out', 'espera expira sem declarar o job perdido');
    my $touched = decode_json(read_file($bulk_path));
    ok($touched->{heartbeat_epoch} > $bulk_state->{heartbeat_epoch}, 'heartbeat atualizado durante espera');
    my @bulk_files = glob(MMPve::Module::Updates->state_dir . '/bulk-*.json');
    is(scalar @bulk_files, 1, 'bulk antigos são podados');
    my $old_log;
    for my $i (1 .. 2) {
        my $job = MMPve::Module::Updates->request_run('node-ret', actor => 'root@pam');
        my $before = decode_json(read_file(MMPve::Module::Updates->state_dir . '/node-ret.json'));
        $old_log = $before->{log} if $i == 1;
        MMPve::Module::Updates->run_job('node-ret', $job);
    }
    my @history = glob(MMPve::Module::Updates->state_dir . '/node-ret-*.json');
    is(scalar @history, 1, 'jobs antigos são podados');
    my $current = decode_json(read_file(MMPve::Module::Updates->state_dir . '/node-ret.json'));
    ok(-f $current->{log}, 'log do job mantido mais recente existe');
    ok(!-e $old_log, 'log do job podado também é removido');
};

done_testing();
