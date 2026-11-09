#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

use lib "$Bin/../../lib", "$Bin/../../perl";
use MMPve::Core::Config;
use MMPve::Module::Poollimits;

BEGIN {
    package PVE::QemuConfig;
    our $LOAD_CB;
    sub get_derived_property {
        my ($class, $conf, $name) = @_;
        return $conf->{vcpus} || (($conf->{sockets} || 1) * ($conf->{cores} || 1))
            if $name eq 'max-cpu';
        return ($conf->{memory} || 0) * 1024 * 1024 if $name eq 'max-memory';
        die "unknown property";
    }
    sub load_config { return $LOAD_CB->($_[1]) if ref($LOAD_CB) eq 'CODE'; return undef }
    $INC{'PVE/QemuConfig.pm'} = __FILE__;
}

require PVE::MMTools::PoolLimits;

my ($tmp) = tempdir('mm-pve-poollimits-disk-XXXXXX', TMPDIR => 1, CLEANUP => 1) =~ /\A(.*)\z/s;
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;
$ENV{PATH} = '/usr/bin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $gib = 1024 * 1024 * 1024;
my $mib = 1024 * 1024;
my $pool = {
    mode => 'allocated',
    cpu => { enabled => 0 }, memory_mib => { enabled => 0 },
    disk_total_gib => { enabled => 1, max => 10 },
    disk_storage => { enabled => 1, limits => { local => 2, fast => 10 } },
};
my $cfg = MMPve::Core::Config->default;
$cfg->{modules}{poollimits} = 1;
$cfg->{poollimits}{pools}{lab} = $pool;
MMPve::Core::Config->save($cfg);

my %configs = (
    'qemu:101' => {
        vcpus => 1, memory => 128,
        scsi0 => 'local:vm-101-disk-0,size=1G',
        unused0 => 'fast:vm-101-disk-1,size=1G',
        ide2 => 'local:vm-101-cloudinit,media=cdrom',
    },
    'qemu:102' => {
        vcpus => 1, memory => 128,
        scsi0 => 'local:vm-102-disk-0,size=1G',
    },
    'lxc:201' => {
        rootfs => 'local:subvol-201-disk-0,size=1G',
        mp0 => 'fast:subvol-201-disk-1,size=1G',
    },
    'lxc:202' => {
        rootfs => 'local:subvol-202-disk-0,size=1G',
    },
);
$PVE::QemuConfig::LOAD_CB = sub { return $configs{"qemu:$_[0]"} };
$PVE::MMTools::PoolLimits::TEST_CONFIGS = \%configs;
$PVE::MMTools::PoolLimits::TEST_STORAGE_CFG = { ids => { local => {}, fast => {} } };
$PVE::MMTools::PoolLimits::TEST_USERCFG = {
    pools => { lab => { vms => { 101 => 1, 102 => 1, 201 => 1 } } },
    vms => { 101 => 'lab', 102 => 'lab', 201 => 'lab' },
};
$PVE::MMTools::PoolLimits::TEST_VMLIST = {
    101 => { type => 'qemu', node => 'node-a' },
    102 => { type => 'qemu', node => 'node-a' },
    201 => { type => 'lxc', node => 'node-a' },
    202 => { type => 'lxc', node => 'node-a' },
};
$PVE::MMTools::PoolLimits::TEST_RRD = {
    'pve-vm-9.0/101' => [0, '', 'running', 0],
    'pve-vm-9.0/102' => [0, '', 'running', 0],
    'pve-vm-9.0/201' => [0, '', 'running', 0],
    'pve-vm-9.0/202' => [0, '', 'running', 0],
};
$PVE::MMTools::PoolLimits::TEST_VOL_OWNERS = {
    'local:vm-101-disk-0' => 101,
    'local:vm-101-disk-1' => 101,
    'local:vm-102-disk-0' => 102,
    'local:vm-101-import' => 101,
};

sub save_pool {
    my ($value) = @_;
    $cfg->{poollimits}{pools}{lab} = $value;
    MMPve::Core::Config->save($cfg);
}

sub no_reservation {
    my $path = "$ENV{MM_PVE_CONFIG_DIR}/poollimits-reservations/lab.json";
    return {} unless -f $path;
    require JSON::PP;
    open(my $fh, '<', $path) or die "abrir reserva: $!";
    local $/;
    my $raw = <$fh>;
    close($fh);
    return JSON::PP::decode_json($raw);
}

sub clear_reservation {
    my $path = "$ENV{MM_PVE_CONFIG_DIR}/poollimits-reservations/lab.json";
    unlink $path if -f $path;
}

subtest 'accounting por storage e total inclui unusedN e cloud-init' => sub {
    my $usage = PVE::MMTools::PoolLimits->accounting('lab',
        usercfg => $PVE::MMTools::PoolLimits::TEST_USERCFG,
        vmlist => $PVE::MMTools::PoolLimits::TEST_VMLIST,
        config_cb => sub { return $configs{"$_[0]:$_[1]"} },
        storecfg => $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG,
    );
    is($usage->{usage}{disk_storage_bytes}{local}, 3 * $gib + 4 * $mib, 'local soma QEMU, CT e cloud-init');
    is($usage->{usage}{disk_storage_bytes}{fast}, 2 * $gib, 'fast inclui unusedN e mount point');
    is($usage->{usage}{disk_total_bytes}, 5 * $gib + 4 * $mib, 'total inclui cloud-init');
};

subtest 'vdisk_alloc recusa antes da alocação e acumula target' => sub {
    my $called = 0;
    my $refused = eval {
        PVE::MMTools::PoolLimits->check_storage_alloc(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local', 101, 'raw',
            'vm-101-disk-2', $gib / 1024,
        );
        $called = 1;
        1;
    };
    ok(!$refused && !$called, 'limite recusa antes do plugin');
    like($@, qr/pool 'lab': limite de disco/, 'erro identifica disco');

    save_pool({ %{$pool}, disk_total_gib => { enabled => 1, max => 20 },
        disk_storage => { enabled => 1, limits => { local => 20, fast => 20 } } });
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_alloc(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local', 101, 'raw',
            'vm-101-disk-2', 512 * 1024,
        );
        1;
    }, 'primeira alocação aprovada') or diag $@;
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_alloc(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local', 101, 'raw',
            'vm-101-disk-3', 512 * 1024,
        );
        1;
    }, 'segunda alocação aprovada') or diag $@;
    my $res = no_reservation();
    is($res->{'qemu:101'}{target}{disk_storage_bytes}{local}, 2 * $gib + 4 * $mib,
        'duas alocações acumulam no target por storage');
    clear_reservation();
};

subtest 'exceções e não-incrementos não tomam lock' => sub {
    local *PVE::MMTools::PoolLimits::_with_pool_lock = sub { die 'lock inesperado' };
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_alloc(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local', 101, 'raw',
            'vm-101-fleece-0', $gib / 1024,
        );
        1;
    }, 'fleecing é isento antes do lock') or diag $@;
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_alloc(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local', 101, 'raw',
            'vm-101-state-snap0', $gib / 1024,
        );
        1;
    }, 'vmstate é isento antes do lock') or diag $@;
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_import(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, {}, 'local:vm-101-disk-0',
            'raw', undef, undef, 0, 0,
        );
        1;
    }, 'import do mesmo volid não é aumento') or diag $@;
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_resize(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local:vm-101-disk-0', 2 * $gib, 0, 'snap0',
        );
        1;
    }, 'resize com snapshot é ignorado antes do lock') or diag $@;
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_resize(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local:vm-999-disk-0', 2 * $gib, 0, undef,
        );
        1;
    }, 'resize de volume não atual é ignorado') or diag $@;
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_resize(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local:vm-101-disk-0', 512 * 1024 * 1024, 0, undef,
        );
        1;
    }, 'redução de volume atual é permitida') or diag $@;
};

subtest 'resize, clone e import respeitam aumentos e tamanho desconhecido' => sub {
    save_pool({ %{$pool}, disk_total_gib => { enabled => 1, max => 10 },
        disk_storage => { enabled => 1, limits => { local => 3, fast => 10 } } });
    ok(!eval {
        PVE::MMTools::PoolLimits->check_storage_resize(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local:vm-101-disk-0', 4 * $gib, 0, undef,
        );
        1;
    }, 'resize atual que excede storage é recusado') or diag $@;
    ok(!eval {
        PVE::MMTools::PoolLimits->check_storage_clone(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local:vm-101-disk-0', 101, undef,
        );
        1;
    }, 'clone que cria outro volid recusa mesmo quando a origem é atual') or diag $@;
    ok(!eval {
        PVE::MMTools::PoolLimits->check_storage_clone(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local:vm-999-disk-0', 101, undef,
        );
        1;
    }, 'clone com tamanho desconhecido falha fechado') or diag $@;
    like($@, qr/tamanho do clone indisponível/, 'mensagem de tamanho desconhecido');
    ok(!eval {
        PVE::MMTools::PoolLimits->check_storage_import(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, {}, 'local:vm-101-import',
            'raw', undef, undef, 0, 0,
        );
        1;
    }, 'import sem tamanho conhecido falha fechado') or diag $@;
};

subtest 'toggles independentes e módulo desligado' => sub {
    save_pool({ %{$pool}, disk_total_gib => { enabled => 0 },
        disk_storage => { enabled => 1, limits => { local => 5, fast => 10 } } });
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_alloc(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'fast', 101, 'raw', 'vm-101-disk-fast', $gib / 1024,
        );
        1;
    }, 'limite total desligado não bloqueia por total') or diag $@;
    save_pool({ %{$pool}, disk_total_gib => { enabled => 1, max => 10 },
        disk_storage => { enabled => 0 } });
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_alloc(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local', 101, 'raw', 'vm-101-disk-local', $gib / 1024,
        );
        1;
    }, 'limite por storage desligado não bloqueia por storage') or diag $@;
    save_pool({ %{$pool}, disk_total_gib => { enabled => 0 },
        disk_storage => { enabled => 1, limits => { local => 5, fast => 10 } } });
    local *PVE::MMTools::PoolLimits::_with_pool_lock = sub { die 'lock inesperado com módulo off' };
    $cfg->{modules}{poollimits} = 0;
    MMPve::Core::Config->save($cfg);
    ok(eval {
        PVE::MMTools::PoolLimits->check_storage_alloc(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local', 101, 'raw', 'vm-101-disk-off', $gib / 1024,
        );
        1;
    }, 'módulo desligado é no-op sem lock') or diag $@;
    $cfg->{modules}{poollimits} = 1;
    MMPve::Core::Config->save($cfg);
};

subtest 'write_config e entrada no pool contam disco' => sub {
    save_pool({ %{$pool}, disk_total_gib => { enabled => 1, max => 3 },
        disk_storage => { enabled => 1, limits => { local => 3, fast => 10 } } });
    ok(!eval {
        PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101, {
            %{$configs{'qemu:101'}}, unused1 => 'local:vm-101-disk-2,size=2G',
        });
        1;
    }, 'write_config recusa volume reanexado que excede total') or diag $@;
    ok(eval {
        PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101, {
            scsi0 => $configs{'qemu:101'}{scsi0}, ide2 => $configs{'qemu:101'}{ide2},
        });
        1;
    }, 'write_config aceita redução/alvo dentro do limite') or diag $@;
    ok(!eval {
        PVE::MMTools::PoolLimits->check_qemu_create(
            { scsi0 => 'local:5G', vcpus => 1, memory => 128 }, undef,
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 301, 'lab',
        );
        1;
    }, 'preflight create com pool recusa disco antes de entrar') or diag $@;
    ok(!eval {
        PVE::MMTools::PoolLimits->check_clone(302, 'lab', {
            vcpus => 1, memory => 128, scsi0 => 'local:5G',
        }, 'qemu');
        1;
    }, 'preflight clone com pool recusa disco') or diag $@;
    save_pool({ %{$pool}, disk_total_gib => { enabled => 1, max => 10 },
        disk_storage => { enabled => 1, limits => { local => 10, fast => 10 } } });
    ok(eval {
        PVE::MMTools::PoolLimits->check_lxc_create(
            { rootfs => 'local:1G' }, undef, $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 303, 'lab',
        );
        1;
    }, 'preflight LXC dentro do limite é aceito') or diag $@;
    save_pool({ %{$pool}, disk_total_gib => { enabled => 1, max => 1 },
        disk_storage => { enabled => 1, limits => { local => 1, fast => 1 } } });
    ok(!eval { PVE::MMTools::PoolLimits->check_pool_entry(201, 'lab'); 1 },
        'add_vm_to_pool recusa entrada com disco antes da membership') or diag $@;
    ok(!eval {
        PVE::MMTools::PoolLimits->check_pool_update({ poolid => 'lab', vms => '202' },
            $PVE::MMTools::PoolLimits::TEST_USERCFG);
        1;
    }, 'update_pool recusa entrada com disco antes da membership') or diag $@;
};

subtest 'start em modo running ignora disco mas mantém CPU e RAM' => sub {
    clear_reservation();
    save_pool({ mode => 'running',
        cpu => { enabled => 1, max => 10 }, memory_mib => { enabled => 1, max => 1024 },
        disk_total_gib => { enabled => 1, max => 1 },
        disk_storage => { enabled => 1, limits => { local => 1, fast => 1 } } });
    $configs{'qemu:101'}{unused1} = 'offline:vm-101-unreadable';
    local *PVE::MMTools::PoolLimits::_volume_size = sub { die 'volume_size_info não deveria ser chamado no start' };
    ok(eval {
        PVE::MMTools::PoolLimits->check_start($configs{'qemu:101'}, 101, 'pre-start');
        1;
    }, 'start permitido com disco acima do limite e volume unreadable') or diag $@;
    save_pool({ mode => 'running',
        cpu => { enabled => 1, max => 1 }, memory_mib => { enabled => 1, max => 1024 },
        disk_total_gib => { enabled => 1, max => 1 },
        disk_storage => { enabled => 1, limits => { local => 1, fast => 1 } } });
    ok(!eval {
        PVE::MMTools::PoolLimits->check_start($configs{'qemu:101'}, 101, 'pre-start');
        1;
    }, 'start continua verificando CPU') or diag $@;
    like($@, qr/vCPU/, 'a recusa do start é de CPU, não de disco');
    delete $configs{'qemu:101'}{unused1};
};

subtest 'erros de disco só afetam aumentos de disco' => sub {
    clear_reservation();
    save_pool({ mode => 'allocated',
        cpu => { enabled => 1, max => 5 }, memory_mib => { enabled => 0 },
        disk_total_gib => { enabled => 1, max => 1 },
        disk_storage => { enabled => 1, limits => { local => 1, fast => 10 } } });
    $configs{'qemu:101'}{unused1} = 'offline:vm-101-unreadable';
    local *PVE::MMTools::PoolLimits::_volume_size = sub { die 'volume unreadable' };
    local *PVE::MMTools::PoolLimits::_with_pool_lock = sub { die 'lock inesperado em write sem aumento' };
    ok(eval {
        PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101,
            { %{$configs{'qemu:101'}}, lock => 'backup' });
        1;
    }, 'mudança somente de lock não consulta tamanho de unused') or diag $@;

    local *PVE::MMTools::PoolLimits::_with_pool_lock = sub { return $_[1]->() };
    delete $configs{'qemu:101'}{unused1};
    $configs{'qemu:101'}{unused1} = 'offline:vm-101-target-unreadable';
    $configs{'qemu:102'}{unused1} = 'offline:vm-102-unreadable';
    ok(eval {
        PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101,
            { %{$configs{'qemu:101'}}, vcpus => 2 });
        1;
    }, 'aumento de CPU é julgado sem inventário de disco dos demais guests') or diag $@;
    ok(!eval {
        PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101,
            { %{$configs{'qemu:101'}}, unused2 => 'local:vm-101-new-unknown' });
        1;
    }, 'aumento de disco ainda falha fechado com tamanho desconhecido') or diag $@;
    like($@, qr/calcular disco/, 'erro do aumento é de disco');
    delete $configs{'qemu:101'}{unused1};
    delete $configs{'qemu:102'}{unused1};
};

subtest 'check_config reconhece aumento por storage, não só por total' => sub {
    save_pool({ mode => 'allocated',
        cpu => { enabled => 0 }, memory_mib => { enabled => 0 },
        disk_total_gib => { enabled => 1, max => 10 },
        disk_storage => { enabled => 1, limits => { local => 10, fast => 10 } } });
    local *PVE::MMTools::PoolLimits::_with_pool_lock = sub { die 'aumento por storage alcançou o lock' };
    ok(!eval {
        PVE::MMTools::PoolLimits->check_config('lab', 101, 'qemu',
            { vcpus => 1, memory => 128 },
            target_disk => { total => $gib, by_storage => { fast => $gib } },
            current_disk => { total => $gib, by_storage => { local => $gib } },
            running => 1, current_metrics => { cpu => 1, memory_mib => 128 });
        1;
    }, 'troca de storage com total igual não é tratada como no-op') or diag $@;
    like($@, qr/aumento por storage/, 'check_config chegou ao ponto de aumento');
};

subtest 'migração é isenta enquanto lock=migrate' => sub {
    clear_reservation();
    save_pool({ mode => 'allocated',
        cpu => { enabled => 0 }, memory_mib => { enabled => 0 },
        disk_total_gib => { enabled => 1, max => 1 },
        disk_storage => { enabled => 1, limits => { local => 1, fast => 1 } } });
    my $new_import = 'local:vm-101-migrate-import';
    local $PVE::MMTools::PoolLimits::TEST_VOL_OWNERS = {
        %{$PVE::MMTools::PoolLimits::TEST_VOL_OWNERS}, $new_import => 101,
    };
    local *PVE::MMTools::PoolLimits::_with_pool_lock = sub { die 'migração não deve tomar lock' };
    $configs{'qemu:101'}{lock} = 'migrate';
    {
        # Com lock=migrate nenhum hook pode tocar o storage para inventariar
        # (o inventário roda dentro de eval com erros tolerados: contar chamadas).
        my $inventory_calls = 0;
        local *PVE::MMTools::PoolLimits::_disk_inventory = sub {
            $inventory_calls++;
            return { total => 0, by_storage => {}, volumes => {}, errors => [] };
        };
        {
            local $SIG{__WARN__} = sub { die "warning inesperado: $_[0]" };
            ok(eval {
                PVE::MMTools::PoolLimits->check_storage_alloc(
                    $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local', 101, 'raw', undef,
                    $gib / 1024);
                1;
            }, 'NBD alloc sem nome é isenta durante migração') or diag $@;
        }
        ok(eval {
            PVE::MMTools::PoolLimits->check_storage_import(
                $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, {}, $new_import,
                'raw', undef, undef, 0, 0);
            1;
        }, 'import de novo volid é isento durante migração') or diag $@;
        ok(eval {
            PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101, {
                %{$configs{'qemu:101'}},
                scsi0 => 'fast:vm-101-disk-mapped,size=1G',
            });
            1;
        }, 'write_config da migração mapeada é isento') or diag $@;
        is($inventory_calls, 0, 'nenhum inventário de disco durante a migração');
    }

    delete $configs{'qemu:101'}{lock};
    # Sem o lock a recusa tem de vir da quota do pool, não do lock simulado acima.
    local *PVE::MMTools::PoolLimits::_with_pool_lock = sub { return $_[1]->() };
    {
        local $SIG{__WARN__} = sub { die "warning inesperado: $_[0]" };
        ok(!eval {
            PVE::MMTools::PoolLimits->check_storage_alloc(
                $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, 'local', 101, 'raw', undef,
                $gib / 1024);
            1;
        }, 'NBD alloc sem lock=migrate recusa sem warning de nome undef') or diag $@;
        like($@, qr/^pool 'lab': limite de disco/, 'a recusa do alloc é da quota de disco');
    }
    local $PVE::MMTools::PoolLimits::TEST_VOLUME_SIZES = {
        %{ $PVE::MMTools::PoolLimits::TEST_VOLUME_SIZES || {} }, $new_import => $gib,
    };
    ok(!eval {
        PVE::MMTools::PoolLimits->check_storage_import(
            $PVE::MMTools::PoolLimits::TEST_STORAGE_CFG, {}, $new_import,
            'raw', undef, undef, 0, 0);
        1;
    }, 'import de novo volid sem lock=migrate volta a respeitar a quota') or diag $@;
    like($@, qr/^pool 'lab': limite de disco/, 'a recusa do import é da quota de disco');
};

done_testing();
