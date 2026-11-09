package PVE::MMTools::PoolLimits;

# Enforcement in process. This file is loaded by patched PVE code only; it
# never calls pvesh or another PVE CLI.

use strict;
use warnings;

use JSON::PP qw(decode_json encode_json);
use MMPve::Core::Config;
use MMPve::Module::Poollimits;
use MMPve::Core::Util qw(read_file write_file_atomic ensure_dir);

our $VERSION = '@MM_PVE_VERSION@';
use constant RESERVATION_TTL => 120;

# These package variables are test-only injection points. Production callers
# never populate them; cluster data comes from PVE::Cluster.
our ($TEST_USERCFG, $TEST_RESOURCES, $TEST_VMLIST, $TEST_RRD, $TEST_CONFIGS,
    $TEST_STORAGE_CFG, $TEST_VOLUME_SIZES, $TEST_VOL_OWNERS);

use constant GIB => 1024 * 1024 * 1024;
use constant CLOUDINIT_SIZE => 4 * 1024 * 1024;

sub _safe_component {
    my ($value) = @_;
    my ($safe) = defined($value) && !ref($value)
        ? ($value =~ /\A([A-Za-z0-9_.-]+)\z/) : ();
    die "identificador de pool inválido\n" unless defined $safe;
    return $safe;
}

sub _config_dir {
    my $path = MMPve::Core::Config->config_dir;
    my ($safe) = $path =~ /\A([A-Za-z0-9_+.,:\/-]+)\z/;
    die "diretório de configuração inválido\n" unless defined $safe;
    return $safe;
}

sub _reservation_path {
    my ($pool) = @_;
    my $safe = _safe_component($pool);
    $safe =~ s{/}{__}g;
    return _config_dir() . '/poollimits-reservations/' . $safe . '.json';
}

sub _read_reservations {
    my ($pool) = @_;
    my $path = _reservation_path($pool);
    return {} unless -f $path;
    my $data = eval { decode_json(read_file($path)) };
    return {} unless ref($data) eq 'HASH';
    my $now = time;
    my %live = map { $_ => $data->{$_} }
        grep { ref($data->{$_}) eq 'HASH' && ($data->{$_}{expires} // 0) > $now }
        keys %{$data};
    return \%live;
}

sub _write_reservations {
    my ($pool, $data) = @_;
    my $dir = _config_dir() . '/poollimits-reservations';
    ensure_dir($dir);
    write_file_atomic(_reservation_path($pool), encode_json($data) . "\n", 0600);
}

sub _usercfg {
    my ($opts) = @_;
    return $opts->{usercfg} if ref($opts) eq 'HASH' && ref($opts->{usercfg}) eq 'HASH';
    return $TEST_USERCFG if ref($TEST_USERCFG) eq 'HASH';
    require PVE::Cluster;
    my $cfg = PVE::Cluster::cfs_read_file('user.cfg');
    die "não consegui ler user.cfg\n" unless ref($cfg) eq 'HASH';
    return $cfg;
}

sub _storage_cfg {
    return $TEST_STORAGE_CFG if ref($TEST_STORAGE_CFG) eq 'HASH';
    require PVE::Storage;
    my $cfg = PVE::Storage::config();
    die "não consegui ler storage.cfg\n" unless ref($cfg) eq 'HASH';
    return $cfg;
}

sub resource_catalog {
    my ($class, $opts) = @_;
    return $opts->{resources} if ref($opts) eq 'HASH' && ref($opts->{resources}) eq 'HASH';
    return $TEST_RESOURCES if ref($TEST_RESOURCES) eq 'HASH';
    my $ucfg = _usercfg($opts);
    my $scfg = _storage_cfg();
    my %pools = map { $_ => 1 } keys %{ $ucfg->{pools} || {} };
    my %stores = map { $_ => 1 } keys %{ $scfg->{ids} || {} };
    return { pools => \%pools, storages => \%stores };
}

sub _state {
    my ($class) = @_;
    my ($cfg, $digest, $absent);
    my $err;
    eval { ($cfg, $digest, $absent) = MMPve::Core::Config->load; 1 } or $err = $@;
    if (!$err) {
        my @errors = eval { MMPve::Module::Poollimits->validate_section($cfg) };
        $err = join('; ', @errors) if @errors;
        if (!$err) {
            my $enabled = ($cfg->{modules} || {})->{poollimits} ? 1 : 0;
            return { active => $enabled, degraded => 0, cfg => $cfg, digest => $digest,
                poollimits => $cfg->{poollimits} || { pools => {} } };
        }
    }
    my $last = MMPve::Module::Poollimits->last_good;
    return { active => 0, degraded => 1, error => $err || 'config ausente', poollimits => { pools => {} } }
        unless $last && ref($last->{poollimits}) eq 'HASH';
    return {
        active => $last->{enabled} ? 1 : 0,
        degraded => 1,
        error => $err || 'config inválida',
        poollimits => $last->{poollimits},
        last_revision => $last->{revision},
    };
}

sub _limits {
    my ($state, $pool) = @_;
    my $pools = $state->{poollimits}{pools} || {};
    return $pools->{$pool} if ref($pools->{$pool}) eq 'HASH';
    return undef;
}

sub _has_cpu_or_memory_limit {
    my ($limits) = @_;
    return $limits && (($limits->{cpu}{enabled} || $limits->{memory_mib}{enabled}) ? 1 : 0);
}

sub _error_detail {
    my ($error) = @_;
    return '' unless defined($error) && length($error);
    $error =~ s/\s+/ /g;
    $error =~ s/\A\s+|\s+\z//g;
    return substr($error, 0, 240);
}

sub _fail_closed {
    my ($pool, $resource, $detail) = @_;
    $detail = _error_detail($detail) || 'erro desconhecido';
    die "pool '$pool': não foi possível calcular $resource ($detail); desative o módulo com 'modules.poollimits=0' e rode 'mm-pve apply'\n";
}

sub _limit_error {
    my ($pool, $resource, $current, $requested, $limit) = @_;
    die "pool '$pool': limite de $resource excedido (uso atual $current, pedido $requested, limite $limit)\n";
}

sub _pool_members {
    my ($ucfg, $pool) = @_;
    return keys %{ $ucfg->{pools}{$pool}{vms} || {} } if ref($ucfg->{pools}{$pool}) eq 'HASH';
    return;
}

sub _vmlist {
    my ($opts) = @_;
    return $opts->{vmlist} if ref($opts) eq 'HASH' && ref($opts->{vmlist}) eq 'HASH';
    return $TEST_VMLIST if ref($TEST_VMLIST) eq 'HASH';
    require PVE::Cluster;
    my $list = PVE::Cluster::get_vmlist();
    return ref($list) eq 'HASH' ? ($list->{ids} || {}) : {};
}

sub _type_for {
    my ($vmid, $entry, $ucfg) = @_;
    return lc($entry->{type}) if ref($entry) eq 'HASH' && $entry->{type};
    return $ucfg->{types}{$vmid} if ref($ucfg->{types}) eq 'HASH' && $ucfg->{types}{$vmid};
    my $q = eval { require PVE::QemuConfig; PVE::QemuConfig->config_file($vmid); };
    return 'qemu' if defined($q) && -f $q;
    return 'lxc';
}

sub _load_config {
    my ($type, $vmid, $opts) = @_;
    return $opts->{config_cb}->($type, $vmid, $opts->{node}) if ref($opts->{config_cb}) eq 'CODE';
    if (ref($TEST_CONFIGS) eq 'HASH' && exists($TEST_CONFIGS->{"$type:$vmid"})) {
        return $TEST_CONFIGS->{"$type:$vmid"};
    }
    my $node = $opts->{node};
    if ($type eq 'qemu' || $type eq 'kvm') {
        require PVE::QemuConfig;
        return defined($node) ? PVE::QemuConfig->load_config($vmid, $node)
            : PVE::QemuConfig->load_config($vmid);
    }
    require PVE::LXC::Config;
    return defined($node) ? PVE::LXC::Config->load_config($vmid, $node)
        : PVE::LXC::Config->load_config($vmid);
}

sub _merge_pending {
    my ($conf) = @_;
    my %merged = %{$conf || {}};
    my $pending = ref($conf->{pending}) eq 'HASH' ? $conf->{pending} : {};
    for my $key (keys %{$pending}) {
        next if $key eq 'delete';
        $merged{$key} = $pending->{$key};
    }
    return \%merged;
}

sub _size_token {
    my ($value, $default_unit) = @_;
    return undef if !defined($value) || ref($value);
    my ($number, $unit) = $value =~ /\A(\d+(?:\.\d+)?)([KMGTPE]?)(?:B)?\z/i;
    return undef unless defined($number);
    $unit = uc($unit // '');
    $unit = $default_unit if $unit eq '' && defined($default_unit);
    my %multiplier = (
        '' => 1, K => 1024, M => 1024**2, G => 1024**3,
        T => 1024**4, P => 1024**5, E => 1024**6,
    );
    return undef unless exists($multiplier{$unit});
    return int($number * $multiplier{$unit});
}

sub _size_from_value {
    my ($value) = @_;
    return undef if !defined($value) || ref($value);
    if ($value =~ /(?:\A|,)size=([^,]+)/) {
        return _size_token($1);
    }
    return undef;
}

sub _is_exempt_volid {
    my ($volid) = @_;
    return defined($volid) && ($volid =~ /-fleece-/ || $volid =~ /-state-/) ? 1 : 0;
}

sub _disk_limits_enabled {
    my ($limits) = @_;
    return 0 unless ref($limits) eq 'HASH';
    return 1 if ref($limits->{disk_total_gib}) eq 'HASH'
        && $limits->{disk_total_gib}{enabled};
    return 1 if ref($limits->{disk_storage}) eq 'HASH'
        && $limits->{disk_storage}{enabled};
    return 0;
}

sub _has_any_limit {
    my ($limits) = @_;
    return 1 if _has_cpu_or_memory_limit($limits);
    return _disk_limits_enabled($limits);
}

sub _disk_entry {
    my ($type, $key, $value, $vmid) = @_;
    return unless defined($key) && defined($value) && !ref($value);
    if ($type eq 'qemu') {
        return unless $key =~ /\A(?:ide|sata|scsi|virtio|nvme)\d+\z/
            || $key =~ /\A(?:efidisk|tpmstate|unused)\d+\z/;
    } else {
        return unless $key eq 'rootfs' || $key =~ /\A(?:mp|unused)\d+\z/;
        return if $value =~ /\A\/(?:dev\/)?/;
    }
    my ($raw) = split /,/, $value, 2;
    return if !defined($raw) || $raw eq '' || $raw eq 'none' || $raw =~ /\A\//;
    my ($storeid, $rest) = $raw =~ /\A([^:]+):(.+)\z/;
    return unless defined($storeid) && defined($rest);
    my $cloudinit = $type eq 'qemu' && $raw =~ /(?:cloudinit|vm-\d+-cloudinit)/i;
    return if $type eq 'qemu' && $value =~ /(?:\A|,)media=cdrom(?:,|\z)/
        && !$cloudinit;
    my $size = _size_from_value($value);
    my $size_known = defined($size) ? 1 : 0;
    if (!defined($size) && $rest =~ /\A\d+(?:\.\d+)?[KMGTPE]?\z/i) {
        $size = _size_token($rest, 'G');
        $size_known = 1 if defined($size);
    }
    if (!defined($size) && $cloudinit) {
        $size = CLOUDINIT_SIZE;
        $size_known = 1;
    }
    return {
        key => $key, volid => $raw, storeid => $storeid, size => $size,
        size_known => $size_known,
    };
}

sub _disk_entries {
    my ($type, $conf) = @_;
    my %entries;
    return \%entries unless ref($conf) eq 'HASH';
    for my $key (keys %{$conf}) {
        next if $key eq 'pending' || $key eq 'snapshots' || $key eq 'vmstate';
        my $entry = _disk_entry($type, $key, $conf->{$key});
        next unless $entry && !_is_exempt_volid($entry->{volid});
        my $old = $entries{$entry->{volid}};
        $entries{$entry->{volid}} = $entry
            unless $old && defined($old->{size}) && !defined($entry->{size});
    }
    return \%entries;
}

sub _disk_structural_delta {
    my ($type, $old_conf, $new_conf) = @_;
    my $old = _disk_entries($type, $old_conf);
    my $new = _disk_entries($type, $new_conf);
    my $delta = { increase => 0, unknown => 0, bytes => 0, by_storage => {} };
    for my $volid (keys %{$new}) {
        my $next = $new->{$volid};
        my $previous = $old->{$volid};
        if (!$previous) {
            $delta->{increase} = 1;
            if (defined($next->{size}) && $next->{size_known}) {
                $delta->{bytes} += $next->{size};
                $delta->{by_storage}{$next->{storeid}} += $next->{size};
            } else {
                $delta->{unknown} = 1;
            }
            next;
        }
        if (defined($previous->{size}) && defined($next->{size})
            && $next->{size_known} && $next->{size} > $previous->{size}) {
            my $grown = $next->{size} - $previous->{size};
            $delta->{increase} = 1;
            $delta->{bytes} += $grown;
            $delta->{by_storage}{$next->{storeid}} += $grown;
        }
    }
    return $delta;
}

sub _disk_config_has_volume {
    my ($type, $conf) = @_;
    return scalar keys %{_disk_entries($type, $conf)};
}

sub _guest_is_migrating {
    my ($conf) = @_;
    return ref($conf) eq 'HASH' && defined($conf->{lock}) && $conf->{lock} eq 'migrate';
}

sub _volume_size {
    my ($storecfg, $volid) = @_;
    if (ref($TEST_VOLUME_SIZES) eq 'HASH' && exists($TEST_VOLUME_SIZES->{$volid})) {
        return $TEST_VOLUME_SIZES->{$volid};
    }
    my $size = eval {
        require PVE::Storage;
        PVE::Storage::volume_size_info($storecfg || _storage_cfg(), $volid, 5);
    };
    return undef if $@ || !defined($size) || $size <= 0;
    return $size;
}

sub _disk_inventory {
    my ($type, $conf, %opts) = @_;
    my $result = { total => 0, by_storage => {}, volumes => {}, errors => [] };
    return $result unless ref($conf) eq 'HASH';
    for my $key (keys %{$conf}) {
        next if $key eq 'pending' || $key eq 'snapshots' || $key eq 'vmstate';
        my $entry = _disk_entry($type, $key, $conf->{$key}, $opts{vmid});
        next unless $entry;
        next if _is_exempt_volid($entry->{volid});
        my $size = $entry->{size};
        $size = _volume_size($opts{storecfg}, $entry->{volid}) if !defined($size);
        if (!defined($size) || $size < 0) {
            push @{$result->{errors}}, "$entry->{volid}: tamanho indisponível";
            next;
        }
        my $old = $result->{volumes}{$entry->{volid}};
        next if $old && $old->{size} >= $size;
        if ($old) {
            $result->{total} -= $old->{size};
            $result->{by_storage}{$entry->{storeid}} -= $old->{size};
        }
        $result->{volumes}{$entry->{volid}} = {
            size => $size, storage => $entry->{storeid}, key => $entry->{key},
        };
        $result->{total} += $size;
        $result->{by_storage}{$entry->{storeid}} += $size;
    }
    return $result;
}

sub _disk_reservation_target {
    my ($disk, $reservation) = @_;
    my %stores = %{ $disk->{by_storage} || {} };
    my $total = $disk->{total} || 0;
    if (ref($reservation) eq 'HASH' && ref($reservation->{target}) eq 'HASH') {
        my $target = $reservation->{target};
        my $old_total = $target->{disk_total_bytes};
        $total = $old_total if defined($old_total) && $old_total > $total;
        if (ref($target->{disk_storage_bytes}) eq 'HASH') {
            for my $storeid (keys %{$target->{disk_storage_bytes}}) {
                $stores{$storeid} = $target->{disk_storage_bytes}{$storeid}
                    if !defined($stores{$storeid}) || $target->{disk_storage_bytes}{$storeid} > $stores{$storeid};
            }
        }
    }
    return { total => $total, by_storage => \%stores };
}

sub _disk_target_with_delta {
    my ($disk, $reservation, $storeid, $delta) = @_;
    my $target = _disk_reservation_target($disk, $reservation);
    $target->{by_storage}{$storeid} = ($target->{by_storage}{$storeid} || 0) + $delta;
    $target->{total} += $delta;
    return $target;
}

sub _disk_current_target {
    my ($disk) = @_;
    return { total => $disk->{total} || 0, by_storage => { %{ $disk->{by_storage} || {} } } };
}

sub _disk_target_reached {
    my ($disk, $reservation) = @_;
    return 1 unless ref($reservation) eq 'HASH' && ref($reservation->{target}) eq 'HASH';
    my $target = $reservation->{target};
    return 0 if defined($target->{disk_total_bytes})
        && ($disk->{total} || 0) < $target->{disk_total_bytes};
    if (ref($target->{disk_storage_bytes}) eq 'HASH') {
        for my $storeid (keys %{ $target->{disk_storage_bytes} }) {
            return 0 if ($disk->{by_storage}{$storeid} || 0) < $target->{disk_storage_bytes}{$storeid};
        }
    }
    return 1;
}

sub _check_disk_target_locked {
    my ($class, $pool, $vmid, $type, $disk, $state, %opts) = @_;
    my $limits = _limits($state, $pool);
    return unless $state->{active} && _disk_limits_enabled($limits);
    _fail_closed($pool, 'disco', 'configuração atual inválida') if $state->{degraded};
    my $key = "$type:$vmid";
    my $reservations = $opts{reservations} || _read_reservations($pool);
    my $live = $reservations->{$key};
    delete $reservations->{$key} if $live && _disk_target_reached($disk, $live)
        && !defined($live->{target}{cpu}) && !defined($live->{target}{memory_mib});
    $live = $reservations->{$key};
    my $usage = $opts{usage} || $class->_usage($pool, $state, %opts, reservations => $reservations);
    _fail_closed($pool, 'disco', join('; ', @{ $usage->{disk_errors} || [] }))
        if @{$usage->{disk_errors} || []};
    my $old = $usage->{guests}{$key} || {
        disk_total_bytes => 0, disk_storage_bytes => {},
    };
    my $base_total = ($usage->{usage}{disk_total_bytes} || 0) - ($old->{disk_total_bytes} || 0);
    my %base_storage = %{ $usage->{usage}{disk_storage_bytes} || {} };
    for my $storeid (keys %{ $old->{disk_storage_bytes} || {} }) {
        $base_storage{$storeid} -= $old->{disk_storage_bytes}{$storeid};
    }
    my $target = _disk_reservation_target($disk, $live);
    if ($limits->{disk_total_gib}{enabled}
        && $base_total + $target->{total} > $limits->{disk_total_gib}{max} * GIB) {
        _limit_error($pool, 'disco total', $base_total + ($old->{disk_total_bytes} || 0),
            $target->{total}, $limits->{disk_total_gib}{max} * GIB);
    }
    if ($limits->{disk_storage}{enabled}) {
        my $store_limits = $limits->{disk_storage}{limits} || {};
        for my $storeid (keys %{ $target->{by_storage} }) {
            next unless defined($store_limits->{$storeid});
            my $requested = $target->{by_storage}{$storeid} || 0;
            my $old_store = $old->{disk_storage_bytes}{$storeid} || 0;
            if (($base_storage{$storeid} || 0) + $requested > $store_limits->{$storeid} * GIB) {
                _limit_error($pool, "disco em $storeid", ($base_storage{$storeid} || 0) + $old_store,
                    $requested, $store_limits->{$storeid} * GIB);
            }
        }
    }
    return unless $opts{reserve};
    my $old_res = $reservations->{$key};
    my $record = $old_res && ref($old_res) eq 'HASH' ? { %{$old_res} } : {};
    $record->{target} = { %{ $record->{target} || {} } };
    $record->{target}{disk_total_bytes} = $target->{total};
    $record->{target}{disk_storage_bytes} = { %{ $target->{by_storage} } };
    $record->{expires} = time + RESERVATION_TTL;
    $reservations->{$key} = $record;
    _write_reservations($pool, $reservations);
    return { ok => 1, reservation => $record, previous => $old_res };
}

sub _metrics {
    my ($type, $conf) = @_;
    my $current = { %{$conf || {}} };
    delete $current->{pending};
    my $pending = _merge_pending($conf);
    my ($cpu_current, $cpu_pending, $cpu_defined);
    if ($type eq 'qemu' || $type eq 'kvm') {
        my $class = 'PVE::QemuConfig';
        eval { require PVE::QemuConfig; 1 } or die "configuração QEMU indisponível";
        $cpu_current = $class->get_derived_property($current, 'max-cpu');
        $cpu_pending = $class->get_derived_property($pending, 'max-cpu');
        $cpu_defined = 1;
    } else {
        $cpu_current = $current->{cpulimit} || $current->{cores};
        $cpu_pending = $pending->{cpulimit} || $pending->{cores};
        $cpu_defined = defined($cpu_current) || defined($cpu_pending) ? 1 : 0;
    }
    my $memory_current = $current->{memory};
    my $memory_pending = $pending->{memory};
    my $memory = (defined($memory_current) && defined($memory_pending))
        ? ($memory_current > $memory_pending ? $memory_current : $memory_pending)
        : (defined($memory_current) ? $memory_current : $memory_pending);
    return {
        cpu => (defined($cpu_current) && defined($cpu_pending))
            ? ($cpu_current > $cpu_pending ? $cpu_current : $cpu_pending)
            : (defined($cpu_current) ? $cpu_current : $cpu_pending),
        cpu_current => $cpu_current, cpu_defined => $cpu_defined,
        memory_mib => $memory // 0,
        template => $conf->{template} ? 1 : 0,
    };
}

sub _rrd_vm_running {
    my ($vmid, $opts) = @_;
    my $rrd = ref($opts) eq 'HASH' && ref($opts->{rrd}) eq 'HASH' ? $opts->{rrd} : $TEST_RRD;
    if (!ref($rrd)) {
        require PVE::Cluster;
        $rrd = PVE::Cluster::rrd_dump();
    }
    return undef unless ref($rrd) eq 'HASH';
    my $key;
    if (eval { require PVE::API2Tools; 1 }) {
        $key = eval { PVE::API2Tools::get_rrd_key($rrd, 'vm', $vmid) };
    }
    $key //= "pve-vm-9.0/$vmid";
    my $data = $rrd->{$key};
    return undef unless ref($data) eq 'ARRAY' && defined($data->[2]);
    return ($data->[2] // '') eq 'running' ? 1 : 0;
}

sub _running {
    my ($type, $vmid, $entry, $opts) = @_;
    return $opts->{running_cb}->($type, $vmid, $entry) if ref($opts->{running_cb}) eq 'CODE';
    return _rrd_vm_running($vmid, $opts);
}

sub _usage {
    my ($class, $pool, $state, %opts) = @_;
    my $limits = _limits($state, $pool) || {
        mode => 'allocated', cpu => { enabled => 0 }, memory_mib => { enabled => 0 },
        disk_total_gib => { enabled => 0 }, disk_storage => { enabled => 0 },
    };
    my $ucfg = $opts{usercfg} || _usercfg(\%opts);
    my $members = $opts{members} || { map { $_ => 1 } _pool_members($ucfg, $pool) };
    my $vmlist = $opts{vmlist} || _vmlist(\%opts);
    my $reservations = $opts{reservations} || _read_reservations($pool);
    my $disk_enabled = _disk_limits_enabled($limits) && !$opts{skip_disk};
    my $usage = { cpu => 0, memory_mib => 0, disk_total_bytes => 0, disk_storage_bytes => {} };
    my %guests;
    my @errors;
    my @disk_errors;
    for my $vmid (sort keys %{$members}) {
        my $entry = $vmlist->{$vmid} || {};
        my $type = _type_for($vmid, $entry, $ucfg);
        my $conf = eval { _load_config($type, $vmid, { %opts, node => $entry->{node} }) };
        my $load_error = $@;
        if ($load_error || ref($conf) ne 'HASH') {
            my $detail = _error_detail($load_error);
            push @errors, "guest $vmid: configuração indisponível" . ($detail ? " ($detail)" : '');
            push @disk_errors, "guest $vmid: configuração de disco indisponível"
                if $disk_enabled;
            next;
        }
        my $metrics = eval { _metrics($type, $conf) };
        my $metrics_error = $@;
        if ($metrics_error || !$metrics) {
            my $detail = _error_detail($metrics_error);
            push @errors, "guest $vmid: contabilidade indisponível" . ($detail ? " ($detail)" : '');
            push @disk_errors, "guest $vmid: contabilidade de disco indisponível"
                if $disk_enabled;
            next;
        }
        next if $metrics->{template};
        my $running = _running($type, $vmid, $entry, \%opts);
        my $count_cpu_memory = 1;
        if (($limits->{mode} // 'allocated') eq 'running') {
            if (!defined($running)) {
                push @errors, "guest $vmid: estado running indisponível"
                    if _has_cpu_or_memory_limit($limits);
                $count_cpu_memory = 0;
            } else {
                $count_cpu_memory = $running ? 1 : 0;
            }
        }
        my $disk = { total => 0, by_storage => {}, volumes => {}, errors => [] };
        if ($disk_enabled) {
            $disk = eval { _disk_inventory($type, $conf, storecfg => $opts{storecfg}, vmid => $vmid) };
            my $disk_error = $@;
            if ($disk_error || !$disk || @{$disk->{errors} || []}) {
                my $detail = _error_detail($disk_error || join('; ', @{$disk->{errors} || []}));
                push @disk_errors, "guest $vmid: contabilidade de disco indisponível"
                    . ($detail ? " ($detail)" : '');
            }
        }
        my $key = "$type:$vmid";
        my $cpu = $metrics->{cpu} // 0;
        my $memory = $metrics->{memory_mib} // 0;
        my $disk_total = $disk->{total} || 0;
        my %disk_storage = %{ $disk->{by_storage} || {} };
        if (my $r = $reservations->{$key}) {
            $cpu = $r->{target}{cpu} if defined($r->{target}{cpu}) && $r->{target}{cpu} > $cpu;
            $memory = $r->{target}{memory_mib}
                if defined($r->{target}{memory_mib}) && $r->{target}{memory_mib} > $memory;
            if ($disk_enabled && defined($r->{target}{disk_total_bytes})
                && $r->{target}{disk_total_bytes} > $disk_total) {
                $disk_total = $r->{target}{disk_total_bytes};
            }
            if ($disk_enabled && ref($r->{target}{disk_storage_bytes}) eq 'HASH') {
                for my $storeid (keys %{ $r->{target}{disk_storage_bytes} }) {
                    $disk_storage{$storeid} = $r->{target}{disk_storage_bytes}{$storeid}
                        if !defined($disk_storage{$storeid})
                        || $r->{target}{disk_storage_bytes}{$storeid} > $disk_storage{$storeid};
                }
            }
        }
        if ($count_cpu_memory) {
            $usage->{cpu} += $cpu;
            $usage->{memory_mib} += $memory;
        } else {
            $cpu = 0;
            $memory = 0;
        }
        $usage->{disk_total_bytes} += $disk_total;
        for my $storeid (keys %disk_storage) {
            $usage->{disk_storage_bytes}{$storeid} += $disk_storage{$storeid};
        }
        $guests{$key} = { cpu => $cpu, memory_mib => $memory,
            disk_total_bytes => $disk_total, disk_storage_bytes => \%disk_storage,
            metrics => $metrics, disk => $disk, type => $type, vmid => $vmid,
            running => $running };
    }
    return { usage => $usage, guests => \%guests, errors => \@errors,
        disk_errors => \@disk_errors,
        usercfg => $ucfg, vmlist => $vmlist, reservations => $reservations };
}

sub _with_pool_lock {
    my ($pool, $code) = @_;
    my $domain = 'poollimits-' . _safe_component($pool);
    return MMPve::Core::Config->with_domain_lock($domain, $code);
}

sub accounting {
    my ($class, $pool, %opts) = @_;
    my $state = $class->_state;
    return { usage => { cpu => 0, memory_mib => 0, disk_total_bytes => 0,
            disk_storage_bytes => {} }, guests => {}, errors => [] }
        unless $state->{active} || _limits($state, $pool);
    return $class->_usage($pool, $state, %opts);
}

sub check_config {
    my ($class, $pool, $vmid, $type, $conf, %opts) = @_;
    my $state = $class->_state;
    return unless $state->{active} && _limits($state, $pool);
    my $limits = _limits($state, $pool);
    return unless _has_any_limit($limits);
    my $target = eval { _metrics($type, $conf) };
    my $target_error = $@;
    _fail_closed($pool, 'recursos', _error_detail($target_error) || 'configuração do guest indisponível')
        if $target_error || !$target;
    return if $target->{template};
    if ($type eq 'lxc' && $limits->{cpu}{enabled} && !$target->{cpu_defined}) {
        _fail_closed($pool, 'vCPU', "CT $vmid não tem cpulimit nem cores");
    }
    my $current = $opts{current_metrics} || $target;
    my $running = exists($opts{running}) ? $opts{running}
        : _running($type, $vmid, $opts{entry} || {}, \%opts);
    if (($limits->{mode} // 'allocated') eq 'running' && !defined($running) && !$opts{starting}) {
        _fail_closed($pool, 'recursos', 'estado running indisponível')
            if $target->{cpu} > ($current->{cpu} // 0)
                || $target->{memory_mib} > ($current->{memory_mib} // 0);
    }
    my $target_disk = $opts{target_disk} || { total => 0, by_storage => {} };
    my $current_disk = $opts{current_disk} || { total => 0, by_storage => {} };
    my $disk_increase = 0;
    if (_disk_limits_enabled($limits) && !$opts{skip_disk}) {
        if (exists($opts{current_conf})) {
            $disk_increase = _disk_structural_delta($type, $opts{current_conf}, $conf)->{increase};
        } else {
            $disk_increase = _disk_config_has_volume($type, $conf) ? 1 : 0;
        }
    }
    $disk_increase = 1 if exists($opts{target_disk})
        && (($target_disk->{total} || 0) > ($current_disk->{total} || 0));
    if (exists($opts{target_disk})) {
        for my $storeid (keys %{ $target_disk->{by_storage} || {} }) {
            $disk_increase = 1
                if ($target_disk->{by_storage}{$storeid} || 0)
                    > ($current_disk->{by_storage}{$storeid} || 0);
        }
    }
    if (!$opts{starting} && ($target->{cpu} // 0) <= ($current->{cpu} // 0)
        && ($target->{memory_mib} // 0) <= ($current->{memory_mib} // 0)
        && !$disk_increase) {
        return;
    }
    my %check_opts = %opts;
    $check_opts{skip_disk} = 1 if _disk_limits_enabled($limits) && !$disk_increase;
    delete $check_opts{target_disk} unless exists($opts{target_disk});
    delete $check_opts{current_disk} unless exists($opts{current_disk});
    return _with_pool_lock($pool, sub {
        return $class->_check_guest_locked($pool, $vmid, $type, $conf, $state,
            %check_opts, target_disk => $target_disk, current_disk => $current_disk);
    });
}

sub _guest_pool {
    my ($vmid, $ucfg) = @_;
    return $ucfg->{vms}{$vmid} if ref($ucfg->{vms}) eq 'HASH';
    return;
}

sub _check_guest_locked {
    my ($class, $pool, $vmid, $type, $conf, $state, %opts) = @_;
    my $limits = _limits($state, $pool);
    return unless $state->{active} && $limits && _has_any_limit($limits);
    my $target = eval { _metrics($type, $conf) };
    my $target_error = $@;
    _fail_closed($pool, 'recursos', _error_detail($target_error) || 'configuração do guest indisponível')
        if $target_error || !$target;
    return if $target->{template};
    if ($type eq 'lxc' && $limits->{cpu}{enabled} && !$target->{cpu_defined}) {
        _fail_closed($pool, 'vCPU', "CT $vmid não tem cpulimit nem cores");
    }
    if (_disk_limits_enabled($limits) && !$opts{starting} && !$opts{skip_disk}
        && !exists($opts{target_disk})) {
        my $disk = eval { _disk_inventory($type, $conf,
            storecfg => $opts{storecfg}, vmid => $vmid) };
        my $disk_error = $@;
        _fail_closed($pool, 'disco', _error_detail($disk_error || join('; ', @{$disk->{errors} || []}))
            || 'configuração do guest indisponível')
            if $disk_error || !$disk || @{$disk->{errors} || []};
        $opts{target_disk} = $disk;
    }
    my $running = exists($opts{running}) ? $opts{running}
        : _running($type, $vmid, $opts{entry} || {}, \%opts);
    my $current = $opts{current_metrics} || $target;
    my $current_cpu = $current->{cpu} // 0;
    my $current_memory = $current->{memory_mib} // 0;
    my $count_cpu_memory = 1;
    if (($limits->{mode} // 'allocated') eq 'running') {
        if (!defined($running)) {
            _fail_closed($pool, 'recursos', 'estado running indisponível')
                if ($target->{cpu} // 0) > $current_cpu
                    || ($target->{memory_mib} // 0) > $current_memory;
            $count_cpu_memory = 0;
        } else {
            $count_cpu_memory = $opts{starting} || $running ? 1 : 0;
        }
    }
    if ($type eq 'lxc' && $limits->{cpu}{enabled} && !$target->{cpu_defined}) {
        _fail_closed($pool, 'vCPU', "CT $vmid não tem cpulimit nem cores");
    }
    my $target_cpu = $target->{cpu} // 0;
    my $target_memory = $target->{memory_mib} // 0;
    my $target_disk = $opts{target_disk} || { total => 0, by_storage => {} };
    my $current_disk = $opts{current_disk} || { total => 0, by_storage => {} };
    $target_disk = { total => 0, by_storage => {} } if $opts{starting};
    $current_disk = { total => 0, by_storage => {} } if $opts{starting};
    my $disk_increase = $target_disk->{total} > ($current_disk->{total} || 0);
    for my $storeid (keys %{ $target_disk->{by_storage} || {} }) {
        $disk_increase = 1 if ($target_disk->{by_storage}{$storeid} || 0)
            > ($current_disk->{by_storage}{$storeid} || 0);
    }
    my $cpu_memory_increase = $count_cpu_memory
        && (($target_cpu > $current_cpu) || ($target_memory > $current_memory));
    my $increase = $opts{starting} || $cpu_memory_increase || $disk_increase;
    return unless $increase;
    my $key = "$type:$vmid";
    my $reservations = _read_reservations($pool);
    if (my $live = $reservations->{$key}) {
        my $reached_cpu = !defined($live->{target}{cpu}) || $target_cpu >= $live->{target}{cpu};
        my $reached_memory = !defined($live->{target}{memory_mib})
            || $target_memory >= $live->{target}{memory_mib};
        my $reached_disk = _disk_target_reached($target_disk, $live);
        delete $reservations->{$key} if $reached_cpu && $reached_memory && $reached_disk;
    }
    my $usage = $class->_usage($pool, $state, %opts,
        skip_disk => ($opts{skip_disk} || $opts{starting}) ? 1 : 0,
        reservations => $reservations);
    _fail_closed($pool, 'recursos', join('; ', @{ $usage->{errors} }))
        if ($opts{starting} || $cpu_memory_increase) && @{$usage->{errors}};
    _fail_closed($pool, 'disco', join('; ', @{ $usage->{disk_errors} || [] }))
        if !$opts{skip_disk} && $disk_increase && @{$usage->{disk_errors} || []};
    my $old = $usage->{guests}{$key} || {
        cpu => 0, memory_mib => 0, disk_total_bytes => 0, disk_storage_bytes => {},
    };
    my $base_cpu = $usage->{usage}{cpu} - ($old->{cpu} // 0);
    my $base_memory = $usage->{usage}{memory_mib} - ($old->{memory_mib} // 0);
    # Guest entrando no pool já está em members para a conta, mas o "uso atual"
    # da mensagem é o do pool sem ele (antes saía somado ao pedido).
    my $shown = $opts{entering}
        ? { cpu => 0, memory_mib => 0, disk_total_bytes => 0, disk_storage_bytes => {} } : $old;
    my $base_disk_total = ($usage->{usage}{disk_total_bytes} || 0)
        - ($old->{disk_total_bytes} || 0);
    my %base_disk_storage = %{ $usage->{usage}{disk_storage_bytes} || {} };
    for my $storeid (keys %{ $old->{disk_storage_bytes} || {} }) {
        $base_disk_storage{$storeid} -= $old->{disk_storage_bytes}{$storeid};
    }
    if ($state->{degraded}) {
        _fail_closed($pool, 'recursos', 'configuração atual inválida');
    }
    if ($count_cpu_memory && $limits->{cpu}{enabled} && $base_cpu + $target_cpu > $limits->{cpu}{max}) {
        _limit_error($pool, 'vCPU', $base_cpu + ($shown->{cpu} // 0), $target_cpu, $limits->{cpu}{max});
    }
    if ($count_cpu_memory && $limits->{memory_mib}{enabled}
        && $base_memory + $target_memory > $limits->{memory_mib}{max}) {
        _limit_error($pool, 'RAM MiB', $base_memory + ($shown->{memory_mib} // 0), $target_memory, $limits->{memory_mib}{max});
    }
    my $old_res = $reservations->{$key};
    my $disk_target = _disk_reservation_target($target_disk, $old_res);
    if (_disk_limits_enabled($limits) && !$opts{starting} && !$opts{skip_disk}) {
        if ($limits->{disk_total_gib}{enabled}
            && $base_disk_total + $disk_target->{total} > $limits->{disk_total_gib}{max} * GIB) {
            _limit_error($pool, 'disco total', $base_disk_total + ($shown->{disk_total_bytes} || 0),
                $disk_target->{total}, $limits->{disk_total_gib}{max} * GIB);
        }
        if ($limits->{disk_storage}{enabled}) {
            my $store_limits = $limits->{disk_storage}{limits} || {};
            for my $storeid (keys %{ $disk_target->{by_storage} }) {
                next unless defined($store_limits->{$storeid});
                my $requested = $disk_target->{by_storage}{$storeid} || 0;
                my $old_store = $shown->{disk_storage_bytes}{$storeid} || 0;
                _limit_error($pool, "disco em $storeid", ($base_disk_storage{$storeid} || 0) + $old_store,
                    $requested, $store_limits->{$storeid} * GIB)
                    if ($base_disk_storage{$storeid} || 0) + $requested
                        > $store_limits->{$storeid} * GIB;
            }
        }
    }
    my $record_target = $old_res && ref($old_res->{target}) eq 'HASH'
        ? { %{ $old_res->{target} } } : {};
    if ($count_cpu_memory) {
        $record_target->{cpu} = $target_cpu;
        $record_target->{memory_mib} = $target_memory;
    }
    if (_disk_limits_enabled($limits) && !$opts{starting} && !$opts{skip_disk}) {
        $record_target->{disk_total_bytes} = $disk_target->{total};
        $record_target->{disk_storage_bytes} = { %{ $disk_target->{by_storage} } };
    }
    $reservations->{$key} = {
        target => $record_target,
        expires => time + RESERVATION_TTL,
        starting => $opts{starting} ? 1 : 0,
    };
    _write_reservations($pool, $reservations);
    return { ok => 1, reservation => $reservations->{$key}, previous => $old_res };
}

sub _owner_from_volid {
    my ($storecfg, $volid) = @_;
    return unless defined($volid) && !ref($volid);
    if (ref($TEST_VOL_OWNERS) eq 'HASH' && exists($TEST_VOL_OWNERS->{$volid})) {
        return $TEST_VOL_OWNERS->{$volid};
    }
    my @parsed = eval {
        require PVE::Storage;
        PVE::Storage::parse_volname($storecfg || _storage_cfg(), $volid);
    };
    return $parsed[2] if !$@ && defined($parsed[2]) && $parsed[2] =~ /^\d+$/;
    my (undef, $volname) = $volid =~ /\A([^:]+):(.+)\z/;
    return unless defined($volname);
    return $1 if $volname =~ /\A(?:vm|subvol)-(\d+)(?:-|\z)/;
    return $1 if $volname =~ /\A(\d+)\//;
    return;
}

sub _storage_context {
    my ($class, $vmid, $storecfg, %opts) = @_;
    return unless defined($vmid) && $vmid =~ /^\d+$/;
    my $state = $class->_state;
    return unless $state->{active};
    my $ucfg = _usercfg();
    my $pool = _guest_pool($vmid, $ucfg);
    return unless defined($pool);
    my $limits = _limits($state, $pool);
    return unless $limits && _disk_limits_enabled($limits);
    my $vmlist = _vmlist();
    my $entry = $vmlist->{$vmid} || {};
    my $type = _type_for($vmid, $entry, $ucfg);
    my $conf = eval { _load_config($type, $vmid, { node => $entry->{node} }) };
    _fail_closed($pool, 'disco', _error_detail($@) || 'configuração do guest indisponível')
        if $@ || ref($conf) ne 'HASH';
    # Migração é isenta: sai antes do inventário (sem I/O no storage).
    return if $opts{exempt_migrate} && _guest_is_migrating($conf);
    my $disk = eval { _disk_inventory($type, $conf, storecfg => $storecfg, vmid => $vmid) };
    my $disk_error = $@;
    _fail_closed($pool, 'disco', _error_detail($disk_error || join('; ', @{$disk->{errors} || []}))
        || 'configuração do guest indisponível')
        if !$opts{allow_disk_errors} && ($disk_error || !$disk || @{$disk->{errors} || []});
    $disk ||= { total => 0, by_storage => {}, volumes => {}, errors => [
        _error_detail($disk_error) || 'contabilidade de disco indisponível'
    ] };
    return {
        vmid => $vmid,
        state => $state, usercfg => $ucfg, vmlist => $vmlist, entry => $entry,
        pool => $pool, limits => $limits, type => $type, conf => $conf, disk => $disk,
        storecfg => $storecfg,
    };
}

sub _config_has_volid {
    my ($type, $conf, $volid) = @_;
    return 0 unless ref($conf) eq 'HASH';
    for my $key (keys %{$conf}) {
        my $entry = _disk_entry($type, $key, $conf->{$key});
        return 1 if $entry && defined($entry->{volid}) && $entry->{volid} eq $volid;
    }
    return 0;
}

sub _disk_context_is_known {
    my ($ctx) = @_;
    return 1 unless @{$ctx->{disk}{errors} || []};
    _fail_closed($ctx->{pool}, 'disco', join('; ', @{$ctx->{disk}{errors}}));
}

sub _reserve_storage_delta {
    my ($class, $ctx, $storeid, $delta) = @_;
    return unless defined($delta) && $delta > 0;
    return _with_pool_lock($ctx->{pool}, sub {
        my $state = $class->_state;
        my $ucfg = _usercfg();
        my $limits = _limits($state, $ctx->{pool});
        return unless $state->{active} && $limits && _disk_limits_enabled($limits);
        my $vmlist = _vmlist();
        my $entry = $vmlist->{$ctx->{vmid}} || $ctx->{entry} || {};
        my $conf = eval { _load_config($ctx->{type}, $ctx->{vmid}, { node => $entry->{node} }) };
        _fail_closed($ctx->{pool}, 'disco', _error_detail($@) || 'configuração do guest indisponível')
            if $@ || ref($conf) ne 'HASH';
        my $disk = eval { _disk_inventory($ctx->{type}, $conf,
            storecfg => $ctx->{storecfg}, vmid => $ctx->{vmid}) };
        my $disk_error = $@;
        _fail_closed($ctx->{pool}, 'disco', _error_detail($disk_error || join('; ', @{$disk->{errors} || []}))
            || 'configuração do guest indisponível')
            if $disk_error || !$disk || @{$disk->{errors} || []};
        my $key = "$ctx->{type}:$ctx->{vmid}";
        my $reservations = _read_reservations($ctx->{pool});
        my $target = _disk_target_with_delta($disk, $reservations->{$key}, $storeid, $delta);
        return $class->_check_disk_target_locked($ctx->{pool}, $ctx->{vmid}, $ctx->{type},
            $target, $state, reserve => 1, reservations => $reservations,
            usercfg => $ucfg, vmlist => $vmlist, entry => $entry,
            storecfg => $ctx->{storecfg});
    });
}

sub check_storage_alloc {
    my ($class, $storecfg, $storeid, $vmid, $fmt, $name, $size_kib) = @_;
    return if _is_exempt_volid(defined($name) ? $name : '');
    my $ctx = $class->_storage_context($vmid, $storecfg, allow_disk_errors => 1, exempt_migrate => 1);
    return unless $ctx;
    return if _guest_is_migrating($ctx->{conf});
    return if defined($name) && _config_has_volid($ctx->{type}, $ctx->{conf}, "$storeid:$name");
    _disk_context_is_known($ctx);
    my $bytes = defined($size_kib) && !ref($size_kib) && $size_kib =~ /^\d+(?:\.\d+)?$/
        ? int($size_kib * 1024) : undef;
    _fail_closed($ctx->{pool}, 'disco', 'tamanho da alocação indisponível')
        unless defined($bytes);
    return if $bytes == 0;
    if (defined($name) && $ctx->{disk}{volumes}{"$storeid:$name"}) {
        return;
    }
    return $class->_reserve_storage_delta($ctx, $storeid, $bytes);
}

sub check_storage_clone {
    my ($class, $storecfg, $volid, $vmid, $snap) = @_;
    return if _is_exempt_volid($volid);
    my $ctx = $class->_storage_context($vmid, $storecfg, allow_disk_errors => 1, exempt_migrate => 1);
    return unless $ctx;
    return if _guest_is_migrating($ctx->{conf});
    _disk_context_is_known($ctx);
    my ($storeid) = $volid =~ /\A([^:]+):/;
    return unless defined($storeid);
    my $size = $ctx->{disk}{volumes}{$volid}{size};
    $size = _volume_size($storecfg, $volid) unless defined($size);
    _fail_closed($ctx->{pool}, 'disco', 'tamanho do clone indisponível') unless defined($size);
    return if $size == 0;
    return $class->_reserve_storage_delta($ctx, $storeid, $size);
}

sub check_storage_resize {
    my ($class, $storecfg, $volid, $size, $running, $snapname) = @_;
    return if defined($snapname) || _is_exempt_volid($volid);
    my $owner = _owner_from_volid($storecfg, $volid);
    return unless defined($owner);
    my $ctx = $class->_storage_context($owner, $storecfg, allow_disk_errors => 1);
    return unless $ctx;
    my $old = $ctx->{disk}{volumes}{$volid};
    if (!$old) {
        for my $key (keys %{$ctx->{conf} || {}}) {
            my $entry = _disk_entry($ctx->{type}, $key, $ctx->{conf}{$key});
            next unless $entry && $entry->{volid} eq $volid;
            my $size = $entry->{size};
            $size = _volume_size($storecfg, $volid) unless defined($size);
            $old = { size => $size, storage => $entry->{storeid} };
            last;
        }
    }
    return unless $old;
    _fail_closed($ctx->{pool}, 'disco', 'tamanho do volume indisponível')
        unless defined($size) && !ref($size) && $size =~ /^\d+(?:\.\d+)?$/
        && defined($old->{size});
    my $new_size = int($size);
    return if $new_size <= $old->{size};
    _disk_context_is_known($ctx);
    return $class->_reserve_storage_delta($ctx, $old->{storage}, $new_size - $old->{size});
}

sub check_storage_import {
    my ($class, $storecfg, $fh, $volid, $format, $snapshot, $base_snapshot,
        $with_snapshots, $allow_rename) = @_;
    return if _is_exempt_volid($volid);
    my $owner = _owner_from_volid($storecfg, $volid);
    return unless defined($owner);
    my $ctx = $class->_storage_context($owner, $storecfg, allow_disk_errors => 1, exempt_migrate => 1);
    return unless $ctx;
    return if _guest_is_migrating($ctx->{conf});
    return if _config_has_volid($ctx->{type}, $ctx->{conf}, $volid);
    _disk_context_is_known($ctx);
    my ($storeid) = $volid =~ /\A([^:]+):/;
    return unless defined($storeid);
    my $size = _volume_size($storecfg, $volid);
    _fail_closed($ctx->{pool}, 'disco', 'tamanho do volume importado indisponível')
        unless defined($size);
    return if $size == 0;
    return $class->_reserve_storage_delta($ctx, $storeid, $size);
}

sub check_write_config {
    my ($class, $guest_class, $vmid, $conf) = @_;
    return unless defined($guest_class) && ($guest_class eq 'PVE::QemuConfig' || $guest_class eq 'PVE::LXC::Config');
    my $state = $class->_state;
    return unless $state->{active};
    my $ucfg = _usercfg();
    my $pool = _guest_pool($vmid, $ucfg);
    return unless defined($pool);
    my $limits = _limits($state, $pool);
    return unless $limits && _has_any_limit($limits);
    my $type = $guest_class eq 'PVE::QemuConfig' ? 'qemu' : 'lxc';
    my $target = eval { _metrics($type, $conf) };
    my $target_error = $@;
    _fail_closed($pool, 'recursos', _error_detail($target_error) || 'configuração do guest indisponível')
        if $target_error || !$target;
    return if $target->{template};
    my $old = eval { $guest_class->load_config($vmid) };
    my $current = ref($old) eq 'HASH' ? _metrics($type, $old) : { cpu => 0, memory_mib => 0 };
    my $disk_increase = 0;
    my $migrating = _guest_is_migrating($old);
    if (_disk_limits_enabled($limits) && !$migrating && ref($old) eq 'HASH') {
        $disk_increase = _disk_structural_delta($type, $old, $conf)->{increase};
    } elsif (_disk_limits_enabled($limits) && !$migrating) {
        $disk_increase = _disk_config_has_volume($type, $conf) ? 1 : 0;
    }
    my $vmlist = _vmlist();
    my $running = _running($type, $vmid, $vmlist->{$vmid} || {}, { vmlist => $vmlist });
    my $cpu_memory_increase = ($target->{cpu} // 0) > ($current->{cpu} // 0)
        || ($target->{memory_mib} // 0) > ($current->{memory_mib} // 0);
    if (($limits->{mode} // 'allocated') eq 'running') {
        _fail_closed($pool, 'recursos', 'estado running indisponível')
            if !defined($running) && $cpu_memory_increase;
        $cpu_memory_increase = 0 if !$running;
    }
    # CT sem cores/cpulimit tem cpu indefinido: conta como 0 (sem aumento).
    return unless $cpu_memory_increase || $disk_increase;
    my $skip_disk = _disk_limits_enabled($limits) && (!$disk_increase || $migrating);
    return _with_pool_lock($pool, sub {
        return $class->_check_guest_locked($pool, $vmid, $type, $conf, $state,
            usercfg => $ucfg, vmlist => $vmlist, entry => $vmlist->{$vmid} || {},
            running => $running, current_metrics => $current,
            skip_disk => $skip_disk);
    });
}

sub check_start {
    my ($class, $conf, $vmid, $phase) = @_;
    return unless defined($phase) && $phase eq 'pre-start';
    my $state = $class->_state;
    return unless $state->{active};
    my $ucfg = _usercfg();
    my $pool = _guest_pool($vmid, $ucfg);
    return unless defined($pool);
    my $limits = _limits($state, $pool);
    return unless $limits && ($limits->{mode} // 'allocated') eq 'running';
    my $vmlist = _vmlist();
    my $type = _type_for($vmid, $vmlist->{$vmid} || {}, $ucfg);
    return _with_pool_lock($pool, sub {
        $class->_check_guest_locked($pool, $vmid, $type, $conf, $state,
            usercfg => $ucfg, vmlist => $vmlist, starting => 1, running => 0,
            entry => $vmlist->{$vmid} || {});
    });
}

sub check_pool_entry {
    my ($class, $vmid, $pool) = @_;
    return unless defined($pool) && length($pool);
    my $state = $class->_state;
    return unless $state->{active} && _limits($state, $pool);
    my $ucfg = _usercfg();
    my $vmlist = _vmlist();
    my $type = _type_for($vmid, $vmlist->{$vmid} || {}, $ucfg);
    my $conf = _load_config($type, $vmid, { node => $vmlist->{$vmid}{node} });
    my %members = map { $_ => 1 } _pool_members($ucfg, $pool);
    $members{$vmid} = 1;
    return _with_pool_lock($pool, sub {
        $class->_check_guest_locked($pool, $vmid, $type, $conf, $state,
            usercfg => $ucfg, vmlist => $vmlist, entry => $vmlist->{$vmid} || {},
            running => _running($type, $vmid, $vmlist->{$vmid} || {}, {}),
            current_metrics => { cpu => 0, memory_mib => 0 }, members => \%members, entering => 1);
    });
}

sub check_pool_update {
    my ($class, $param, $usercfg) = @_;
    return unless ref($param) eq 'HASH' && !($param->{delete});
    my $pool = $param->{poolid};
    return unless defined($pool) && _limits($class->_state, $pool);
    $usercfg ||= _usercfg();
    my @vmids = eval {
        require PVE::Tools;
        PVE::Tools::split_list($param->{vms} // '');
    };
    @vmids = grep { /^\d+$/ } split /[;,\s]+/, ($param->{vms} // '') if $@;
    my %members = map { $_ => 1 } _pool_members($usercfg, $pool);
    my @new = grep { !$members{$_} } @vmids;
    $members{$_} = 1 for @new;
    return unless @new;
    my $vmlist = _vmlist();
    return _with_pool_lock($pool, sub {
        for my $vmid (@new) {
            my $type = _type_for($vmid, $vmlist->{$vmid} || {}, $usercfg);
            my $conf = _load_config($type, $vmid, { node => $vmlist->{$vmid}{node} });
            $class->_check_guest_locked($pool, $vmid, $type, $conf, $class->_state,
                usercfg => $usercfg, vmlist => $vmlist, entry => $vmlist->{$vmid} || {},
                running => _running($type, $vmid, $vmlist->{$vmid} || {}, {}),
                current_metrics => { cpu => 0, memory_mib => 0 }, members => \%members, entering => 1);
        }
    });
}

# O create_vm do PVE já tirou o vmid de $param antes do hook: o nome do arquivo
# usa o vmid do hook. Com $param->{vmid} o nome ficava "backup/qemu-server/.conf",
# o parse_vm_config recusava e todo restore com --pool num pool limitado falhava.
sub _restore_qemu_conf {
    my ($archive, $storecfg, $param, $vmid) = @_;
    return undef unless ref($archive) eq 'HASH' && $archive->{volid};
    die "vmid do restore ausente\n" unless defined($vmid) && $vmid =~ /^\d+$/;
    require PVE::Storage;
    require PVE::QemuServer;
    my $old = PVE::Storage::extract_vzdump_config($storecfg, $archive->{volid});
    return PVE::QemuServer::restore_merge_config("backup/qemu-server/$vmid.conf", $old, $param || {});
}

sub check_qemu_create {
    my ($class, $param, $archive, $storecfg, $vmid, $pool) = @_;
    my $state = $class->_state;
    my $ucfg = _usercfg();
    $pool //= _guest_pool($vmid, $ucfg);
    return unless $state->{active} && defined($pool) && _limits($state, $pool);
    my $conf = ref($archive) eq 'HASH' ? eval { _restore_qemu_conf($archive, $storecfg, $param, $vmid) } : undef;
    my $restore_failed = ref($archive) eq 'HASH' && !$conf;
    $conf ||= { %{ $param || {} } };
    _fail_closed($pool, 'recursos', 'configuração do backup não pôde ser lida') if $restore_failed;
    return _with_pool_lock($pool, sub {
        $class->_check_guest_locked($pool, $vmid, 'qemu', $conf, $state,
            usercfg => $ucfg, vmlist => _vmlist(), running => 0,
            current_metrics => { cpu => 0, memory_mib => 0 }, storecfg => $storecfg);
    });
}

sub check_lxc_create {
    my ($class, $param, $archive, $storage_cfg, $vmid, $pool) = @_;
    my $state = $class->_state;
    my $ucfg = _usercfg();
    $pool //= _guest_pool($vmid, $ucfg);
    return unless $state->{active} && defined($pool) && _limits($state, $pool);
    my $conf = { %{ $param || {} } };
    if ($archive && $archive ne '-') {
        my $recovered = eval { require PVE::LXC::Create; (PVE::LXC::Create::recover_config($storage_cfg, $archive, $vmid))[0] };
        $conf = { %{ $recovered || {} }, %{$conf} } if $recovered;
    }
    _fail_closed($pool, 'recursos', 'configuração do backup não pôde ser lida')
        if $archive && $archive eq '-';
    return _with_pool_lock($pool, sub {
        $class->_check_guest_locked($pool, $vmid, 'lxc', $conf, $state,
            usercfg => $ucfg, vmlist => _vmlist(), running => 0,
            current_metrics => { cpu => 0, memory_mib => 0 }, storecfg => $storage_cfg);
    });
}

sub check_clone {
    my ($class, $newid, $pool, $conf, $type, $snapname) = @_;
    return unless defined($pool);
    if ($type eq 'lxc' && $snapname && ref($conf->{snapshots}) eq 'HASH') {
        $conf = $conf->{snapshots}{$snapname} || $conf;
    }
    # O clone de um template é um guest comum: sem isto o linked clone (caso
    # mais comum) passava pela regra "template não conta" e só a defesa final
    # (entrada no pool) recusava, depois de criar o volume.
    $conf = { %{ $conf || {} } };
    delete $conf->{template};
    my $state = $class->_state;
    return unless $state->{active} && _limits($state, $pool);
    my $ucfg = _usercfg();
    return _with_pool_lock($pool, sub {
        $class->_check_guest_locked($pool, $newid, $type, $conf, $state,
            usercfg => $ucfg, vmlist => _vmlist(), running => 0,
            current_metrics => { cpu => 0, memory_mib => 0 });
    });
}

sub pool_status {
    my ($class, $pool) = @_;
    my $state = $class->_state;
    my $limits = _limits($state, $pool);
    my $data = _with_pool_lock($pool, sub {
        my $usage = $class->_usage($pool, $state);
        return { poolid => $pool, module_enabled => $state->{active} ? 1 : 0,
            digest => $state->{digest}, limits => $limits,
            mode => $limits ? $limits->{mode} : 'allocated', usage => $usage->{usage},
            errors => $usage->{errors} || [], disk_errors => $usage->{disk_errors} || [],
            degraded => $state->{degraded} ? 1 : 0, config_error => $state->{error} };
    });
    return $data;
}

sub all_status {
    my ($class) = @_;
    my $state = $class->_state;
    my $ucfg = _usercfg();
    my %pools = map { $_ => 1 } keys %{ $ucfg->{pools} || {} };
    $pools{$_} = 1 for keys %{ $state->{poollimits}{pools} || {} };
    return { pools => [ map { $class->pool_status($_) } sort keys %pools ],
        degraded => $state->{degraded} ? 1 : 0, config_error => $state->{error} };
}

1;
