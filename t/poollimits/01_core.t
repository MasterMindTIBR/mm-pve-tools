#!/usr/bin/perl -T
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

my ($lib, $perl);
BEGIN {
    ($lib) = "$Bin/../../lib" =~ /\A(.*)\z/s;
    ($perl) = "$Bin/../../perl" =~ /\A(.*)\z/s;
}
use lib $lib, $perl;
use MMPve::Core::Config;
use MMPve::Core::Util qw(write_file_atomic);
use MMPve::Module::Poollimits;

BEGIN {
    package PVE::QemuConfig;
    our $LOAD_CB;
    sub get_derived_property {
        my ($class, $conf, $name) = @_;
        return $conf->{vcpus} || (($conf->{sockets} || 1) * ($conf->{cores} || 1)) if $name eq 'max-cpu';
        return ($conf->{memory} || 0) * 1024 * 1024 if $name eq 'max-memory';
        die "unknown property";
    }
    sub load_config { return $LOAD_CB->($_[1]) if ref($LOAD_CB) eq 'CODE'; return undef }
    $INC{'PVE/QemuConfig.pm'} = __FILE__;
}

require PVE::MMTools::PoolLimits;

my ($tmp) = tempdir('mm-pve-poollimits-XXXXXX', TMPDIR => 1, CLEANUP => 1) =~ /\A(.*)\z/s;
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;
$ENV{PATH} = '/usr/bin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $pool = {
    mode => 'allocated',
    cpu => { enabled => 1, max => 4 },
    memory_mib => { enabled => 1, max => 1024 },
    disk_total_gib => { enabled => 0 },
    disk_storage => { enabled => 0 },
};
my $cfg = MMPve::Core::Config->default;
$cfg->{modules}{poollimits} = 1;
$cfg->{poollimits}{pools}{lab} = $pool;
is_deeply([MMPve::Core::Config->validate($cfg)], [], 'schema válido');
my ($saved) = MMPve::Core::Config->save($cfg);
ok($saved->{revision} >= 2, 'config salva e cópia válida criada');

my %configs = (
    'qemu:101' => { vcpus => 2, sockets => 1, cores => 2, memory => 512 },
    'qemu:102' => { vcpus => 1, memory => 256 },
    'lxc:201' => { cpulimit => 1, memory => 128 },
    'lxc:202' => { cores => 1, memory => 128 },
    'lxc:203' => { memory => 128 },
    'qemu:301' => { template => 1, vcpus => 8, memory => 4096 },
);
$PVE::MMTools::PoolLimits::TEST_USERCFG = {
    pools => { lab => { vms => { 101 => 1, 102 => 1, 301 => 1 } } },
    vms => { 101 => 'lab', 102 => 'lab', 301 => 'lab' },
};
$PVE::MMTools::PoolLimits::TEST_VMLIST = {
    101 => { type => 'qemu', node => 'node-b' }, 102 => { type => 'qemu', node => 'node-b' },
    201 => { type => 'lxc', node => 'node-b' }, 202 => { type => 'lxc', node => 'node-b' },
    203 => { type => 'lxc', node => 'node-b' }, 301 => { type => 'qemu', node => 'node-b' },
};
$PVE::MMTools::PoolLimits::TEST_RRD = {
    map { ("pve-vm-9.0/$_" => [0, '', 'running', 0]) } (101, 102, 201, 202, 203, 301)
};
my @loaded_nodes;
my $cb = sub { my ($type, $vmid, $node) = @_; push @loaded_nodes, $node if defined $node; return $configs{"$type:$vmid"} };
$PVE::QemuConfig::LOAD_CB = sub { return $configs{"qemu:$_[0]"} };

my $usage = PVE::MMTools::PoolLimits->accounting('lab', config_cb => $cb);
is($usage->{usage}{cpu}, 3, 'QEMU vCPU usa vcpus explícito');
is($usage->{usage}{memory_mib}, 768, 'RAM QEMU contabilizada');
ok((grep { $_ eq 'node-b' } @loaded_nodes) > 0, 'config dos membros usa o node do vmlist');
my $diagnostic_usage = PVE::MMTools::PoolLimits->accounting('lab',
    config_cb => sub { die "dependência ausente: IO/Multiplex.pm\n" });
like($diagnostic_usage->{errors}[0], qr/IO\/Multiplex\.pm/,
    'erro de contabilidade inclui a causa truncada');

PVE::MMTools::PoolLimits->check_config('lab', 101, 'qemu',
    { vcpus => 3, memory => 512 }, config_cb => $cb,
    current_metrics => { cpu => 2, memory_mib => 512 }, running => 1);
my $refused = eval {
    PVE::MMTools::PoolLimits->check_config('lab', 102, 'qemu',
        { vcpus => 2, memory => 256 }, config_cb => $cb,
        current_metrics => { cpu => 1, memory_mib => 256 }, running => 1);
    1;
};
ok(!$refused, 'segunda reserva que excede vCPU é recusada') or diag $@;
like($@, qr/pool 'lab'.*vCPU.*uso atual.*pedido.*limite/s, 'mensagem inclui pool, recurso, uso, pedido e limite');

ok(eval {
    PVE::MMTools::PoolLimits->check_config('lab', 101, 'qemu',
        { vcpus => 1, memory => 256 }, config_cb => $cb,
        current_metrics => { cpu => 3, memory_mib => 512 }, running => 1);
    1;
}, 'redução nunca é recusada') or diag $@;

ok(!eval {
    PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101,
        { vcpus => 5, memory => 512 });
    1;
}, 'hook write_config recusa aumento') or diag $@;
ok(eval {
    PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101,
        { vcpus => 1, memory => 256 });
    1;
}, 'hook write_config aceita redução') or diag $@;
ok(eval {
    PVE::MMTools::PoolLimits->check_write_config('PVE::AbstractConfig', 101,
        { vcpus => 99, memory => 9999 });
    1;
}, 'classe de configuração não guest é ignorada') or diag $@;

my $missing = delete $configs{'qemu:102'};
my $lock_only_ok;
{
    no warnings 'redefine';
    local *PVE::MMTools::PoolLimits::_with_pool_lock = sub { die 'lock não deveria ser tomado' };
    $lock_only_ok = eval {
        PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101,
            { vcpus => 2, memory => 512, lock => 'backup' });
        1;
    };
}
ok($lock_only_ok, 'lock-only write não toma lock nem calcula membro indisponível') or diag $@;
ok(!eval {
    PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101,
        { vcpus => 3, memory => 512 });
    1;
}, 'aumento com membro indisponível falha fechado') or diag $@;
$configs{'qemu:102'} = $missing;

my $lxc_no_cpu = eval {
    $PVE::MMTools::PoolLimits::TEST_USERCFG = {
        pools => { lab => { vms => { 101 => 1, 102 => 1, 201 => 1, 202 => 1, 203 => 1, 301 => 1 } } },
        vms => { 101 => 'lab', 102 => 'lab', 201 => 'lab', 202 => 'lab', 203 => 'lab', 301 => 'lab' },
    };
    PVE::MMTools::PoolLimits->check_config('lab', 203, 'lxc',
        $configs{'lxc:203'}, config_cb => $cb,
        current_metrics => { cpu => 0, memory_mib => 128 }, running => 1);
    1;
};
ok(!$lxc_no_cpu, 'LXC sem cpulimit/cores recusado') or diag $@;

my $template_usage = $usage->{usage}{cpu};
ok($template_usage < 11, 'template não entra na contabilidade');

$cfg->{poollimits}{pools}{lab}{cpu}{max} = 1;
MMPve::Core::Config->save($cfg);
ok(eval {
    PVE::MMTools::PoolLimits->check_start({ vcpus => 8, memory => 4096 }, 101, 'pre-start');
    1;
}, 'start em modo allocated é sempre no-op') or diag $@;
$cfg->{poollimits}{pools}{lab}{cpu}{max} = 4;

$PVE::MMTools::PoolLimits::TEST_USERCFG = {
    pools => { lab => { vms => { 101 => 1, 102 => 1, 301 => 1 } } },
    vms => { 101 => 'lab', 102 => 'lab', 301 => 'lab' },
};
$cfg->{poollimits}{pools}{lab}{mode} = 'running';
MMPve::Core::Config->save($cfg);
$PVE::MMTools::PoolLimits::TEST_VMLIST = {
    101 => { type => 'qemu', node => 'node-b' }, 102 => { type => 'qemu', node => 'node-b' },
    301 => { type => 'qemu', node => 'node-b' },
};
$PVE::MMTools::PoolLimits::TEST_RRD = {
    'pve-vm-9.0/101' => [0, '', 'stopped', 0],
    'pve-vm-9.0/102' => [0, '', 'running', 0],
    'pve-vm-9.0/301' => [0, '', 'stopped', 1],
};
$PVE::QemuConfig::LOAD_CB = sub { return $configs{"qemu:$_[0]"} };
$usage = PVE::MMTools::PoolLimits->accounting('lab', config_cb => $cb,
    vmlist => { 101 => { type => 'qemu', node => 'node-b' }, 102 => { type => 'qemu', node => 'node-b' },
        301 => { type => 'qemu', node => 'node-b' } });
is($usage->{usage}{cpu}, 1, 'modo running conta somente guest ligado');
ok(eval {
    PVE::MMTools::PoolLimits->check_config('lab', 101, 'qemu',
        { vcpus => 2, memory => 512 }, config_cb => $cb, running => 0,
        starting => 1, current_metrics => { cpu => 0, memory_mib => 0 });
    1;
}, 'starting usa a mesma reserva') or diag $@;
ok(-f "$ENV{MM_PVE_CONFIG_DIR}/poollimits-reservations/lab.json",
    'start grava reserva de guest iniciando');

$cfg->{modules}{poollimits} = 0;
MMPve::Core::Config->save($cfg);
ok(eval {
    PVE::MMTools::PoolLimits->check_config('lab', 203, 'lxc', $configs{'lxc:203'},
        config_cb => $cb, running => 1, current_metrics => { cpu => 0, memory_mib => 0 });
    1;
}, 'módulo desligado é no-op') or diag $@;

$cfg->{modules}{poollimits} = 1;
MMPve::Core::Config->save($cfg);
write_file_atomic(MMPve::Core::Config->config_path, '{"quebrado": [}\\n');
my $fail_closed = eval {
    PVE::MMTools::PoolLimits->check_config('lab', 102, 'qemu',
        { vcpus => 3, memory => 512 }, config_cb => $cb,
        current_metrics => { cpu => 1, memory_mib => 256 }, running => 1);
    1;
};
ok(!$fail_closed, 'config inválida não libera aumento') or diag $@;
like($@, qr/desative o módulo/, 'fail-closed explica como desligar');

done_testing();

