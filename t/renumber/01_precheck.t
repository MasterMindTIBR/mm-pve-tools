#!/usr/bin/perl
# Pré-checagens do renumber: caminho feliz e cada recusa do plano.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;
use File::Path qw(make_path);

use lib "$Bin", "$Bin/../../lib", "$Bin/../lib-stubs";
use MockPve;
use MMPve::Module::Renumber;
use MMPve::Core::Runner;
require PVE::Storage;    # stub (ver t/lib-stubs/PVE/Storage.pm) — R2.6 #9

my $tmp = tempdir('mm-pve-renumber-pre-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_ROOT} = "$tmp";

sub fresh {
    MockPve->reset;
    local $MMPve::Core::Runner::OVERRIDE = \&MockPve::handler;   ## no critic
    return;
}

sub pre {
    my (%o) = @_;
    local $MMPve::Core::Runner::OVERRIDE = \&MockPve::handler;   ## no critic
    my $r = MMPve::Module::Renumber->precheck(from => 100, to => 1100, %o);
    my %by = map { $_->{check} => $_ } @{$r->{checks}};
    return ($r, \%by);
}

sub fail_names {
    my ($checks) = @_;
    return map { $_->{check} } grep { !$_->{ok} } @{$checks};
}

subtest 'precheck feliz' => sub {
    fresh();
    my ($r, $by) = pre();
    ok($r->{ok}, 'ok') or diag explain [fail_names($r->{checks})];
    is($r->{info}{node}, 'n1', 'node localizado');
    is_deeply([fail_names($r->{checks})], [], 'nenhuma checagem falhando');
    my %kinds = map { $_->{key} => $_->{kind} } @{$r->{info}{drives}};
    is($kinds{scsi0},    'volume',    'scsi0 volume');
    is($kinds{efidisk0}, 'volume',    'efidisk0 volume');
    is($kinds{ide0},     'copy_line', 'ISO só copia linha');
    is($kinds{ide2},     'cloudinit', 'cloudinit detectado');
    is_deeply([MockPve::ops()], [], 'nenhuma chamada mutante');
};

subtest 'recusa: id novo ocupado' => sub {
    fresh();
    $MockPve::S{nextid_free} = 0;
    my ($r, $by) = pre();
    ok(!$by->{'id-novo-livre'}{ok}, 'nextid recusa');
    like($by->{'id-novo-livre'}{detail}, qr/1100/, 'detalha o ID');
    ok(!$r->{ok}, 'aborta');
    is_deeply([MockPve::ops()], [], 'sem mutações');
};

subtest 'recusa: VM ligada' => sub {
    fresh();
    $MockPve::S{vm_status}{status} = 'running';
    my ($r, $by) = pre();
    ok(!$by->{desligada}{ok}, 'desligada falha');
    ok(!$r->{ok}, 'aborta');
};

subtest 'recusa: lock' => sub {
    fresh();
    $MockPve::S{vm_status}{lock} = 'backup';
    my ($r, $by) = pre();
    ok(!$by->{'sem-lock'}{ok}, 'lock detectado');
};

subtest 'recusa: template' => sub {
    fresh();
    $MockPve::S{vm_config}{template} = 1;
    my ($r, $by) = pre();
    ok(!$by->{'nao-template'}{ok}, 'template detectado');
};

subtest 'recusa: snapshot' => sub {
    fresh();
    push @{ $MockPve::S{snapshots} }, { name => 'snap1' };
    my ($r, $by) = pre();
    ok(!$by->{'sem-snapshots'}{ok}, 'snapshot detectado');
    like($by->{'sem-snapshots'}{detail}, qr/snap1/, 'nomeia o snapshot');
};

subtest 'sem-pending: entradas normais (sem campo pending/delete) não acusam mudança (R2.6 #2)' => sub {
    fresh();
    # GET .../pending devolve UMA entrada por chave de config, sempre (ver
    # PVE::GuestHelpers::config_with_pending_array); só é mudança pendente
    # de verdade se tiver 'pending' (valor novo) ou 'delete' (remoção).
    push @{ $MockPve::S{pending} }, { key => 'memory', value => '2048' };
    push @{ $MockPve::S{pending} }, { key => 'scsi0', value => 'zfs1:vm-100-disk-0,size=20G' };
    my ($r, $by) = pre();
    ok($by->{'sem-pending'}{ok}, 'entradas normais não contam como pendentes')
        or diag explain $by->{'sem-pending'};
    ok($r->{ok}, 'precheck inteiro passa') or diag explain [fail_names($r->{checks})];
};

subtest 'recusa: pending de verdade (campo pending)' => sub {
    fresh();
    push @{ $MockPve::S{pending} }, { key => 'memory', value => '2048', pending => '4096' };
    my ($r, $by) = pre();
    ok(!$by->{'sem-pending'}{ok}, 'pending de verdade detectado');
    like($by->{'sem-pending'}{detail}, qr/memory/, 'nomeia a chave pendente');
};

subtest 'recusa: delete pendente' => sub {
    fresh();
    push @{ $MockPve::S{pending} }, { key => 'scsi1', value => 'zfs1:vm-100-disk-1,size=10G', delete => 1 };
    my ($r, $by) = pre();
    ok(!$by->{'sem-pending'}{ok}, 'delete pendente detectado');
    like($by->{'sem-pending'}{detail}, qr/scsi1/, 'nomeia a chave com delete pendente');
};

subtest 'recusa: volume órfão do ID novo' => sub {
    fresh();
    $MockPve::S{orphan} = 1;
    my ($r, $by) = pre();
    ok(!$by->{'sem-volumes-orfaos'}{ok}, 'órfão detectado');
    like($by->{'sem-volumes-orfaos'}{detail}, qr/vm-1100/, 'detalha volid');
};

subtest 'precheck: erro de API é falha dura, nunca passa escondido (R2.6 #8)' => sub {
    fresh();
    $MockPve::S{api_fail}{'/cluster/status'} = "conexão recusada (simulado)\n";
    my ($r, $by) = pre();
    ok(!$r->{ok}, 'precheck falha de verdade quando a API erra (antes passava escondido)');
    ok(!$by->{'sem-volumes-orfaos'}{ok}, 'o check específico também falha');
    like($by->{'sem-volumes-orfaos'}{detail}, qr/conexão recusada/, 'erro real aparece no detail');
};

subtest 'precheck: erro em snapshot/pending/ha/replicacao também é falha dura (R2.6 #8)' => sub {
    for my $case (
        ['/nodes/n1/qemu/100/snapshot', 'sem-snapshots'],
        ['/nodes/n1/qemu/100/pending',  'sem-pending'],
        ['/cluster/ha/resources',       'ha'],
        ['/cluster/replication',        'replicacao'],
    ) {
        my ($path, $check) = @$case;
        fresh();
        $MockPve::S{api_fail}{$path} = "erro simulado em $path\n";
        my ($r, $by) = pre();
        ok(!$by->{$check}{ok}, "check '$check' falha quando $path erra") or diag explain $by->{$check};
        like($by->{$check}{detail}, qr/erro simulado/, "detail mostra o erro real ($check)");
    }
};

subtest 'recusa: HA sem flag' => sub {
    fresh();
    $MockPve::S{ha} = [{ sid => 'vmid:100', state => 'started' }];
    my ($r, $by) = pre();
    ok(!$by->{ha}{ok}, 'HA bloqueia');
    ok(!$r->{ok}, 'aborta');
    fresh();
    $MockPve::S{ha} = [{ sid => 'vmid:100', state => 'started' }];
    ($r, $by) = pre(handle_ha => 1);
    ok($by->{ha}{ok}, 'flag --handle-ha deixa passar');
    ok($r->{ok}, 'ok com flag') or diag explain [fail_names($r->{checks})];
    ok(grep { /HA/ } @{$r->{warnings}}, 'avisa sobre HA');
};

subtest 'recusa: replicação sem flag' => sub {
    fresh();
    $MockPve::S{repl} = [{ id => 'rep1', guest => 100, target => 'n2' }];
    my ($r, $by) = pre();
    ok(!$by->{replicacao}{ok}, 'replicação bloqueia');
    fresh();
    $MockPve::S{repl} = [{ id => 'rep1', guest => 100, target => 'n2' }];
    ($r, $by) = pre(handle_replication => 1);
    ok($by->{replicacao}{ok}, 'flag --handle-replication deixa passar');
    ok($r->{ok}, 'ok com flag') or diag explain [fail_names($r->{checks})];
    ok(grep { /sync COMPLETO/i } @{$r->{warnings}}, 'avisa sync completo');
};

subtest 'recusa: storage sem feature rename (volume_has_feature retorna falso) — R2.6 #9' => sub {
    fresh();
    local $PVE::Storage::FEATURE_OVERRIDE{'rename:zfs1'} = 0;
    my ($r, $by) = pre();
    ok(!$by->{drives}{ok}, 'storage sem rename recusa');
    like($by->{drives}{detail}, qr/rename/, 'explica o motivo');
};

subtest 'aceita: storage com tipo "sem rename" na lista antiga, mas feature real diz que sim — R2.6 #9' => sub {
    fresh();
    # tipo iscsi era recusado pela allow-list fixa antiga; agora quem manda
    # é PVE::Storage::volume_has_feature (ex.: LVM/RBD que suportam rename).
    $MockPve::S{storage_types} = [ { storage => 'zfs1', type => 'iscsi' } ];
    local $PVE::Storage::FEATURE_OVERRIDE{'rename:zfs1'} = 1;
    my ($r, $by) = pre();
    ok($by->{drives}{ok}, 'tipo de storage não decide mais sozinho; feature real manda')
        or diag explain $by->{drives};
};

subtest 'recusa: storage ausente' => sub {
    fresh();
    $MockPve::S{storage_types} = [];
    my ($r, $by) = pre();
    ok(!$by->{drives}{ok}, 'storage ausente recusa');
};

subtest 'esquema vmid_scheme' => sub {
    fresh();
    my $dir = $ENV{MM_PVE_CONFIG_DIR};
    make_path($dir);
    open(my $fh, '>', "$dir/config.json") or die $!;
    print $fh encode_json({
        revision => 1,
        modules  => { renumber => 1, restore => 0, branding => 0 },
        vmid_scheme => [{ label => 'Produção', from => 1000, to => 1999 }],
        restore => { session_default_hours => 24, session_max_hours => 72, max_sessions => 10 },
        branding => {},
    });
    close $fh;

    my ($r, $by) = pre();
    ok($r->{ok}, '1100 dentro do esquema') or diag explain [fail_names($r->{checks})];

    ($r, $by) = pre(to => 500);
    ok(!$r->{ok}, '500 fora aborta');
    ok(!$by->{esquema}{ok}, 'check esquema falha');
    ok(grep { /fora do esquema/ } @{$r->{warnings}}, 'aviso de esquema');

    ($r, $by) = pre(to => 500, force_scheme => 1);
    ok($r->{ok}, 'force-scheme continua') or diag explain [fail_names($r->{checks})];
    ok(grep { /fora do esquema/ } @{$r->{warnings}}, 'aviso continua com force');
    unlink "$dir/config.json";
};

subtest 'recusa: VM não existe' => sub {
    fresh();
    $MockPve::S{vmid} = 999;
    my ($r, $by) = pre();
    ok(!$by->{'vm-existe'}{ok}, 'VM ausente detectada');
    ok(!$r->{ok}, 'aborta');
};

subtest 'plano: ordem dos passos' => sub {
    fresh();
    my @plan = map { $_->{step} } MMPve::Module::Renumber->plan;
    is_deeply(\@plan,
        [qw(reserve move_disks config firewall refs verify destroy)],
        'ordem do plano');
};

done_testing();
