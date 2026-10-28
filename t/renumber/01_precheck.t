#!/usr/bin/perl
# Pré-checagens do renumber: caminho feliz e cada recusa do plano.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP;
use File::Path qw(make_path);

use lib "$Bin", "$Bin/../../lib";
use MockPve;
use MMPve::Module::Renumber;
use MMPve::Core::Runner;

my $tmp = "$Bin/tmp-pre";
system("rm -rf $tmp") == 0 or die;
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

subtest 'recusa: pending' => sub {
    fresh();
    push @{ $MockPve::S{pending} }, { key => 'memory' };
    my ($r, $by) = pre();
    ok(!$by->{'sem-pending'}{ok}, 'pending detectado');
};

subtest 'recusa: volume órfão do ID novo' => sub {
    fresh();
    $MockPve::S{orphan} = 1;
    my ($r, $by) = pre();
    ok(!$by->{'sem-volumes-orfaos'}{ok}, 'órfão detectado');
    like($by->{'sem-volumes-orfaos'}{detail}, qr/vm-1100/, 'detalha volid');
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

subtest 'recusa: storage sem rename' => sub {
    fresh();
    $MockPve::S{storage_types} = [ { storage => 'zfs1', type => 'iscsi' } ];
    my ($r, $by) = pre();
    ok(!$by->{drives}{ok}, 'storage sem rename recusa');
    like($by->{drives}{detail}, qr/rename/, 'explica o motivo');
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
