package MMPve::Core::Config;

# Estado desejado do cluster em /etc/pve/mm-tools/config.json (pmxcfs).
# Escritas passam por cfs_lock_domain; digest (SHA-256) evita sobrescrever
# edição concorrente e revision é sempre calculada no servidor.

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Digest::SHA ();
use MMPve::Core::Util qw(read_file write_file_atomic ensure_dir flock_ex unlock log_line);

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
        modules => { renumber => 1, restore => 0, branding => 0 },
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
    };
}

# ----------------------------------------------------------- validação

sub _err { my ($e, $m) = @_; push @{$e}, $m; return }

sub _is_int { return defined $_[0] && !ref $_[0] && $_[0] =~ /^\d+$/ }

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
    my ($class, $data) = @_;
    my @e = $class->validate_structure($data);
    return @e if @e;    # chaves/tipos quebrados: nem tenta validar módulo

    # validação por módulo (assets em disco, consistência local). É estado
    # do node, não corrupção do config: só barra GRAVAÇÃO (save/_write_locked),
    # nunca a LEITURA (load usa validate_structure sozinho — ver load()).
    require MMPve::Core::Modules;
    for my $m (MMPve::Core::Modules->all) {
        my $name = $m->name;
        my @me = $m->validate_section($data);
        _err(\@e, "[$name] $_") for @me;
    }
    return @e;
}

sub validate_structure {
    my ($class, $data) = @_;
    my @e;
    return ('config não é um objeto') unless ref $data eq 'HASH';

    my %known = map { $_ => 1 } qw(revision modules vmid_scheme restore branding);
    for my $k (sort keys %{$data}) {
        _err(\@e, "chave desconhecida '$k'") unless $known{$k};
    }

    # revision
    if (exists $data->{revision}) {
        _err(\@e, 'revision precisa ser inteiro >= 1')
            unless _is_int($data->{revision}) && $data->{revision} >= 1;
    }

    # modules
    if (exists $data->{modules}) {
        my $m = $data->{modules};
        if (ref $m ne 'HASH') {
            _err(\@e, 'modules precisa ser objeto');
        } else {
            my %mk = map { $_ => 1 } qw(renumber restore branding);
            for my $k (sort keys %{$m}) {
                if (!$mk{$k}) { _err(\@e, "módulo desconhecido '$k'"); next }
                _err(\@e, "modules.$k precisa ser booleano") unless _is_bool($m->{$k});
            }
        }
    }

    # vmid_scheme
    if (exists $data->{vmid_scheme}) {
        my $s = $data->{vmid_scheme};
        if (ref $s ne 'ARRAY') {
            _err(\@e, 'vmid_scheme precisa ser lista');
        } else {
            my @ranges;
            my $i = 0;
            for my $r (@{$s}) {
                $i++;
                if (ref $r ne 'HASH') { _err(\@e, "vmid_scheme[$i] precisa ser objeto"); next }
                for my $k (sort keys %{$r}) {
                    _err(\@e, "vmid_scheme[$i]: chave desconhecida '$k'")
                        unless $k =~ /^(label|from|to)$/;
                }
                _err(\@e, "vmid_scheme[$i].label obrigatório (texto)")
                    unless defined $r->{label} && !ref $r->{label} && length $r->{label} <= 64;
                _err(\@e, "vmid_scheme[$i].from/to precisam ser inteiros 100..9999999")
                    unless _is_int($r->{from}) && _is_int($r->{to})
                    && $r->{from} >= 100 && $r->{to} <= 9999999;
                _err(\@e, "vmid_scheme[$i].from precisa ser < to")
                    if _is_int($r->{from}) && _is_int($r->{to}) && $r->{from} >= $r->{to};
                push @ranges, [$r->{from}, $r->{to}, $r->{label} // "faixa$i"];
            }
            # sobreposição
            my @sorted = sort { $a->[0] <=> $b->[0] } @ranges;
            for my $j (1 .. $#sorted) {
                if ($sorted[$j][0] <= $sorted[$j - 1][1]) {
                    _err(\@e,
                        "vmid_scheme: faixas sobrepostas '$sorted[$j-1][2]' e '$sorted[$j][2]'");
                }
            }
        }
    }

    # restore
    if (exists $data->{restore}) {
        my $r = $data->{restore};
        if (ref $r ne 'HASH') {
            _err(\@e, 'restore precisa ser objeto');
        } else {
            my %rk = map { $_ => 1 } qw(gateway_vmid vlans session_default_hours session_max_hours max_sessions);
            for my $k (sort keys %{$r}) {
                _err(\@e, "restore: chave desconhecida '$k'") unless $rk{$k};
            }
            if (defined $r->{gateway_vmid} && length($r->{gateway_vmid} // '')) {
                _err(\@e, 'restore.gateway_vmid precisa ser inteiro 100..9999999')
                    unless _is_int($r->{gateway_vmid}) && $r->{gateway_vmid} >= 100 && $r->{gateway_vmid} <= 9999999;
            }
            if (exists $r->{vlans}) {
                if (ref $r->{vlans} ne 'HASH') {
                    _err(\@e, 'restore.vlans precisa ser objeto');
                } else {
                    for my $vid (sort keys %{$r->{vlans}}) {
                        _err(\@e, "restore.vlans: VLAN '$vid' precisa ser 1..4094")
                            unless $vid =~ /^\d+$/ && $vid >= 1 && $vid <= 4094;
                        my $v = $r->{vlans}{$vid};
                        if (ref $v ne 'HASH') { _err(\@e, "restore.vlans.$vid precisa ser objeto"); next }
                        for my $k (sort keys %{$v}) {
                            _err(\@e, "restore.vlans.$vid: chave desconhecida '$k'")
                                unless $k =~ /^(gw_ip|prefix|note)$/;
                        }
                        _err(\@e, "restore.vlans.$vid.gw_ip IPv4 inválido") unless _is_ipv4($v->{gw_ip});
                        _err(\@e, "restore.vlans.$vid.prefix precisa ser 8..32")
                            unless _is_int($v->{prefix}) && $v->{prefix} >= 8 && $v->{prefix} <= 32;
                        if (defined $v->{note} && (!defined $v->{note} || ref $v->{note} || length($v->{note} // '') > 256)) {
                            _err(\@e, "restore.vlans.$vid.note precisa ser texto <= 256");
                        }
                    }
                    # gw_ip não pode se repetir
                    my %seen;
                    for my $vid (sort keys %{$r->{vlans}}) {
                        my $ip = $r->{vlans}{$vid}{gw_ip} // next;
                        _err(\@e, "restore.vlans: IP $ip repetido nas VLANs") if $seen{$ip}++;
                    }
                }
            }
            for my $f (qw(session_default_hours session_max_hours max_sessions)) {
                next unless exists $r->{$f};
                _err(\@e, "restore.$f precisa ser inteiro >= 1")
                    unless _is_int($r->{$f}) && $r->{$f} >= 1;
            }
            _err(\@e, 'restore.session_default_hours > session_max_hours')
                if _is_int($r->{session_default_hours}) && _is_int($r->{session_max_hours})
                    && $r->{session_default_hours} > $r->{session_max_hours};
            _err(\@e, 'restore.session_max_hours > 168 (7 dias)')
                if _is_int($r->{session_max_hours}) && $r->{session_max_hours} > 168;
            _err(\@e, 'restore.max_sessions > 100')
                if _is_int($r->{max_sessions}) && $r->{max_sessions} > 100;
        }
    }

    # branding
    if (exists $data->{branding}) {
        my $b = $data->{branding};
        if (ref $b ne 'HASH') {
            _err(\@e, 'branding precisa ser objeto');
        } else {
            my %bk = map { $_ => 1 } qw(title header_text logo favicon login_text assets_hash);
            for my $k (sort keys %{$b}) {
                _err(\@e, "branding: chave desconhecida '$k'") unless $bk{$k};
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
                _err(\@e, "branding.$f: nome de arquivo inválido (use [A-Za-z0-9._-])")
                    unless $v =~ /^[A-Za-z0-9._-]+$/ && $v !~ /^\./;
                _err(\@e, "branding.$f: só .png")
                    unless $v =~ /^[0-9a-f]{64}\.png$/;
            }
            if (defined $b->{assets_hash} && length $b->{assets_hash}) {
                _err(\@e, 'branding.assets_hash precisa ser sha256:<64 hex>')
                    unless $b->{assets_hash} =~ /^sha256:[0-9a-f]{64}$/;
            }
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
        return (undef, undef, $@ || "config ausente em $path");
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
    die "config.json inválido: $@\n" if $@;
    my @e = $class->validate_structure($data);
    die "config.json inválido:\n" . join("\n", @e) . "\n" if @e;
    return wantarray ? ($data, $digest, 0) : $data;
}

sub _write_locked {
    my ($class, $data, %opt) = @_;
    my $raw_prev = eval { read_file($class->config_path) };
    my $previous;
    if (defined $raw_prev) {
        my $cur = $class->digest_of($raw_prev);
        if (defined $opt{digest} && $opt{digest} ne $cur) {
            die "DIGEST_MISMATCH: config mudou desde a leitura (atual $cur). Releia e salve de novo.\n";
        }
        $previous = eval { decode_json($raw_prev) };
        die "config.json inválido durante a gravação: $@\n" if $@;
    } else {
        $previous = $class->default;
    }

    # O consumidor nunca escolhe a revisão. Ela vem do estado protegido pela
    # mesma trava da leitura e escrita.
    delete $data->{revision};

    my $def = $class->default;
    for my $k (qw(modules vmid_scheme restore branding)) {
        if (!exists $data->{$k}) {
            $data->{$k} = $def->{$k};
        } elsif (ref $def->{$k} eq 'HASH' && ref $data->{$k} eq 'HASH') {
            for my $kk (keys %{$def->{$k}}) {
                $data->{$k}{$kk} = $def->{$k}{$kk} unless exists $data->{$k}{$kk};
            }
        }
    }
    $data->{revision} = ($previous->{revision} // 0) + 1;

    my @e = $class->validate($data);
    die "config rejeitado:\n" . join("\n", @e) . "\n" if @e;

    my $json = JSON::PP->new->canonical->pretty->utf8->encode($data);
    die "config excede 1 MiB (limite do pmxcfs)\n" if length($json) > MAX_BYTES;
    write_file_atomic($class->config_path, $json . "\n", 0644);
    log_line("config salvo revision $data->{revision}");
    return ($data, $class->digest_of($json . "\n"));
}

sub _with_domain_lock {
    my ($class, $domain, $code) = @_;
    die "domínio de lock inválido\n"
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
    die 'with_domain_lock precisa de callback' unless ref $code eq 'CODE';
    return $class->_with_domain_lock($domain, $code);
}

sub _with_write_lock {
    my ($class, $code) = @_;
    return $class->_with_domain_lock('mm-tools', $code);
}

sub save {
    my ($class, $data, %opt) = @_;
    die 'save precisa de hashref' unless ref $data eq 'HASH';
    # cfs_lock_domain propagates scalar returns only. Keep the data/digest
    # pair in one reference so callers have the same contract on PVE and tests.
    my $saved = $class->_with_write_lock(sub {
        return [ $class->_write_locked($data, %opt) ];
    });
    return wantarray ? @{$saved} : $saved->[0];
}

sub save_section {
    my ($class, $section, $value, %opt) = @_;
    my %allowed = map { $_ => 1 } qw(modules vmid_scheme restore branding);
    die "seção inválida '$section'\n" unless $allowed{$section};
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
            die "config.json inválido durante a gravação: $@\n" if $@;
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
