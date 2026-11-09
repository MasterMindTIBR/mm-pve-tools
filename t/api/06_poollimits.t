#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

use lib "$Bin";
use TestAPI;

TestAPI::setup_inc();
my ($real, $why) = TestAPI::real_pve();
plan skip_all => "PVE real não disponível: $why" unless $real;

ok(eval { require PVE::MMTools::PoolLimits; 1 }, 'núcleo poollimits carrega com os módulos reais')
    or BAIL_OUT($@);
ok(eval { require PVE::API2::MMTools::Poollimits; 1 }, 'API poollimits carrega')
    or BAIL_OUT($@);
PVE::RESTHandler->validate_method_schemas();

my $attrs = PVE::API2::MMTools::Poollimits->method_attributes;
ok(@{$attrs}, 'API poollimits registrou métodos');
for my $info (@{$attrs}) {
    next if $info->{subclass};
    my $check = $info->{permissions}{check};
    ok($check && $check->[0] eq 'perm', "$info->{name} tem permissão real");
    if ($info->{name} eq 'index') {
        is($check->[1], '/', 'lista exige Sys.Audit em /');
    } elsif ($info->{name} eq 'read_pool') {
        is($check->[1], '/pool/{poolid}', 'pool exige Pool.Audit no pool');
    } elsif ($info->{name} eq 'update_limits') {
        is($check->[1], '/', 'PUT exige Sys.Modify em /');
    }
}

subtest 'contabilidade real com cfs falso' => sub {
    require MMPve::Core::Config;
    my ($tmp) = tempdir('mm-pve-api-poollimits-XXXXXX', TMPDIR => 1, CLEANUP => 1) =~ /\A(.*)\z/s;
    $ENV{MM_PVE_ROOT} = $tmp;
    $ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
    $ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;
    make_path($ENV{MM_PVE_CONFIG_DIR});

    my $cfg = MMPve::Core::Config->default;
    $cfg->{modules}{poollimits} = 1;
    $cfg->{poollimits}{pools}{lab} = {
        mode => 'allocated',
        cpu => { enabled => 1, max => 4 },
        memory_mib => { enabled => 1, max => 1024 },
        disk_total_gib => { enabled => 0 },
        disk_storage => { enabled => 0 },
    };
    MMPve::Core::Config->save($cfg);
    {
        no warnings 'once';
        $PVE::MMTools::PoolLimits::TEST_USERCFG = {
            pools => { lab => { vms => { 101 => 1, 102 => 1 } } },
            vms => { 101 => 'lab', 102 => 'lab' },
        };
        $PVE::MMTools::PoolLimits::TEST_VMLIST = {
            101 => { type => 'qemu', node => 'node-b' },
            102 => { type => 'qemu', node => 'node-b' },
        };
        $PVE::MMTools::PoolLimits::TEST_RRD = {
            'pve-vm-9.0/101' => [0, '', 'running', 0],
            'pve-vm-9.0/102' => [0, '', 'running', 0],
        };
    }
    my %conf = (
        'qemu:101' => { vcpus => 2, memory => 512 },
        'qemu:102' => { vcpus => 1, memory => 256 },
    );
    my $usage = PVE::MMTools::PoolLimits->accounting('lab',
        usercfg => {
            pools => { lab => { vms => { 101 => 1, 102 => 1 } } },
            vms => { 101 => 'lab', 102 => 'lab' },
        },
        vmlist => { 101 => { type => 'qemu', node => 'node-b' }, 102 => { type => 'qemu', node => 'node-b' } },
        config_cb => sub { return $conf{"$_[0]:$_[1]"} },
    );
    is($usage->{usage}{cpu}, 3, 'PVE::QemuConfig real contabiliza vcpus');
    ok(eval {
        PVE::MMTools::PoolLimits->check_config('lab', 101, 'qemu',
            { vcpus => 3, memory => 512 },
            usercfg => {
                pools => { lab => { vms => { 101 => 1, 102 => 1 } } },
                vms => { 101 => 'lab', 102 => 'lab' },
            },
            vmlist => { 101 => { type => 'qemu', node => 'node-b' }, 102 => { type => 'qemu', node => 'node-b' } },
            config_cb => sub { return $conf{"$_[0]:$_[1]"} },
            current_metrics => { cpu => 2, memory_mib => 512 }, running => 1,
        );
        1;
    }, 'reserva real passa pelo lock falso') or diag $@;
};

subtest 'hooks de storage reais recusam antes do efeito' => sub {
    my $cfg = MMPve::Core::Config->default;
    $cfg->{modules}{poollimits} = 1;
    $cfg->{poollimits}{pools}{lab} = {
        mode => 'allocated',
        cpu => { enabled => 0 }, memory_mib => { enabled => 0 },
        disk_total_gib => { enabled => 1, max => 1 },
        disk_storage => { enabled => 1, limits => { local => 1 } },
    };
    MMPve::Core::Config->save($cfg);
    local $PVE::MMTools::PoolLimits::TEST_USERCFG = {
        pools => { lab => { vms => { 101 => 1 } } }, vms => { 101 => 'lab' },
    };
    local $PVE::MMTools::PoolLimits::TEST_VMLIST = {
        101 => { type => 'qemu', node => 'node-b' },
    };
    local $PVE::MMTools::PoolLimits::TEST_CONFIGS = {
        'qemu:101' => { vcpus => 1, memory => 128,
            scsi0 => 'local:vm-101-disk-0,size=1G' },
    };
    local $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG = { ids => { local => {} } };
    local $PVE::MMTools::PoolLimits::TEST_RRD = { 'pve-vm-9.0/101' => [0, '', 'running', 0] };
    ok(!eval {
        PVE::MMTools::PoolLimits->check_storage_alloc(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local', 101, 'raw',
            'vm-101-disk-1', 1024 * 1024,
        );
        1;
    }, 'vdisk_alloc real recusa antes do plugin') or diag $@;
    ok(!eval {
        PVE::MMTools::PoolLimits->check_storage_clone(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local:vm-101-disk-0', 101, undef,
        );
        1;
    }, 'vdisk_clone real recusa antes do plugin') or diag $@;
    ok(!eval {
        PVE::MMTools::PoolLimits->check_storage_resize(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local:vm-101-disk-0', 2 * 1024 * 1024 * 1024, 0, undef,
        );
        1;
    }, 'volume_resize real recusa antes do plugin') or diag $@;
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_import(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, {}, 'local:vm-101-disk-0',
            'raw', undef, undef, 0, 0,
        );
        1;
    }, 'volume_import do mesmo volid não é aumento') or diag $@;
};

done_testing();
