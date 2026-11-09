#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json encode_json);
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

my ($read_info) = grep { $_->{name} eq 'read_pool' } @{$attrs};
ok($read_info && ref($read_info->{code}) eq 'CODE', 'GET de pool tem callback executável');
{
    package TestAPIPoollimitsRPC;
    sub new { bless { allow => $_[1] }, $_[0] }
    sub get_user { return 'tester@pam' }
    sub check {
        die 'assinatura inesperada em RPCEnvironment::check'
            unless $_[1] eq 'tester@pam' && $_[2] eq '/' && ref($_[3]) eq 'ARRAY'
            && $_[3][0] eq 'Sys.Modify' && $_[4] == 1;
        return $_[0]->{allow};
    }
}
{
    no warnings qw(once redefine);
    local *PVE::MMTools::PoolLimits::pool_status = sub {
        return { poolid => 'lab', module_enabled => 1 };
    };
    local *PVE::RPCEnvironment::get = sub { return TestAPIPoollimitsRPC->new(0) };
    my $allowed = $read_info->{code}->({ poolid => 'lab' });
    is($allowed->{can_edit}, 0, 'GET usa o resultado do RPC environment para negar edição');
    local *PVE::RPCEnvironment::get = sub { return TestAPIPoollimitsRPC->new(1) };
    my $admin = $read_info->{code}->({ poolid => 'lab' });
    is($admin->{can_edit}, 1, 'GET usa o resultado do RPC environment para liberar edição');
}

my ($update_info) = grep { $_->{name} eq 'update_limits' } @{$attrs};
ok($update_info && ref($update_info->{parameters}) eq 'HASH', 'PUT expõe schema de parâmetros');
subtest 'payload JSON da GUI passa pelo schema PVE real' => sub {
    my $payload = decode_json(<<'JSON');
{"node":"localhost","poolid":"lab","mode":"running",
 "cpu":{"enabled":true,"max":4},
 "memory_mib":{"enabled":true,"max":2048},
 "disk_total_gib":{"enabled":false},
 "disk_storage":{"enabled":true,"limits":{"local":6,"fast":4}},
 "digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}
JSON
    ok(JSON::PP::is_bool($payload->{cpu}{enabled}), 'booleano JSON preservado em cpu.enabled');
    ok(JSON::PP::is_bool($payload->{disk_total_gib}{enabled}), 'booleano JSON preservado em disk_total_gib.enabled');
    ok(eval { PVE::JSONSchema::validate($payload, $update_info->{parameters}); 1 },
        'payload aceito por PVE::JSONSchema') or diag $@;

    my $bad_max = decode_json(encode_json($payload));
    $bad_max->{cpu}{max} = 0;
    ok(!eval { PVE::JSONSchema::validate($bad_max, $update_info->{parameters}); 1 },
        'max zero rejeitado pelo schema');

    my $bad_key = decode_json(encode_json($payload));
    $bad_key->{unknown} = 1;
    ok(!eval { PVE::JSONSchema::validate($bad_key, $update_info->{parameters}); 1 },
        'chave desconhecida rejeitada pelo schema');
};

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
