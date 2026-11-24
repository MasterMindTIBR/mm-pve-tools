package MMPve::Module::Poollimits;

# Configuração, manifesto de patches e CLI. A contabilidade em processo fica
# exclusivamente em PVE::MMTools::PoolLimits.

use strict;
use warnings;
use base qw(MMPve::Core::ModuleBase);

use JSON::PP qw(decode_json);
use MMPve::Core::Config;
use MMPve::Core::Runner;
use MMPve::Core::Util qw(root_path read_file write_file_atomic ensure_dir json_encode);
use Sys::Hostname qw(hostname);

our $VERSION = '@MM_PVE_VERSION@';

sub name { 'poollimits' }

sub _poollimits {
    my ($class, $cfg) = @_;
    return {} unless ref($cfg) eq 'HASH';
    return $cfg->{poollimits} if ref($cfg->{poollimits}) eq 'HASH';
    return $cfg if exists($cfg->{pools}) && !exists($cfg->{modules});
    return {};
}

sub _bool {
    my ($v) = @_;
    return 1 if ref($v) && ref($v) =~ /Boolean/;
    return 1 if defined($v) && !ref($v) && ($v eq '0' || $v eq '1');
    return 0;
}

sub _positive {
    my ($v) = @_;
    return defined($v) && !ref($v) && $v =~ /^\d+$/ && $v >= 1;
}

sub _poolid { return defined($_[0]) && !ref($_[0]) && $_[0] =~ /^[A-Za-z][A-Za-z0-9_.-]*(?:\/[A-Za-z][A-Za-z0-9_.-]*){0,2}$/ }

sub _resource {
    my ($errors, $pool, $key, $value) = @_;
    if (ref($value) ne 'HASH') {
        push @{$errors}, "poollimits.pools.$pool.$key must be an object";
        return;
    }
    my %known = map { $_ => 1 } qw(enabled max);
    for my $field (keys %{$value}) {
        push @{$errors}, "poollimits.pools.$pool.$key: unknown key '$field'"
            unless $known{$field};
    }
    push @{$errors}, "poollimits.pools.$pool.$key.enabled must be boolean"
        unless exists($value->{enabled}) && _bool($value->{enabled});
    if ($value->{enabled}) {
        push @{$errors}, "poollimits.pools.$pool.$key.max must be a positive integer"
            unless _positive($value->{max});
    } elsif (exists($value->{max}) && !_positive($value->{max})) {
        push @{$errors}, "poollimits.pools.$pool.$key.max must be a positive integer when set";
    }
}

sub validate_section {
    my ($class, $cfg, %opt) = @_;
    return () unless ref($cfg) eq 'HASH' && (exists($cfg->{poollimits}) || exists($cfg->{pools}));
    my $p = $class->_poollimits($cfg);
    my @errors;
    my %known = (pools => 1);
    push @errors, 'poollimits: unknown key' for grep { !$known{$_} } keys %{$p};
    if (ref($p->{pools}) ne 'HASH') {
        push @errors, 'poollimits.pools must be an object';
        return @errors;
    }
    for my $pool (sort keys %{ $p->{pools} }) {
        push @errors, "poollimits.pools.$pool: invalid identifier" unless _poolid($pool);
        my $value = $p->{pools}{$pool};
        if (ref($value) ne 'HASH') {
            push @errors, "poollimits.pools.$pool must be an object";
            next;
        }
        my %pk = map { $_ => 1 } qw(mode cpu memory_mib disk_total_gib disk_storage);
        push @errors, "poollimits.pools.$pool: unknown key '$_'"
            for grep { !$pk{$_} } keys %{$value};
        push @errors, "poollimits.pools.$pool.mode must be allocated or running"
            unless defined($value->{mode}) && !ref($value->{mode})
                && ($value->{mode} eq 'allocated' || $value->{mode} eq 'running');
        for my $key (qw(cpu memory_mib disk_total_gib)) {
            _resource(\@errors, $pool, $key, $value->{$key})
                if exists($value->{$key});
        }
        for my $key (qw(cpu memory_mib disk_total_gib)) {
            push @errors, "poollimits.pools.$pool.$key is required"
                unless exists($value->{$key});
        }
        my $ds = $value->{disk_storage};
        if (ref($ds) ne 'HASH') {
            push @errors, "poollimits.pools.$pool.disk_storage must be an object";
        } else {
            my %dk = map { $_ => 1 } qw(enabled limits);
            push @errors, "poollimits.pools.$pool.disk_storage: unknown key '$_'"
                for grep { !$dk{$_} } keys %{$ds};
            push @errors, "poollimits.pools.$pool.disk_storage.enabled must be boolean"
                unless exists($ds->{enabled}) && _bool($ds->{enabled});
            if (exists($ds->{limits})) {
                if (ref($ds->{limits}) ne 'HASH') {
                    push @errors, "poollimits.pools.$pool.disk_storage.limits must be an object";
                } else {
                    for my $storeid (sort keys %{ $ds->{limits} }) {
                        push @errors, "poollimits.pools.$pool.disk_storage.limits.$storeid must be a positive integer"
                            unless _positive($ds->{limits}{$storeid});
                    }
                }
            } elsif ($ds->{enabled}) {
                push @errors, "poollimits.pools.$pool.disk_storage.limits is required when enabled";
            }
        }
    }

    # A validação de existência precisa de um catálogo fornecido pelo endpoint
    # em processo ou pela CLI. Sem PVE instalado, o schema ainda pode ser
    # validado e o catálogo será exigido no ponto de gravação real.
    if (ref($opt{resources}) eq 'HASH') {
        my $pools = $opt{resources}{pools} || {};
        my $stores = $opt{resources}{storages} || {};
        for my $pool (keys %{ $p->{pools} }) {
            push @errors, "poollimits.pools.$pool does not exist"
                unless $pools->{$pool};
            my $limits = $p->{pools}{$pool}{disk_storage}{limits} || {};
            for my $storeid (keys %{$limits}) {
                push @errors, "storage '$storeid' does not exist"
                    unless $stores->{$storeid};
            }
        }
    }
    return @errors;
}

sub _catalog {
    my ($class) = @_;
    my $pools = MMPve::Core::Runner->pvesh(get => '/pools');
    my $stores = MMPve::Core::Runner->pvesh(get => '/storage');
    my %pools = map { ($_->{poolid} // '') => 1 } @{ ref($pools) eq 'ARRAY' ? $pools : [] };
    my %stores = map { ($_->{storage} // $_->{storageid} // '') => 1 } @{ ref($stores) eq 'ARRAY' ? $stores : [] };
    return { pools => \%pools, storages => \%stores };
}

sub last_good_path { root_path('/var/lib/mm-pve-tools/poollimits-last-good.json') }

sub last_good {
    my ($class) = @_;
    return undef unless -f $class->last_good_path;
    my $data = eval { decode_json(read_file($class->last_good_path)) };
    return ref($data) eq 'HASH' ? $data : undef;
}

sub record_last_known_good {
    my ($class, $cfg) = @_;
    my $p = $class->_poollimits($cfg);
    ensure_dir(root_path('/var/lib/mm-pve-tools'));
    write_file_atomic($class->last_good_path, json_encode({
        revision => $cfg->{revision} // 1,
        enabled => ($cfg->{modules} || {})->{poollimits} ? 1 : 0,
        poollimits => $p,
    }) . "\n", 0644);
    return 1;
}

sub patch_enabled_for_invalid {
    my ($class) = @_;
    my $last = $class->last_good;
    return $last && $last->{enabled} && ref($last->{poollimits}{pools}) eq 'HASH'
        && keys %{ $last->{poollimits}{pools} } ? 1 : 0;
}

sub apply { return { ok => 1, changed => 0, message => 'poollimits ready' } }
sub revert { return { ok => 1, changed => 0, message => 'poollimits reverted' } }

sub check {
    my ($class, $cfg) = @_;
    my $last = $class->last_good;
    my ($loaded, @schema_errors);
    my $valid = eval {
        ($loaded) = MMPve::Core::Config->load;
        @schema_errors = $class->validate_section($loaded);
        @schema_errors ? 0 : 1;
    };
    my $config_error = $@ || join('; ', @schema_errors);
    my $enabled = $valid && (($cfg->{modules} || {})->{poollimits} ? 1 : 0);
    return {
        ok => 1,
        enabled => $enabled,
        config_valid => $valid ? 1 : 0,
        degraded => $valid ? 0 : 1,
        config_error => $config_error || undef,
        last_known_good_revision => $last ? $last->{revision} : undef,
        pools_with_last_limits => $last && ref($last->{poollimits}{pools}) eq 'HASH'
            ? scalar(keys %{ $last->{poollimits}{pools} }) : 0,
        note => $valid ? 'valid configuration' : 'invalid configuration; increases in existing pools will be refused',
    };
}

# Pool ou storage apagado no PVE deixa entrada órfã na config, e a validação de
# existência na gravação cobre a seção inteira: uma órfã travava a gravação de
# limites de qualquer pool. Na gravação, pools que não existem mais saem e
# storages que sumiram saem dos limites dos outros pools (um limite órfão não
# protege nada). O pool que está sendo gravado continua validado à risca.
sub prune_missing {
    my ($class, $p, $resources, $keep) = @_;
    my @removed;
    return \@removed unless ref($p) eq 'HASH' && ref($p->{pools}) eq 'HASH' && ref($resources) eq 'HASH';
    my $pools = $resources->{pools} || {};
    my $stores = $resources->{storages} || {};
    for my $pool (sort keys %{ $p->{pools} }) {
        next if defined($keep) && $pool eq $keep;
        if (!$pools->{$pool}) {
            delete $p->{pools}{$pool};
            push @removed, "pool $pool";
            next;
        }
        my $ds = $p->{pools}{$pool}{disk_storage};
        next unless ref($ds) eq 'HASH' && ref($ds->{limits}) eq 'HASH';
        my %limits = %{ $ds->{limits} };
        my @gone = sort grep { !$stores->{$_} } keys %limits;
        next unless @gone;
        delete @limits{@gone};
        push @removed, map { "storage $_ do pool $pool" } @gone;
        $p->{pools}{$pool} = { %{ $p->{pools}{$pool} },
            disk_storage => %limits ? { %{$ds}, limits => \%limits } : { enabled => 0 } };
    }
    return \@removed;
}

sub _save_pool {
    my ($class, $poolid, $value, %opt) = @_;
    my ($cfg, $digest) = MMPve::Core::Config->load;
    my $p = ref($cfg->{poollimits}) eq 'HASH' ? { %{ $cfg->{poollimits} } } : { pools => {} };
    $p->{pools} = { %{ $p->{pools} || {} }, $poolid => $value };
    my $resources = eval { $class->_catalog };
    $class->prune_missing($p, $resources, $poolid) if $resources;
    my %save = defined($opt{digest}) ? (digest => $opt{digest}) : (digest => $digest);
    $save{resources} = $resources if $resources;
    return MMPve::Core::Config->save_section('poollimits', $p, %save);
}

sub cli {
    my ($class, $argv) = @_;
    require Getopt::Long;
    my ($pool, $mode, $cpu, $memory, $disk_total, $cpu_off, $memory_off,
        $disk_total_off, $disk_storage_off, @disk_storage_max, $check, $help, $digest);
    local @ARGV = @{$argv};
    Getopt::Long::GetOptions(
        'pool=s' => \$pool, 'mode=s' => \$mode, 'cpu-max=i' => \$cpu,
        'memory-max=i' => \$memory, 'cpu-off' => \$cpu_off,
        'memory-off' => \$memory_off, 'disk-total-max=i' => \$disk_total,
        'disk-total-off' => \$disk_total_off, 'disk-storage-max=s@' => \@disk_storage_max,
        'disk-storage-off' => \$disk_storage_off, 'digest=s' => \$digest,
        'check' => \$check, 'help|h' => \$help,
    ) or return 2;
    if ($help) {
        print "usage: mm-pve poollimits status [--pool ID]\n";
        print "       mm-pve poollimits set <pool> --mode allocated|running [--cpu-max N|--cpu-off] [--memory-max N|--memory-off]\n";
        print "       [--disk-total-max GiB|--disk-total-off] [--disk-storage-max STORAGE=GiB ...|--disk-storage-off]\n";
        return 0;
    }
    if ($check || (@ARGV && $ARGV[0] eq 'status')) {
        my $data;
        if ($check) {
            my ($cfg) = MMPve::Core::Config->load;
            $data = $class->check($cfg);
        } else {
            my $path = '/nodes/' . hostname() . '/mm-tools/poollimits';
            $path .= '/' . $pool if defined($pool);
            $data = MMPve::Core::Runner->pvesh(get => $path);
        }
        print json_encode($data, pretty => 1), "\n";
        return 0;
    }
    die "usage: mm-pve poollimits set <pool> ...\n" unless @ARGV == 2 && $ARGV[0] eq 'set';
    my $poolid = $ARGV[1];
    die "--mode is required\n" unless defined($mode) && ($mode eq 'allocated' || $mode eq 'running');
    die "use --cpu-max or --cpu-off\n" if $cpu_off && defined($cpu);
    die "use --memory-max or --memory-off\n" if $memory_off && defined($memory);
    die "use --disk-total-max or --disk-total-off\n" if $disk_total_off && defined($disk_total);
    die "use --disk-storage-max or --disk-storage-off\n" if $disk_storage_off && @disk_storage_max;
    my %disk_storage_max;
    for my $spec (@disk_storage_max) {
        die "--disk-storage-max must be STORAGE=GiB\n"
            unless $spec =~ /\A([A-Za-z][A-Za-z0-9_.-]*)=(\d+)\z/ && $2 >= 1;
        $disk_storage_max{$1} = 0 + $2;
    }
    my ($cfg) = MMPve::Core::Config->load;
    my $old = $cfg->{poollimits}{pools}{$poolid} || {
        cpu => { enabled => 0 }, memory_mib => { enabled => 0 },
        disk_total_gib => { enabled => 0 }, disk_storage => { enabled => 0 },
    };
    my $value = { %{$old}, mode => $mode };
    $value->{cpu} = { %{ $old->{cpu} || {} } };
    $value->{memory_mib} = { %{ $old->{memory_mib} || {} } };
    if (defined($cpu)) { $value->{cpu} = { enabled => 1, max => $cpu } }
    if ($cpu_off) { $value->{cpu} = { enabled => 0 } }
    if (defined($memory)) { $value->{memory_mib} = { enabled => 1, max => $memory } }
    if ($memory_off) { $value->{memory_mib} = { enabled => 0 } }
    if (defined($disk_total)) { $value->{disk_total_gib} = { enabled => 1, max => $disk_total } }
    if ($disk_total_off) { $value->{disk_total_gib} = { enabled => 0 } }
    if (%disk_storage_max) {
        my %limits = %{ $value->{disk_storage}{limits} || {} };
        $limits{$_} = $disk_storage_max{$_} for keys %disk_storage_max;
        $value->{disk_storage} = { enabled => 1, limits => \%limits };
    }
    if ($disk_storage_off) { $value->{disk_storage} = { enabled => 0 } }
    my %opt = defined($digest) ? (digest => $digest) : ();
    my ($saved, $new_digest) = eval { $class->_save_pool($poolid, $value, %opt) };
    if ($@) { chomp(my $err = $@); print STDERR "$err\n"; return 1 }
    print "poollimits saved (revision $saved->{revision})\ndigest: $new_digest\n";
    return 0;
}

sub patch_targets {
    my $args_anchor = qr/^\s*my\s+\([^;\n]*\)\s*=\s*\@_;\s*$/;
    my $call = sub {
        my ($name, $args) = @_;
        $args = '@_' unless defined($args);
        return "    eval { require PVE::MMTools::PoolLimits; 1 } && PVE::MMTools::PoolLimits->$name($args);";
    };
    return [
        {
            id => 'abstract_config_write', owner => 'libpve-guest-common-perl',
            path => '/usr/share/perl5/PVE/AbstractConfig.pm',
            anchor => $args_anchor,
            scope_anchor => qr/^\s*sub\s+write_config\b/,
            expected_function => 'sub write_config',
            line => $call->('check_write_config'),
            daemons => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm qm pct)],
        },
        {
            id => 'guest_helpers_start', owner => 'libpve-guest-common-perl',
            path => '/usr/share/perl5/PVE/GuestHelpers.pm',
            anchor => $args_anchor,
            scope_anchor => qr/^\s*sub\s+exec_hookscript\b/,
            expected_function => 'sub exec_hookscript',
            line => $call->('check_start'),
            daemons => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm qm pct)],
        },
        {
            id => 'access_control_pool', owner => 'libpve-access-control',
            path => '/usr/share/perl5/PVE/AccessControl.pm',
            anchor => $args_anchor,
            scope_anchor => qr/^\s*sub\s+add_vm_to_pool\b/,
            expected_function => 'sub add_vm_to_pool',
            line => $call->('check_pool_entry'),
            daemons => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm pveum pvesh qm pct)],
        },
        {
            id => 'qemu_create_pool', owner => 'qemu-server',
            path => '/usr/share/perl5/PVE/API2/Qemu.pm',
            anchor => qr/^\s*my\s+\$emsg\s*=\s*\$is_restore\s+\?/,
            scope_anchor => qr/^\s*name\s*=>\s*['"]create_vm['"],/,
            expected_function => "name => 'create_vm'",
            line => $call->('check_qemu_create', '$param, $archive, $storecfg, $vmid, $pool'),
            daemons => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm qm pvesh)],
        },
        {
            id => 'qemu_clone_pool', owner => 'qemu-server',
            path => '/usr/share/perl5/PVE/API2/Qemu.pm',
            anchor => qr/^\s*my\s+\$oldconf\s*=\s*\$snapname\s+\?/,
            scope_anchor => qr/^\s*name\s*=>\s*['"]clone_vm['"],/,
            expected_function => "name => 'clone_vm'",
            line => $call->('check_clone', '$newid, $pool, $oldconf, "qemu"'),
            daemons => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm qm pvesh)],
        },
        {
            id => 'lxc_create_pool', owner => 'pve-container',
            path => '/usr/share/perl5/PVE/API2/LXC.pm',
            anchor => qr/^\s*my\s+\$emsg\s*=\s*\$restore\s+\?/,
            scope_anchor => qr/^\s*name\s*=>\s*['"]create_vm['"],/,
            expected_function => "name => 'create_vm'",
            line => $call->('check_lxc_create', '$param, $archive, $storage_cfg, $vmid, $pool'),
            daemons => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm pct pvesh)],
        },
        {
            id => 'lxc_clone_pool', owner => 'pve-container',
            path => '/usr/share/perl5/PVE/API2/LXC.pm',
            anchor => qr/^\s*my\s+\$src_conf\s*=\s*PVE::LXC::Config->set_lock\(\$vmid,\s*'disk'\)/,
            scope_anchor => qr/^\s*name\s*=>\s*['"]clone_vm['"],/,
            expected_function => "name => 'clone_vm'",
            line => $call->('check_clone', '$newid, $pool, $src_conf, "lxc", $snapname'),
            daemons => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pve-ha-lrm pve-ha-crm pct pvesh)],
        },
        {
            id => 'pool_update', owner => 'pve-manager',
            path => '/usr/share/perl5/PVE/API2/Pool.pm',
            anchor => qr/^\s*my\s+\$pool\s*=\s*\$param->\{poolid\};/,
            scope_anchor => qr/^\s*name\s*=>\s*['"]update_pool['"],/,
            expected_function => "name => 'update_pool'",
            line => $call->('check_pool_update', '$param, $usercfg'),
            daemons => [qw(pvedaemon pveproxy)],
            processes => [qw(pvedaemon pveproxy pvesh)],
        },
        {
            id => 'storage_vdisk_alloc', owner => 'libpve-storage-perl',
            path => '/usr/share/perl5/PVE/Storage.pm',
            anchor => $args_anchor,
            scope_anchor => qr/^\s*sub\s+vdisk_alloc\b/,
            expected_function => 'sub vdisk_alloc',
            line => $call->('check_storage_alloc'),
            daemons => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm qm pct pvesm pvesh)],
        },
        {
            id => 'storage_vdisk_clone', owner => 'libpve-storage-perl',
            path => '/usr/share/perl5/PVE/Storage.pm',
            anchor => $args_anchor,
            scope_anchor => qr/^\s*sub\s+vdisk_clone\b/,
            expected_function => 'sub vdisk_clone',
            line => $call->('check_storage_clone'),
            daemons => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm qm pct pvesm pvesh)],
        },
        {
            id => 'storage_volume_resize', owner => 'libpve-storage-perl',
            path => '/usr/share/perl5/PVE/Storage.pm',
            anchor => $args_anchor,
            scope_anchor => qr/^\s*sub\s+volume_resize\b/,
            expected_function => 'sub volume_resize',
            line => $call->('check_storage_resize'),
            daemons => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm qm pct pvesm pvesh)],
        },
        {
            id => 'storage_volume_import', owner => 'libpve-storage-perl',
            path => '/usr/share/perl5/PVE/Storage.pm',
            anchor => $args_anchor,
            scope_anchor => qr/^\s*sub\s+volume_import\b/,
            expected_function => 'sub volume_import',
            line => $call->('check_storage_import'),
            daemons => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm qm pct pvesm pvesh)],
        },
    ];
}

1;
