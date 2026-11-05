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
our ($TEST_USERCFG, $TEST_RESOURCES, $TEST_VMLIST, $TEST_RRD);

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
    my ($cfg, undef, $absent);
    my $err;
    eval { ($cfg, undef, $absent) = MMPve::Core::Config->load; 1 } or $err = $@;
    if (!$err) {
        my @errors = eval { MMPve::Module::Poollimits->validate_section($cfg) };
        $err = join('; ', @errors) if @errors;
        if (!$err) {
            my $enabled = ($cfg->{modules} || {})->{poollimits} ? 1 : 0;
            return { active => $enabled, degraded => 0, cfg => $cfg,
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
    my $limits = _limits($state, $pool) || { mode => 'allocated', cpu => { enabled => 0 }, memory_mib => { enabled => 0 } };
    my $ucfg = $opts{usercfg} || _usercfg(\%opts);
    my $members = $opts{members} || { map { $_ => 1 } _pool_members($ucfg, $pool) };
    my $vmlist = $opts{vmlist} || _vmlist(\%opts);
    my $reservations = $opts{reservations} || _read_reservations($pool);
    my $usage = { cpu => 0, memory_mib => 0 };
    my %guests;
    my @errors;
    for my $vmid (sort keys %{$members}) {
        my $entry = $vmlist->{$vmid} || {};
        my $type = _type_for($vmid, $entry, $ucfg);
        my $conf = eval { _load_config($type, $vmid, { %opts, node => $entry->{node} }) };
        my $load_error = $@;
        if ($load_error || ref($conf) ne 'HASH') {
            my $detail = _error_detail($load_error);
            push @errors, "guest $vmid: configuração indisponível" . ($detail ? " ($detail)" : '');
            next;
        }
        my $metrics = eval { _metrics($type, $conf) };
        my $metrics_error = $@;
        if ($metrics_error || !$metrics) {
            my $detail = _error_detail($metrics_error);
            push @errors, "guest $vmid: contabilidade indisponível" . ($detail ? " ($detail)" : '');
            next;
        }
        next if $metrics->{template};
        my $running = _running($type, $vmid, $entry, \%opts);
        if (($limits->{mode} // 'allocated') eq 'running') {
            if (!defined($running)) { push @errors, "guest $vmid: estado running indisponível"; next }
            next unless $running;
        }
        my $key = "$type:$vmid";
        my $cpu = $metrics->{cpu} // 0;
        my $memory = $metrics->{memory_mib} // 0;
        if (my $r = $reservations->{$key}) {
            $cpu = $r->{target}{cpu} if defined($r->{target}{cpu}) && $r->{target}{cpu} > $cpu;
            $memory = $r->{target}{memory_mib}
                if defined($r->{target}{memory_mib}) && $r->{target}{memory_mib} > $memory;
        }
        $usage->{cpu} += $cpu;
        $usage->{memory_mib} += $memory;
        $guests{$key} = { cpu => $cpu, memory_mib => $memory, metrics => $metrics,
            type => $type, vmid => $vmid, running => $running };
    }
    return { usage => $usage, guests => \%guests, errors => \@errors,
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
    return { usage => { cpu => 0, memory_mib => 0 }, guests => {}, errors => [] }
        unless $state->{active} || _limits($state, $pool);
    return $class->_usage($pool, $state, %opts);
}

sub check_config {
    my ($class, $pool, $vmid, $type, $conf, %opts) = @_;
    my $state = $class->_state;
    return unless $state->{active} && _limits($state, $pool);
    my $limits = _limits($state, $pool);
    return unless _has_cpu_or_memory_limit($limits);
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
        return;
    }
    return unless $opts{starting} || $target->{cpu} > ($current->{cpu} // 0)
        || $target->{memory_mib} > ($current->{memory_mib} // 0);
    return _with_pool_lock($pool, sub {
        return $class->_check_guest_locked($pool, $vmid, $type, $conf, $state, %opts);
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
    return unless $state->{active} && $limits && _has_cpu_or_memory_limit($limits);
    my $target = eval { _metrics($type, $conf) };
    my $target_error = $@;
    _fail_closed($pool, 'recursos', _error_detail($target_error) || 'configuração do guest indisponível')
        if $target_error || !$target;
    return if $target->{template};
    if ($type eq 'lxc' && $limits->{cpu}{enabled} && !$target->{cpu_defined}) {
        _fail_closed($pool, 'vCPU', "CT $vmid não tem cpulimit nem cores");
    }
    my $running = exists($opts{running}) ? $opts{running}
        : _running($type, $vmid, $opts{entry} || {}, \%opts);
    my $current = $opts{current_metrics} || $target;
    my $current_cpu = $current->{cpu} // 0;
    my $current_memory = $current->{memory_mib} // 0;
    if (($limits->{mode} // 'allocated') eq 'running' && !defined($running) && !$opts{starting}) {
        _fail_closed($pool, 'recursos', 'estado running indisponível')
            if $target->{cpu} > $current_cpu || $target->{memory_mib} > $current_memory;
        return;
    }
    my $count_target = ($limits->{mode} // 'allocated') eq 'running'
        ? ($opts{starting} || $running ? 1 : 0) : 1;
    return unless $count_target;
    if ($type eq 'lxc' && $limits->{cpu}{enabled} && !$target->{cpu_defined}) {
        _fail_closed($pool, 'vCPU', "CT $vmid não tem cpulimit nem cores");
    }
    my $target_cpu = $target->{cpu} // 0;
    my $target_memory = $target->{memory_mib} // 0;
    my $increase = $opts{starting} || $target_cpu > $current_cpu || $target_memory > $current_memory;
    return unless $increase;
    my $key = "$type:$vmid";
    my $reservations = _read_reservations($pool);
    if (my $live = $reservations->{$key}) {
        my $reached_cpu = !defined($live->{target}{cpu}) || $target_cpu >= $live->{target}{cpu};
        my $reached_memory = !defined($live->{target}{memory_mib})
            || $target_memory >= $live->{target}{memory_mib};
        delete $reservations->{$key} if $reached_cpu && $reached_memory;
    }
    my $usage = $class->_usage($pool, $state, %opts, reservations => $reservations);
    _fail_closed($pool, 'recursos', join('; ', @{ $usage->{errors} })) if @{ $usage->{errors} };
    my $old = $usage->{guests}{$key} || { cpu => 0, memory_mib => 0 };
    my $base_cpu = $usage->{usage}{cpu} - ($old->{cpu} // 0);
    my $base_memory = $usage->{usage}{memory_mib} - ($old->{memory_mib} // 0);
    if ($state->{degraded}) {
        _fail_closed($pool, 'recursos', 'configuração atual inválida');
    }
    if ($limits->{cpu}{enabled} && $base_cpu + $target_cpu > $limits->{cpu}{max}) {
        _limit_error($pool, 'vCPU', $base_cpu + ($old->{cpu} // 0), $target_cpu, $limits->{cpu}{max});
    }
    if ($limits->{memory_mib}{enabled} && $base_memory + $target_memory > $limits->{memory_mib}{max}) {
        _limit_error($pool, 'RAM MiB', $base_memory + ($old->{memory_mib} // 0), $target_memory, $limits->{memory_mib}{max});
    }
    my $old_res = $reservations->{$key};
    $reservations->{$key} = {
        target => { cpu => $target_cpu, memory_mib => $target_memory },
        expires => time + RESERVATION_TTL,
        starting => $opts{starting} ? 1 : 0,
    };
    _write_reservations($pool, $reservations);
    return { ok => 1, reservation => $reservations->{$key}, previous => $old_res };
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
    return unless $limits && _has_cpu_or_memory_limit($limits);
    my $type = $guest_class eq 'PVE::QemuConfig' ? 'qemu' : 'lxc';
    my $target = eval { _metrics($type, $conf) };
    my $target_error = $@;
    _fail_closed($pool, 'recursos', _error_detail($target_error) || 'configuração do guest indisponível')
        if $target_error || !$target;
    return if $target->{template};
    my $old = eval { $guest_class->load_config($vmid) };
    my $current = ref($old) eq 'HASH' ? _metrics($type, $old) : { cpu => 0, memory_mib => 0 };
    my $vmlist = _vmlist();
    my $running = _running($type, $vmid, $vmlist->{$vmid} || {}, { vmlist => $vmlist });
    if (($limits->{mode} // 'allocated') eq 'running') {
        _fail_closed($pool, 'recursos', 'estado running indisponível')
            if !defined($running) && (($target->{cpu} // 0) > ($current->{cpu} // 0)
                || ($target->{memory_mib} // 0) > ($current->{memory_mib} // 0));
        return if !$running;
    }
    # CT sem cores/cpulimit tem cpu indefinido: conta como 0 (sem aumento).
    return if ($target->{cpu} // 0) <= ($current->{cpu} // 0)
        && ($target->{memory_mib} // 0) <= ($current->{memory_mib} // 0);
    return _with_pool_lock($pool, sub {
        return $class->_check_guest_locked($pool, $vmid, $type, $conf, $state,
            usercfg => $ucfg, vmlist => $vmlist, entry => $vmlist->{$vmid} || {},
            running => $running, current_metrics => $current);
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
            current_metrics => { cpu => 0, memory_mib => 0 }, members => \%members);
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
                current_metrics => { cpu => 0, memory_mib => 0 }, members => \%members);
        }
    });
}

sub _restore_qemu_conf {
    my ($archive, $storecfg, $param) = @_;
    return undef unless ref($archive) eq 'HASH' && $archive->{volid};
    require PVE::Storage;
    require PVE::QemuServer;
    my $old = PVE::Storage::extract_vzdump_config($storecfg, $archive->{volid});
    return PVE::QemuServer::restore_merge_config('backup/qemu-server/' . ($param->{vmid} // '') . '.conf', $old, $param);
}

sub check_qemu_create {
    my ($class, $param, $archive, $storecfg, $vmid, $pool) = @_;
    my $state = $class->_state;
    my $ucfg = _usercfg();
    $pool //= _guest_pool($vmid, $ucfg);
    return unless $state->{active} && defined($pool) && _limits($state, $pool);
    my $conf = ref($archive) eq 'HASH' ? eval { _restore_qemu_conf($archive, $storecfg, $param) } : undef;
    my $restore_failed = ref($archive) eq 'HASH' && !$conf;
    $conf ||= { %{ $param || {} } };
    _fail_closed($pool, 'recursos', 'configuração do backup não pôde ser lida') if $restore_failed;
    return _with_pool_lock($pool, sub {
        $class->_check_guest_locked($pool, $vmid, 'qemu', $conf, $state,
            usercfg => $ucfg, vmlist => _vmlist(), running => 0,
            current_metrics => { cpu => 0, memory_mib => 0 });
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
            current_metrics => { cpu => 0, memory_mib => 0 });
    });
}

sub check_clone {
    my ($class, $newid, $pool, $conf, $type, $snapname) = @_;
    return unless defined($pool);
    if ($type eq 'lxc' && $snapname && ref($conf->{snapshots}) eq 'HASH') {
        $conf = $conf->{snapshots}{$snapname} || $conf;
    }
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
        return { poolid => $pool, limits => $limits, mode => $limits ? $limits->{mode} : 'allocated',
            usage => $usage->{usage}, errors => $usage->{errors}, degraded => $state->{degraded} ? 1 : 0,
            config_error => $state->{error} };
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
