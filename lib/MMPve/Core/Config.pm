package MMPve::Core::Config;

# Estado desejado do cluster em /etc/pve/mm-tools/config.json (pmxcfs).
# Escritas passam por cfs_lock_domain; digest (SHA-256) evita sobrescrever
# edição concorrente e revision é sempre calculada no servidor.

use strict;
use warnings;
use JSON::PP qw(decode_json);
use Digest::SHA ();
use MMPve::Core::Util qw(read_file write_file_atomic ensure_dir flock_ex unlock log_line json_encode);

our $VERSION = '@MM_PVE_VERSION@';

use constant {
    CONFIG_DIR_DEFAULT => '/etc/pve/mm-tools',
    MAX_BYTES          => 1024 * 1024,         # limite do pmxcfs por arquivo
    PVE_PROXY_MAX_POST_BYTES       => 512 * 1024,
    BRANDING_REQUEST_MARGIN_BYTES => 16 * 1024,
    MAX_BRANDING_BYTES             => 256 * 1024,
    MAX_BRANDING_REQUEST_BYTES     => (512 * 1024) - (16 * 1024),
};

sub config_dir {
    return $ENV{MM_PVE_CONFIG_DIR} || CONFIG_DIR_DEFAULT;
}
sub config_path    { return config_dir() . '/config.json' }
sub branding_dir   { return config_dir() . '/branding' }
sub journal_dir    { return config_dir() . '/journal' }
sub lock_path      { return config_dir() . '/.lock' }

sub default {
    my ($class) = @_;
    return {
        revision => 1,
        modules => { renumber => 1, restore => 0, branding => 0, ui => 0, updates => 0, poollimits => 0 },
        vmid_scheme => [],
        restore => {
            gateway_vmid => undef,
            vlans => {},
            session_default_hours => 24,
            session_max_hours => 168,
            max_sessions => 10,
        },
        branding => {
            title => '',
            header_text => '',
            logo => '',
            favicon => '',
            login_text => '',
            assets_hash => '',
        },
        ui => {
            console => { qemu => 'default', lxc => 'default' },
            hide_subscription_popup => 0,
        },
        updates => {
            job_timeout => 3600,
            dpkg_lock_timeout => 300,
            retention => 10,
        },
        poollimits => { pools => {} },
    };
}

# ----------------------------------------------------------- validação

sub _err { my ($e, $m) = @_; push @{$e}, $m; return }

sub _is_int { return defined $_[0] && !ref $_[0] && $_[0] =~ /^\d+$/ }

sub _numify_schema {
    my ($data) = @_;
    return $data unless ref $data eq 'HASH';
    my $numify = sub {
        my ($value) = @_;
        return $value unless defined $value && !ref $value && $value =~ /^\d+$/;
        return 0 + $value;
    };

    $data->{revision} = $numify->($data->{revision}) if exists $data->{revision};
    if (ref $data->{vmid_scheme} eq 'ARRAY') {
        for my $range (@{$data->{vmid_scheme}}) {
            next unless ref $range eq 'HASH';
            for my $field (qw(from to)) {
                $range->{$field} = $numify->($range->{$field}) if exists $range->{$field};
            }
        }
    }
    my $restore = $data->{restore};
    if (ref $restore eq 'HASH') {
        for my $field (qw(gateway_vmid session_default_hours session_max_hours max_sessions)) {
            $restore->{$field} = $numify->($restore->{$field}) if exists $restore->{$field};
        }
        if (ref $restore->{vlans} eq 'HASH') {
            for my $vlan (values %{$restore->{vlans}}) {
                next unless ref $vlan eq 'HASH';
                $vlan->{prefix} = $numify->($vlan->{prefix}) if exists $vlan->{prefix};
            }
        }
    }
    my $updates = $data->{updates};
    if (ref $updates eq 'HASH') {
        for my $field (qw(job_timeout dpkg_lock_timeout retention)) {
            $updates->{$field} = $numify->($updates->{$field}) if exists $updates->{$field};
        }
    }
    my $poollimits = $data->{poollimits};
    if (ref $poollimits eq 'HASH' && ref $poollimits->{pools} eq 'HASH') {
        for my $pool (values %{ $poollimits->{pools} }) {
            next unless ref $pool eq 'HASH';
            for my $resource (qw(cpu memory_mib disk_total_gib)) {
                next unless ref $pool->{$resource} eq 'HASH';
                $pool->{$resource}{max} = $numify->($pool->{$resource}{max})
                    if exists $pool->{$resource}{max};
            }
            if (ref $pool->{disk_storage} eq 'HASH'
                && ref $pool->{disk_storage}{limits} eq 'HASH') {
                for my $storeid (keys %{ $pool->{disk_storage}{limits} }) {
                    $pool->{disk_storage}{limits}{$storeid} =
                        $numify->($pool->{disk_storage}{limits}{$storeid});
                }
            }
        }
    }
    return $data;
}

sub _is_ipv4 {
    my ($s) = @_;
    return 0 unless defined $s && !ref $s && $s =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
    my @o = ($1, $2, $3, $4);
    for my $x (@o) { return 0 if $x > 255 || $x =~ /^0\d/ }
    return 1;
}

# aceita JSON::PP::Boolean, 0/1 e "true"/"false"
sub _is_bool {
    my ($v) = @_;
    return 0 unless defined $v;
    return 1 if ref($v) && ref($v) =~ /Boolean/;
    return 1 if !ref $v && ($v eq '0' || $v eq '1' || $v eq 'true' || $v eq 'false');
    return 0;
}

sub validate {
    my ($class, $data, %opts) = @_;
    my @e = $class->validate_structure($data);
    return @e if @e;    # chaves/tipos quebrados: nem tenta validar módulo

    # validação por módulo (assets em disco, consistência local). É estado
    # do node, não corrupção do config: só barra GRAVAÇÃO (save/_write_locked),
    # nunca a LEITURA (load usa validate_structure sozinho — ver load()).
    require MMPve::Core::Modules;
    for my $m (MMPve::Core::Modules->all) {
        my $name = $m->name;
        my @me = $m->validate_section($data, %opts);
        _err(\@e, "[$name] $_") for @me;
    }
    return @e;
}

sub validate_structure {
    my ($class, $data) = @_;
    my @e;
    return ('config must be an object') unless ref $data eq 'HASH';

    my %known = map { $_ => 1 } qw(revision modules vmid_scheme restore branding ui updates poollimits);
    for my $k (sort keys %{$data}) {
        _err(\@e, "unknown key '$k'") unless $known{$k};
    }

    # revision
    if (exists $data->{revision}) {
        _err(\@e, 'revision must be an integer >= 1')
            unless _is_int($data->{revision}) && $data->{revision} >= 1;
    }

    # modules
    if (exists $data->{modules}) {
        my $m = $data->{modules};
        if (ref $m ne 'HASH') {
            _err(\@e, 'modules must be an object');
        } else {
            my %mk = map { $_ => 1 } qw(renumber restore branding ui updates poollimits);
            for my $k (sort keys %{$m}) {
                if (!$mk{$k}) { _err(\@e, "unknown module '$k'"); next }
                _err(\@e, "modules.$k must be boolean") unless _is_bool($m->{$k});
            }
        }
    }

    # vmid_scheme
    if (exists $data->{vmid_scheme}) {
        my $s = $data->{vmid_scheme};
        if (ref $s ne 'ARRAY') {
            _err(\@e, 'vmid_scheme must be a list');
        } else {
            my @ranges;
            my $i = 0;
            for my $r (@{$s}) {
                $i++;
                if (ref $r ne 'HASH') { _err(\@e, "vmid_scheme[$i] must be an object"); next }
                for my $k (sort keys %{$r}) {
                    _err(\@e, "vmid_scheme[$i]: unknown key '$k'")
                        unless $k =~ /^(label|from|to)$/;
                }
                _err(\@e, "vmid_scheme[$i].label is required (text)")
                    unless defined $r->{label} && !ref $r->{label} && length $r->{label} <= 64;
                _err(\@e, "vmid_scheme[$i].from/to must be integers 100..9999999")
                    unless _is_int($r->{from}) && _is_int($r->{to})
                    && $r->{from} >= 100 && $r->{to} <= 9999999;
                _err(\@e, "vmid_scheme[$i].from must be < to")
                    if _is_int($r->{from}) && _is_int($r->{to}) && $r->{from} >= $r->{to};
                push @ranges, [$r->{from}, $r->{to}, $r->{label} // "range$i"];
            }
            # sobreposição
            my @sorted = sort { $a->[0] <=> $b->[0] } @ranges;
            for my $j (1 .. $#sorted) {
                if ($sorted[$j][0] <= $sorted[$j - 1][1]) {
                    _err(\@e,
                        "vmid_scheme: overlapping ranges '$sorted[$j-1][2]' and '$sorted[$j][2]'");
                }
            }
        }
    }

    # restore
    if (exists $data->{restore}) {
        my $r = $data->{restore};
        if (ref $r ne 'HASH') {
            _err(\@e, 'restore must be an object');
        } else {
            my %rk = map { $_ => 1 } qw(gateway_vmid vlans session_default_hours session_max_hours max_sessions);
            for my $k (sort keys %{$r}) {
                _err(\@e, "restore: unknown key '$k'") unless $rk{$k};
            }
            if (defined $r->{gateway_vmid} && length($r->{gateway_vmid} // '')) {
                _err(\@e, 'restore.gateway_vmid must be an integer 100..9999999')
                    unless _is_int($r->{gateway_vmid}) && $r->{gateway_vmid} >= 100 && $r->{gateway_vmid} <= 9999999;
            }
            if (exists $r->{vlans}) {
                if (ref $r->{vlans} ne 'HASH') {
                    _err(\@e, 'restore.vlans must be an object');
                } else {
                    for my $vid (sort keys %{$r->{vlans}}) {
                        _err(\@e, "restore.vlans: VLAN '$vid' must be 1..4094")
                            unless $vid =~ /^\d+$/ && $vid >= 1 && $vid <= 4094;
                        my $v = $r->{vlans}{$vid};
                        if (ref $v ne 'HASH') { _err(\@e, "restore.vlans.$vid must be an object"); next }
                        for my $k (sort keys %{$v}) {
                            _err(\@e, "restore.vlans.$vid: unknown key '$k'")
                                unless $k =~ /^(gw_ip|prefix|note)$/;
                        }
                        _err(\@e, "restore.vlans.$vid.gw_ip is not a valid IPv4 address") unless _is_ipv4($v->{gw_ip});
                        _err(\@e, "restore.vlans.$vid.prefix must be 8..32")
                            unless _is_int($v->{prefix}) && $v->{prefix} >= 8 && $v->{prefix} <= 32;
                        if (defined $v->{note} && (!defined $v->{note} || ref $v->{note} || length($v->{note} // '') > 256)) {
                            _err(\@e, "restore.vlans.$vid.note must be text <= 256 characters");
                        }
                    }
                    # gw_ip não pode se repetir
                    my %seen;
                    for my $vid (sort keys %{$r->{vlans}}) {
                        my $ip = $r->{vlans}{$vid}{gw_ip} // next;
                        _err(\@e, "restore.vlans: IP $ip is repeated across VLANs") if $seen{$ip}++;
                    }
                }
            }
            for my $f (qw(session_default_hours session_max_hours max_sessions)) {
                next unless exists $r->{$f};
                _err(\@e, "restore.$f must be an integer >= 1")
                    unless _is_int($r->{$f}) && $r->{$f} >= 1;
            }
            _err(\@e, 'restore.session_default_hours > session_max_hours')
                if _is_int($r->{session_default_hours}) && _is_int($r->{session_max_hours})
                    && $r->{session_default_hours} > $r->{session_max_hours};
            _err(\@e, 'restore.session_max_hours > 168 (7 days)')
                if _is_int($r->{session_max_hours}) && $r->{session_max_hours} > 168;
            _err(\@e, 'restore.max_sessions > 100')
                if _is_int($r->{max_sessions}) && $r->{max_sessions} > 100;
        }
    }

    # branding
    if (exists $data->{branding}) {
        my $b = $data->{branding};
        if (ref $b ne 'HASH') {
            _err(\@e, 'branding must be an object');
        } else {
            my %bk = map { $_ => 1 } qw(title header_text logo favicon login_text assets_hash);
            for my $k (sort keys %{$b}) {
                _err(\@e, "branding: unknown key '$k'") unless $bk{$k};
            }
            _err(\@e, 'branding.title <= 100 caracteres')
                if defined $b->{title} && length($b->{title} // '') > 100;
            _err(\@e, 'branding.header_text <= 60 caracteres')
                if defined $b->{header_text} && length($b->{header_text} // '') > 60;
            _err(\@e, 'branding.login_text <= 200 caracteres')
                if defined $b->{login_text} && length($b->{login_text} // '') > 200;
            for my $f (qw(logo favicon)) {
                my $v = $b->{$f};
                next unless defined $v && length $v;
                _err(\@e, "branding.$f: invalid file name (use [A-Za-z0-9._-])")
                    unless $v =~ /^[A-Za-z0-9._-]+$/ && $v !~ /^\./;
                _err(\@e, "branding.$f: only .png is allowed")
                    unless $v =~ /^[0-9a-f]{64}\.png$/;
            }
            if (defined $b->{assets_hash} && length $b->{assets_hash}) {
                _err(\@e, 'branding.assets_hash precisa ser sha256:<64 hex>')
                    unless $b->{assets_hash} =~ /^sha256:[0-9a-f]{64}$/;
            }
        }
    }

    # ui (detalhes dos valores também são validados pelo módulo Ui)
    if (exists $data->{ui}) {
        my $u = $data->{ui};
        if (ref $u ne 'HASH') {
            _err(\@e, 'ui must be an object');
        } else {
            my %uk = map { $_ => 1 } qw(console hide_subscription_popup);
            for my $k (sort keys %{$u}) {
                _err(\@e, "ui: unknown key '$k'") unless $uk{$k};
            }
            if (exists $u->{console}) {
                if (ref $u->{console} ne 'HASH') {
                    _err(\@e, 'ui.console must be an object');
                } else {
                    for my $k (sort keys %{ $u->{console} }) {
                        _err(\@e, "ui.console: unknown key '$k'")
                            unless $k eq 'qemu' || $k eq 'lxc';
                        _err(\@e, "ui.console.$k must be text")
                            if $k eq 'qemu' || $k eq 'lxc'
                                ? ref($u->{console}{$k}) || !defined($u->{console}{$k})
                                : 0;
                    }
                }
            }
            _err(\@e, 'ui.hide_subscription_popup must be boolean')
                if exists $u->{hide_subscription_popup}
                    && !_is_bool($u->{hide_subscription_popup});
        }
    }

    # updates (detalhes dos limites também são validados pelo módulo Updates)
    if (exists $data->{updates}) {
        my $u = $data->{updates};
        if (ref $u ne 'HASH') {
            _err(\@e, 'updates must be an object');
        } else {
            my %uk = map { $_ => 1 } qw(job_timeout dpkg_lock_timeout retention);
            for my $k (sort keys %{$u}) {
                _err(\@e, "updates: unknown key '$k'") unless $uk{$k};
                _err(\@e, "updates.$k must be an integer >= 1")
                    if $uk{$k} && (!_is_int($u->{$k}) || $u->{$k} < 1);
            }
        }
    }

    # poollimits (detalhes são validados pelo módulo)
    if (exists $data->{poollimits}) {
        my $p = $data->{poollimits};
        if (ref $p ne 'HASH') {
            _err(\@e, 'poollimits must be an object');
        } elsif (exists($p->{pools}) && ref($p->{pools}) ne 'HASH') {
            _err(\@e, 'poollimits.pools must be an object');
        }
    }

    return @e;
}

# ----------------------------------------------------------- IO

sub digest_of {
    my ($class, $raw) = @_;
    return 'sha256:' . Digest::SHA::sha256_hex($raw);
}

sub load_raw {
    my ($class) = @_;
    my $path = $class->config_path;
    my $raw = eval { read_file($path) };
    if ($@ || !defined $raw) {
        return (undef, undef, $@ || "config missing at $path");
    }
    return ($raw, $class->digest_of($raw), undef);
}

sub load {
    my ($class) = @_;
    my ($raw, $digest, $err) = $class->load_raw;
    if (defined $err) {
        my $d = $class->default;
        return wantarray ? ($d, undef, 1) : $d;    # default + flag absent
    }
    my $data = eval { decode_json($raw) };
    die "invalid config.json: $@\n" if $@;
    my @e = $class->validate_structure($data);
    die "invalid config.json:\n" . join("\n", @e) . "\n" if @e;
    return wantarray ? ($data, $digest, 0) : $data;
}

sub _write_locked {
    my ($class, $data, %opt) = @_;
    my $raw_prev = eval { read_file($class->config_path) };
    my $previous;
    if (defined $raw_prev) {
        my $cur = $class->digest_of($raw_prev);
        if (defined $opt{digest} && $opt{digest} ne $cur) {
            die "DIGEST_MISMATCH: config changed since it was read (current $cur). Read and save again.\n";
        }
        $previous = eval { decode_json($raw_prev) };
        die "invalid config.json while saving: $@\n" if $@;
    } else {
        $previous = $class->default;
    }

    # O consumidor nunca escolhe a revisão. Ela vem do estado protegido pela
    # mesma trava da leitura e escrita.
    delete $data->{revision};

    my $def = $class->default;
    for my $k (qw(modules vmid_scheme restore branding ui updates poollimits)) {
        if (!exists $data->{$k}) {
            $data->{$k} = $def->{$k};
        } elsif (ref $def->{$k} eq 'HASH' && ref $data->{$k} eq 'HASH') {
            for my $kk (keys %{$def->{$k}}) {
                $data->{$k}{$kk} = $def->{$k}{$kk} unless exists $data->{$k}{$kk};
            }
            if ($k eq 'ui' && ref $data->{$k}{console} eq 'HASH') {
                for my $kk (keys %{ $def->{ui}{console} }) {
                    $data->{$k}{console}{$kk} = $def->{ui}{console}{$kk}
                        unless exists $data->{$k}{console}{$kk};
                }
            }
        }
    }
    _numify_schema($data);
    $data->{revision} = ($previous->{revision} // 0) + 1;
    _numify_schema($data);

    my @e = $class->validate($data, resources => $opt{resources});
    die "config rejected:\n" . join("\n", @e) . "\n" if @e;

    my $json = json_encode($data, pretty => 1);
    die "config exceeds 1 MiB (pmxcfs limit)\n" if length($json) > MAX_BYTES;
    write_file_atomic($class->config_path, $json . "\n", 0644);
    eval {
        require MMPve::Module::Poollimits;
        MMPve::Module::Poollimits->record_last_known_good($data);
        1;
    } or log_line('poollimits: could not update the valid local copy');
    log_line("config saved revision $data->{revision}");
    return ($data, $class->digest_of($json . "\n"));
}

sub _with_domain_lock {
    my ($class, $domain, $code) = @_;
    die "invalid lock domain\n"
        unless defined $domain && $domain =~ /^[A-Za-z0-9_-]+$/;
    ensure_dir($class->config_dir);

    # flock é somente fallback de testes; em um PVE a trava do pmxcfs cobre
    # todos os nodes do cluster.
    if (!$ENV{MM_PVE_DISABLE_CFS_LOCK} && eval { require PVE::Cluster; 1 }) {
        my $out = PVE::Cluster::cfs_lock_domain($domain, 10, $code);
        die $@ if $@;
        return $out;
    }

    my $lock_path = $domain eq 'mm-tools'
        ? $class->lock_path
        : $class->config_dir . '/.' . $domain . '.lock';
    my $lock = flock_ex($lock_path);
    my (@out, $out, $want) = ((), undef, wantarray);
    my $ok = eval {
        if ($want) { @out = $code->() } else { $out = $code->() }
        1;
    };
    my $err = $@;
    unlock($lock);
    die $err unless $ok;
    return $want ? @out : $out;
}

sub with_domain_lock {
    my ($class, $domain, $code) = @_;
    die 'with_domain_lock requires a callback' unless ref $code eq 'CODE';
    return $class->_with_domain_lock($domain, $code);
}

sub _with_write_lock {
    my ($class, $code) = @_;
    return $class->_with_domain_lock('mm-tools', $code);
}

sub save {
    my ($class, $data, %opt) = @_;
    die 'save requires a hashref' unless ref $data eq 'HASH';
    # cfs_lock_domain propagates scalar returns only. Keep the data/digest
    # pair in one reference so callers have the same contract on PVE and tests.
    my $saved = $class->_with_write_lock(sub {
        return [ $class->_write_locked($data, %opt) ];
    });
    return wantarray ? @{$saved} : $saved->[0];
}

sub save_section {
    my ($class, $section, $value, %opt) = @_;
    my %allowed = map { $_ => 1 } qw(modules vmid_scheme restore branding ui updates poollimits);
    die "invalid section '$section'\n" unless $allowed{$section};
    my $lock_domain = delete $opt{lock_domain} // 'mm-tools';
    my $before_write = delete $opt{before_write};
    my $after_write = delete $opt{after_write};
    my $saved = $class->_with_domain_lock($lock_domain, sub {
        my ($raw, $current_digest, $err) = $class->load_raw;
        my $cfg;
        if (defined $err) {
            $cfg = $class->default;
        } else {
            $cfg = eval { decode_json($raw) };
            die "invalid config.json while saving: $@\n" if $@;
        }
        $cfg->{$section} = $value;
        $before_write->($cfg) if $before_write;
        my @result = $class->_write_locked($cfg, %opt);
        $after_write->($cfg, @result) if $after_write;
        return [ @result ];
    });
    return wantarray ? @{$saved} : $saved->[0];
}

1;
