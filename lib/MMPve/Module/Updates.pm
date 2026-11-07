package MMPve::Module::Updates;

# Atualização segura de um node PVE. O estado compartilhado fica no pmxcfs;
# o trabalho pesado é sempre executado por uma unit transitória do systemd.

use strict;
use warnings;
use base qw(MMPve::Core::ModuleBase);

use Fcntl qw(:flock);
use JSON::PP qw(decode_json encode_json);
use POSIX qw(strftime);
use Time::HiRes ();
use Sys::Hostname qw(hostname);

use MMPve::Core::Apply;
use MMPve::Core::Config;
use MMPve::Core::Runner;
use MMPve::Core::Util qw(root_path read_file write_file_atomic ensure_dir random_uuid log_line);

our $VERSION = '@MM_PVE_VERSION@';

use constant {
    DEFAULT_JOB_TIMEOUT => 3600,
    DEFAULT_LOCK_TIMEOUT => 300,
    DEFAULT_RETENTION => 10,
    MAX_LOG_LIMIT => 1000,
};

sub name { 'updates' }
sub state_dir { MMPve::Core::Config->config_dir . '/updates' }
sub log_dir { root_path('/var/log/mm-pve-tools/updates') }

sub validate_section {
    my ($class, $cfg) = @_;
    return () unless ref($cfg) eq 'HASH' && exists $cfg->{updates};
    my $u = $cfg->{updates};
    return ('updates precisa ser objeto') unless ref($u) eq 'HASH';
    my %known = map { $_ => 1 } qw(job_timeout dpkg_lock_timeout retention);
    my @errors;
    for my $k (sort keys %{$u}) {
        push @errors, "updates: chave desconhecida '$k'" unless $known{$k};
        next unless $known{$k};
        push @errors, "updates.$k precisa ser inteiro >= 1"
            unless defined($u->{$k}) && !ref($u->{$k}) && $u->{$k} =~ /^\d+$/ && $u->{$k} >= 1;
    }
    return @errors;
}

sub apply { return { ok => 1, changed => 0, message => 'updates pronto (sem patch local)' } }
sub revert { return { ok => 1, changed => 0, message => 'updates revertido (sem patch local)' } }
sub check {
    my ($class, $cfg) = @_;
    return { ok => 1, enabled => (($cfg->{modules} || {})->{updates} ? 1 : 0),
        active_job => $class->active_job ? 1 : 0, state_dir => state_dir() };
}

sub _now { strftime('%Y-%m-%dT%H:%M:%S%z', localtime) }
sub _safe_node {
    my ($node) = @_;
    my ($safe) = defined($node) && !ref($node)
        ? ($node =~ /\A([A-Za-z0-9][A-Za-z0-9_.-]{0,63})\z/) : ();
    die "node inválido\n" unless defined $safe;
    return $safe;
}
sub _safe_job {
    my ($job) = @_;
    my ($safe) = defined($job) && !ref($job)
        ? ($job =~ /\A([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\z/) : ();
    die "id de job inválido\n" unless defined $safe;
    return $safe;
}
sub _safe_actor {
    my ($actor) = @_;
    $actor = 'root@pam' unless defined($actor) && !ref($actor) && length($actor);
    $actor =~ s/![^!\x00-\x1f\x7f]*\z//;
    my ($safe) = $actor =~ /\A([A-Za-z0-9._-]{1,64}\@[A-Za-z0-9._-]{1,64})\z/;
    die "principal inválido\n" unless defined $safe;
    return $safe;
}
sub _safe_path {
    my ($path) = @_;
    my ($safe) = defined($path) && !ref($path)
        ? ($path =~ /\A(\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*)\z/) : ();
    die "caminho interno inválido\n" unless defined $safe;
    return $safe;
}
sub _unit_name { 'mm-pve-update-' . _safe_job($_[0]) }
sub _current_path { state_dir() . '/' . _safe_node($_[0]) . '.json' }
sub _history_path { state_dir() . '/' . _safe_node($_[0]) . '-' . _safe_job($_[1]) . '.json' }

sub _read_json {
    my ($path) = @_;
    return undef unless -e $path;
    my $raw = read_file($path);
    my $data = eval { decode_json($raw) };
    die "estado de updates inválido: $path: $@\n" if $@ || ref($data) ne 'HASH';
    return $data;
}
sub _write_json {
    my ($path, $data) = @_;
    ensure_dir(state_dir());
    write_file_atomic($path, JSON::PP->new->canonical->pretty->utf8->encode($data) . "\n", 0644);
}
sub _bulk_for_node {
    my ($node) = @_;
    my @bulk;
    return undef unless opendir(my $dh, state_dir());
    while (my $entry = readdir($dh)) {
        next unless $entry =~ /\Abulk-([0-9a-f-]+)\.json\z/;
        my $item = eval { _read_json(state_dir() . '/' . $entry) };
        push @bulk, $item if $item && grep { $_ eq $node } @{ $item->{nodes} || [] };
    }
    closedir($dh);
    @bulk = sort { ($b->{heartbeat_epoch} // 0) <=> ($a->{heartbeat_epoch} // 0) } @bulk;
    my $latest = $bulk[0] or return undef;
    $latest->{orchestrator_lost} = (($latest->{state} // '') =~ /^(?:queued|running)$/
        && time - ($latest->{heartbeat_epoch} // 0) > 120) ? 1 : 0;
    return $latest;
}
sub _with_node_lock {
    my ($node, $code) = @_;
    return MMPve::Core::Config->with_domain_lock('updates-' . _safe_node($node), $code);
}
sub _sanitize_log {
    my ($line) = @_;
    $line //= '';
    $line =~ s{([A-Za-z][A-Za-z0-9+.-]*://)([^\s/\x40:]+):([^\s/\x40]+)\x40}{$1***:***\x40}g;
    $line =~ s{(?i)(password|token|secret|api[_-]?key)=([^\s&]+)}{$1=***}g;
    return $line;
}
sub _append_log {
    my ($path, $text) = @_;
    $path = _safe_path($path);
    ensure_dir(log_dir());
    open(my $fh, '>>', $path) or die "não consegui abrir log do job: $!\n";
    for my $line (split /\n/, $text // '', -1) {
        print {$fh} _sanitize_log($line) . "\n";
    }
    close($fh) or die "não consegui fechar log do job: $!\n";
}
sub _unit_active {
    my ($unit) = @_;
    return 0 unless defined($unit) && $unit =~ /\Amm-pve-update-[0-9a-f-]+\z/;
    my $r = MMPve::Core::Runner->run(['systemctl', 'is-active', '--quiet', $unit], timeout => 15);
    return $r->{ok} ? 1 : 0;
}

sub _reconcile_locked {
    my ($node, $state) = @_;
    return $state unless $state && ($state->{state} eq 'queued' || $state->{state} eq 'running');
    return $state if $state->{launching} && ($state->{launch_deadline} // 0) > time;
    return $state if _unit_active($state->{unit});
    $state->{state} = 'lost';
    $state->{finished} = _now();
    $state->{error} = 'unit transitória inativa sem estado final';
    delete $state->{launching};
    _write_json(_current_path($node), $state);
    _write_json(_history_path($node, $state->{id}), $state);
    return $state;
}

sub active_job {
    my ($class, $node) = @_;
    $node //= hostname();
    $node = eval { _safe_node($node) } or return undef;
    my $state = eval {
        _with_node_lock($node, sub {
            my $current = _read_json(_current_path($node));
            return _reconcile_locked($node, $current);
        });
    } or return undef;
    return undef unless $state && ($state->{state} eq 'queued' || $state->{state} eq 'running');
    return $state;
}

sub dpkg_locked {
    my ($class) = @_;
    for my $name (qw(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock)) {
        my $path = root_path($name);
        my $fh;
        next unless open($fh, '+<', $path) || open($fh, '<', $path);
        my $busy = !flock($fh, LOCK_EX | LOCK_NB);
        flock($fh, LOCK_UN) unless $busy;
        close($fh);
        return 1 if $busy;
    }
    return 0;
}

sub _kernel_state {
    my $uname = MMPve::Core::Runner->run(['uname', '-r'], timeout => 15);
    my $running = $uname->{ok} ? $uname->{out} : '';
    $running =~ s/^\s+|\s+$//g;
    my $q = MMPve::Core::Runner->run(
        ['dpkg-query', '-W', '-f=${Status}\t${Package}\t${Version}\n'], timeout => 30);
    my @installed;
    if ($q->{ok}) {
        for my $line (split /\n/, $q->{out} // '') {
            my ($status, $package, $version) = split /\t/, $line, 3;
            next unless defined($status) && $status eq 'install ok installed';
            next unless defined($package)
                && $package =~ /\A(?:pve|proxmox)-kernel-(.+?-pve)(?:-signed)?\z/;
            my $release = $1;
            push @installed, { package => $package, version => $version // '', release => $release };
        }
    }
    my $newest;
    for my $item (@installed) {
        if (!$newest) { $newest = $item; next }
        my $cmp = MMPve::Core::Runner->run(
            ['dpkg', '--compare-versions', $item->{version}, 'gt', $newest->{version}], timeout => 15);
        if ($cmp->{rc} == 0) {
            $newest = $item;
        } elsif ($cmp->{rc} != 1 && $item->{version} gt $newest->{version}) {
            # Fallback only when dpkg is unavailable in a reduced test/lab
            # image; production Debian always has dpkg --compare-versions.
            $newest = $item;
        }
    }
    return {
        running => $running,
        installed => \@installed,
        newest_installed => $newest,
        reboot_suggested => ($newest && defined($running) && $newest->{release} ne $running) ? 1 : 0,
    };
}

sub _default_pending {
    my ($node) = @_;
    return MMPve::Core::Runner->pvesh(get => "/nodes/$_[0]/apt/update");
}

sub status {
    my ($class, $node, %opts) = @_;
    $node = _safe_node($node // hostname());
    my $state = _read_json(_current_path($node));
    if ($state) {
        $state = _with_node_lock($node, sub {
            my $fresh = _read_json(_current_path($node));
            return _reconcile_locked($node, $fresh);
        });
    }
    my $pending;
    my $pending_error;
    my $cb = $opts{pending_cb} || sub { _default_pending($node) };
    eval { $pending = $cb->($node); 1 } or $pending_error = $@;
    $pending = [] unless ref($pending) eq 'ARRAY';
    my $kernel = _kernel_state();
    my @history;
    if (opendir(my $dh, state_dir())) {
        while (my $entry = readdir($dh)) {
            next unless $entry =~ /\A\Q$node\E-([0-9a-f-]+)\.json\z/;
            my $item = eval { _read_json(state_dir() . '/' . $entry) };
            push @history, $item if $item && $item->{id};
        }
        closedir($dh);
    }
    @history = sort { ($b->{finished} // $b->{created} // '') cmp ($a->{finished} // $a->{created} // '') } @history;
    my $cfg = eval { MMPve::Core::Config->load } || MMPve::Core::Config->default;
    my $u = $cfg->{updates} || {};
    splice @history, $u->{retention} // DEFAULT_RETENTION if @history > ($u->{retention} // DEFAULT_RETENTION);
    return {
        node => $node,
        online => exists($opts{online}) ? ($opts{online} ? 1 : 0) : 1,
        pending => $pending,
        pending_error => $pending_error,
        kernel => $kernel,
        reboot_suggested => $kernel->{reboot_suggested} ? 1 : 0,
        job => $state,
        results => \@history,
        bulk => _bulk_for_node($node),
        dpkg_locked => $class->dpkg_locked ? 1 : 0,
    };
}

sub _reserve {
    my ($class, $node, $actor, %opts) = @_;
    $node = _safe_node($node);
    $actor = _safe_actor($actor);
    return _with_node_lock($node, sub {
        my $current = _read_json(_current_path($node));
        if ($current && ($current->{state} eq 'queued' || $current->{state} eq 'running')) {
            $current = _reconcile_locked($node, $current);
            die "já existe job ativo no node $node ($current->{id})\n"
                if $current->{state} eq 'queued' || $current->{state} eq 'running';
        }
        my $id = random_uuid();
        my $state = {
            id => $id, node => $node, requested_by => $actor,
            state => 'queued', created => _now(), created_epoch => Time::HiRes::time(),
            unit => _unit_name($id),
            launching => 1, launch_deadline => time + 60,
            log => log_dir() . '/' . $id . '.log',
        };
        _write_json(_current_path($node), $state);
        return $state;
    });
}

sub _finish {
    my ($class, $node, $id, $state, $result) = @_;
    _with_node_lock($node, sub {
        my $current = _read_json(_current_path($node));
        return unless $current && $current->{id} eq $id;
        delete $state->{launching};
        $state->{state} = $result->{ok} ? 'succeeded' : 'failed';
        $state->{finished} = _now();
        $state->{finished_epoch} = Time::HiRes::time();
        $state->{result} = $result;
        $state->{error} = $result->{error} if !$result->{ok};
        _write_json(_current_path($node), $state);
        _write_json(_history_path($node, $id), $state);
        my $cfg = eval { MMPve::Core::Config->load } || MMPve::Core::Config->default;
        my $keep = $cfg->{updates}{retention} // DEFAULT_RETENTION;
        my @files;
        if (opendir(my $dh, state_dir())) {
            @files = grep { /^\Q$node\E-[0-9a-f-]+\.json\z/ } readdir($dh);
            closedir($dh);
        }
        # Mais novo primeiro pelo epoch de alta resolução gravado no job (o
        # mtime em segundos empata quando dois jobs terminam no mesmo
        # segundo); o job que acabou de terminar nunca é podado.
        my %epoch = map {
            my $data = eval { _read_json(state_dir() . '/' . $_) } || {};
            ($_ => $data->{finished_epoch} // $data->{created_epoch} // 0)
        } @files;
        my $mine = "$node-$id.json";
        @files = sort { ($b eq $mine) <=> ($a eq $mine) || $epoch{$b} <=> $epoch{$a} || $b cmp $a } @files;
        if (@files > $keep) {
            for my $file (@files[$keep .. $#files]) {
                my $old = eval { _read_json(state_dir() . '/' . $file) } || {};
                unlink(state_dir() . '/' . $file);
                if ($old->{log} && eval { _safe_path($old->{log}); 1 }) {
                    unlink($old->{log});
                }
            }
        }
    });
}

sub _prune_bulk {
    my ($keep) = @_;
    $keep = DEFAULT_RETENTION unless defined($keep) && $keep =~ /^\d+$/ && $keep >= 1;
    my @files;
    return unless opendir(my $dh, state_dir());
    @files = grep { /\Abulk-[0-9a-f-]+\.json\z/ } readdir($dh);
    closedir($dh);
    my %epoch = map {
        my $data = eval { _read_json(state_dir() . '/' . $_) } || {};
        ($_ => $data->{created_epoch} // 0)
    } @files;
    @files = sort { $epoch{$b} <=> $epoch{$a} || $b cmp $a } @files;
    if (@files > $keep) {
        unlink(state_dir() . '/' . $_) for @files[$keep .. $#files];
    }
}

sub _launch {
    my ($class, $state, %opts) = @_;
    my $node = _safe_node($state->{node});
    my $id = _safe_job($state->{id});
    my $bin = $ENV{MM_PVE_BIN} || '/usr/sbin/mm-pve';
    _safe_path($bin);
    my $config = _safe_path(MMPve::Core::Config->config_dir);
    my @env = ('env', '-i', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin',
        'DEBIAN_FRONTEND=noninteractive', "MM_PVE_CONFIG_DIR=$config");
    push @env, 'MM_PVE_ROOT=' . _safe_path($ENV{MM_PVE_ROOT}) if $ENV{MM_PVE_ROOT};
    push @env, $bin, 'updates', 'worker', '--node', $node, '--job', $id;
    my @cmd = ('systemd-run', '--no-block', '--collect', '--service-type=oneshot',
        '--unit=' . $state->{unit}, @env);
    my $res = MMPve::Core::Runner->run(\@cmd, timeout => 30);
    if (!$res->{ok}) {
        $class->_finish($node, $id, $state, { ok => 0, error => 'systemd-run falhou: ' . ($res->{err} || $res->{error} || "rc=$res->{rc}") });
        die "não consegui iniciar a unit do job $id: " . ($res->{err} || $res->{error} || "rc=$res->{rc}") . "\n";
    }
    _with_node_lock($node, sub {
        my $fresh = _read_json(_current_path($node));
        if ($fresh && $fresh->{id} eq $id) {
            _write_json(_current_path($node), $fresh);
        }
    });
    return $id;
}

sub request_run {
    my ($class, $node, %opts) = @_;
    $node = _safe_node($node // hostname());
    my $state = $class->_reserve($node, $opts{actor}, mode => 'single');
    return $class->_launch($state);
}

sub run_job {
    my ($class, $node, $id) = @_;
    $node = _safe_node($node); $id = _safe_job($id);
    my $state = _with_node_lock($node, sub {
        my $s = _read_json(_current_path($node));
        die "job não encontrado\n" unless $s && $s->{id} eq $id;
        die "job não está na fila\n" unless $s->{state} eq 'queued';
        $s->{state} = 'running'; $s->{started} = _now(); delete $s->{launching};
        _write_json(_current_path($node), $s);
        return $s;
    });
    _append_log($state->{log}, "job $id iniciado; solicitado por $state->{requested_by}\n");
    my $cfg = eval { MMPve::Core::Config->load } || MMPve::Core::Config->default;
    my $timeout = $cfg->{updates}{job_timeout} // DEFAULT_JOB_TIMEOUT;
    my $lock_timeout = $cfg->{updates}{dpkg_lock_timeout} // DEFAULT_LOCK_TIMEOUT;
    my $run = sub {
        my ($run_timeout, @args) = @_;
        _append_log($state->{log}, join(' ', @args));
        my %run_opts = (on_output => sub { _append_log($state->{log}, $_[0]) });
        $run_opts{timeout} = $run_timeout if defined $run_timeout;
        my $res = MMPve::Core::Runner->run_stream(\@args, %run_opts);
        return $res;
    };
    my $result = { ok => 0 };
    my $update = $run->($timeout, 'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'update',
        '-o', "DPkg::Lock::Timeout=$lock_timeout");
    if (!$update->{ok}) {
        $result->{error} = 'apt-get update falhou';
    } else {
        my $upgrade = $run->(undef, 'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', '-y', 'dist-upgrade',
            '-o', 'Dpkg::Options::=--force-confdef', '-o', 'Dpkg::Options::=--force-confold',
            '-o', "DPkg::Lock::Timeout=$lock_timeout");
        if (!$upgrade->{ok}) {
            $result->{error} = 'apt-get dist-upgrade falhou';
        } else {
            my $apply = eval {
                MMPve::Core::Apply->apply_all(
                    patches => (-d root_path('/usr/share/pve-manager') ? 1 : 0),
                    allow_updates => 1,
                )
            };
            if ($@ || !$apply || !$apply->{ok}) {
                $result->{error} = 'apply/reload pós-update falhou: ' . ($@ || $apply->{reason} || 'resultado inválido');
            } else {
                $result = { ok => 1, apply => $apply };
            }
        }
    }
    _append_log($state->{log}, $result->{ok} ? "job concluído com sucesso\n" : "job falhou: $result->{error}\n");
    $class->_finish($node, $id, $state, $result);
    return $result;
}

sub refresh {
    my ($class, $node) = @_;
    $node = _safe_node($node // hostname());
    my $res = MMPve::Core::Runner->run(['env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'update'], timeout => 900);
    die "apt-get update falhou: " . ($res->{err} || "rc=$res->{rc}") . "\n" unless $res->{ok};
    return { ok => 1, node => $node };
}

sub _cluster_preflight {
    my ($nodes) = @_;
    my $cluster = MMPve::Core::Runner->pvesh(get => '/cluster/status');
    die "preflight: cluster sem quorum\n" if ref($cluster) eq 'ARRAY'
        && grep { ref($_) eq 'HASH' && exists($_->{quorate}) && !$_->{quorate} } @{$cluster};
    my %online = map { ($_->{name} // $_->{node} => $_->{online}) }
        grep { ref($_) eq 'HASH' && ($_->{type} // '') eq 'node' } (ref($cluster) eq 'ARRAY' ? @{$cluster} : ());
    for my $node (@{$nodes}) {
        die "preflight: node $node desconhecido\n" unless exists $online{$node};
        die "preflight: node $node offline\n" unless $online{$node};
    }
    my $ha = eval { MMPve::Core::Runner->pvesh(get => '/cluster/ha/status/current') };
    if (ref($ha) eq 'ARRAY') {
        for my $item (@{$ha}) {
            my $text = encode_json($item);
            die "preflight: HA com erro ou migração\n" if $text =~ /(?:error|migrat)/i;
        }
    }
    my $ceph = eval { MMPve::Core::Runner->pvesh(get => '/cluster/ceph/status') };
    if ($ceph && ref($ceph) eq 'HASH') {
        my $health = ref($ceph->{health}) eq 'HASH' ? $ceph->{health}{status} : $ceph->{health};
        die "preflight: Ceph não está HEALTH_OK\n" if defined($health) && $health ne 'HEALTH_OK';
    }
    return { ok => 1, quorum => 1, nodes => \@{$nodes}, ha => 'ok', ceph => $ceph ? 'ok' : 'absent' };
}

sub run_bulk {
    my ($class, $nodes, %opts) = @_;
    die "nodes precisa ser lista\n" unless ref($nodes) eq 'ARRAY' && @{$nodes};
    my %seen; my @authorized = map { _safe_node($_) } @{$nodes};
    @authorized = grep { !$seen{$_}++ } @authorized;
    my $mode = $opts{mode} // 'sequential';
    die "mode precisa ser sequential ou parallel\n" unless $mode eq 'sequential' || $mode eq 'parallel';
    my $preflight = $opts{preflight_cb} || sub { _cluster_preflight($_[0]) };
    my ($pf, $preflight_error);
    eval { $pf = $preflight->(\@authorized); 1 } or $preflight_error = $@;
    if ($preflight_error) {
        die $preflight_error unless $opts{override};
        $pf = { ok => 0, error => $preflight_error };
    }
    die "preflight bloqueou o bulk\n" unless $opts{override} || ($pf && $pf->{ok});
    my $id = random_uuid();
    ensure_dir(state_dir());
    my $state = { id => $id, state => 'queued', requested_by => _safe_actor($opts{actor}),
        mode => $mode, nodes => \@authorized, override => $opts{override} ? 1 : 0,
        preflight => $pf, created => _now(), created_epoch => Time::HiRes::time(),
        heartbeat => _now(), heartbeat_epoch => time, results => {} };
    _write_json(state_dir() . '/bulk-' . $id . '.json', $state);
    my $cfg = eval { MMPve::Core::Config->load } || MMPve::Core::Config->default;
    _prune_bulk($cfg->{updates}{retention} // DEFAULT_RETENTION);
    my $bin = _safe_path($ENV{MM_PVE_BIN} || '/usr/sbin/mm-pve');
    my @cmd = ('systemd-run', '--no-block', '--collect', '--service-type=oneshot',
        '--unit=mm-pve-bulk-' . $id, 'env', '-i',
        'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'DEBIAN_FRONTEND=noninteractive',
        'MM_PVE_CONFIG_DIR=' . _safe_path(MMPve::Core::Config->config_dir),
        $bin, 'updates', 'bulk-worker', '--bulk', $id);
    my $res = MMPve::Core::Runner->run(\@cmd, timeout => 30);
    die "não consegui iniciar o orquestrador\n" unless $res->{ok};
    return { bulk_id => $id, nodes => \@authorized, mode => $mode, preflight => $pf };
}

sub bulk_worker {
    my ($class, $id) = @_;
    $id = _safe_job($id);
    my $path = state_dir() . '/bulk-' . $id . '.json';
    my $bulk = _read_json($path) or die "bulk não encontrado\n";
    $bulk->{state} = 'running';
    _write_json($path, $bulk);
    my @nodes = @{ $bulk->{nodes} || [] };
    my @started;
    for my $node (@nodes) {
        if ($bulk->{mode} eq 'sequential' && !$bulk->{override}) {
            my ($pf, $error);
            eval { $pf = _cluster_preflight([$node]); 1 } or $error = $@;
            if ($error || !$pf || !$pf->{ok}) {
                $bulk->{state} = 'failed';
                $bulk->{error} = $error || $pf->{error} || "preflight bloqueou antes do node $node";
                $bulk->{finished} = _now();
                _write_json($path, $bulk);
                die $bulk->{error};
            }
        }
        $bulk->{heartbeat} = _now(); $bulk->{heartbeat_epoch} = time;
        $bulk->{current_node} = $node; _write_json($path, $bulk);
        my $result = eval {
            if ($node eq hostname()) {
                my $job = $class->request_run($node, actor => $bulk->{requested_by});
                return { ok => 1, job => $job };
            }
            my $upid = MMPve::Core::Runner->pvesh_task('create', "/nodes/$node/mm-tools/updates/run",
                requested_by => $bulk->{requested_by});
            return { ok => 1, upid => $upid };
        };
        $result = { ok => 0, error => $@ } if $@;
        $bulk->{results}{$node} = $result;
        _write_json($path, $bulk);
        if (!$result->{ok}) {
            $bulk->{state} = 'failed'; $bulk->{finished} = _now(); _write_json($path, $bulk);
            die "bulk parou no primeiro erro em $node\n" if $bulk->{mode} eq 'sequential';
        }
        push @started, $node if $result->{ok};
        if ($bulk->{mode} eq 'sequential') {
            my $done = $class->_wait_for_node($node, bulk_path => $path);
            $bulk->{results}{$node}{result} = $done;
            _write_json($path, $bulk);
            if (!$done->{ok}) {
                $bulk->{state} = 'failed'; $bulk->{finished} = _now(); _write_json($path, $bulk);
                die "bulk parou no primeiro erro em $node\n";
            }
        }
    }
    if ($bulk->{mode} eq 'parallel') {
        for my $node (@started) {
            my $done = $class->_wait_for_node($node, bulk_path => $path);
            $bulk->{results}{$node}{result} = $done;
            _write_json($path, $bulk);
            $bulk->{state} = 'failed' if !$done->{ok};
        }
    }
    $bulk->{state} = 'failed' if grep { !($bulk->{results}{$_}{result}{ok} // $bulk->{results}{$_}{ok}) } @started;
    $bulk->{state} = 'succeeded' if $bulk->{state} ne 'failed';
    $bulk->{finished} = _now(); delete $bulk->{current_node};
    _write_json($path, $bulk);
    my $cfg = eval { MMPve::Core::Config->load } || MMPve::Core::Config->default;
    _prune_bulk($cfg->{updates}{retention} // DEFAULT_RETENTION);
    return $bulk;
}

sub _wait_for_node {
    my ($class, $node, %opts) = @_;
    my $started = time;
    my $cfg = eval { MMPve::Core::Config->load } || MMPve::Core::Config->default;
    my $timeout = $opts{timeout} // $cfg->{updates}{job_timeout} // DEFAULT_JOB_TIMEOUT;
    my $heartbeat_interval = defined($opts{heartbeat_interval}) ? $opts{heartbeat_interval} : 30;
    my $last_heartbeat = time;
    while (time - $started <= $timeout) {
        if ($opts{bulk_path} && time - $last_heartbeat >= $heartbeat_interval) {
            my $bulk = eval { _read_json($opts{bulk_path}) };
            if ($bulk && ($bulk->{state} // '') =~ /^(?:queued|running)$/) {
                $bulk->{heartbeat} = _now();
                $bulk->{heartbeat_epoch} = time;
                _write_json($opts{bulk_path}, $bulk);
            }
            $last_heartbeat = time;
        }
        my $state;
        if ($node eq hostname()) {
            $state = eval { _read_json(_current_path($node)) };
        } else {
            $state = eval { MMPve::Core::Runner->pvesh(get => "/nodes/$node/mm-tools/updates/status") };
            $state = $state->{job} if ref($state) eq 'HASH' && exists $state->{job};
        }
        if (ref($state) eq 'HASH' && ($state->{state} // '') =~ /^(?:succeeded|failed|lost)$/) {
            return { ok => $state->{state} eq 'succeeded' ? 1 : 0, state => $state->{state}, error => $state->{error} };
        }
        select(undef, undef, undef, 1);
    }
    return { ok => 0, state => 'timed_out', error => 'timeout esperando job do node' };
}

sub reboot_context {
    my ($class, $node) = @_;
    $node = _safe_node($node);
    my $out = { running_guests => [], ha => {} };
    my $resources = eval { MMPve::Core::Runner->pvesh(get => '/cluster/resources') };
    if (ref($resources) eq 'ARRAY') {
        for my $item (@{$resources}) {
            next unless ref($item) eq 'HASH' && ($item->{node} // '') eq $node;
            next unless ($item->{type} // '') =~ /^(?:qemu|lxc)$/;
            next unless ($item->{status} // '') eq 'running';
            push @{$out->{running_guests}}, {
                vmid => 0 + ($item->{vmid} // 0), type => $item->{type},
                name => $item->{name} // $item->{vmid},
            };
        }
    }
    my $ha = eval { MMPve::Core::Runner->pvesh(get => '/cluster/ha/status/current') };
    if (ref($ha) eq 'HASH') {
        $out->{ha} = $ha->{node_status}{$node} if ref($ha->{node_status}) eq 'HASH'
            && $ha->{node_status}{$node};
        $out->{ha} = $ha unless keys %{$out->{ha}};
    }
    return $out;
}

sub reboot_preflight {
    my ($class, $node, %opts) = @_;
    $node = _safe_node($node);
    die "confirmação inválida: digite o nome do node\n" unless defined($opts{confirm}) && $opts{confirm} eq $node;
    my $s = $class->status($node, pending_cb => ($opts{pending_cb} || sub { _default_pending($_[0]) }),
        online => exists($opts{online}) ? $opts{online} : 1);
    die "node $node está offline\n" unless $s->{online};
    die "há job de update ativo no node $node\n" if $s->{job} && ($s->{job}{state} eq 'queued' || $s->{job}{state} eq 'running');
    die "não há kernel novo pendente\n" unless $s->{kernel}{reboot_suggested};
    return { node => $node, running_guests => $opts{running_guests} || [], ha => $opts{ha} || {} };
}

sub reboot {
    my ($class, $node, %opts) = @_;
    my $ctx = $class->reboot_context($node);
    $opts{running_guests} //= $ctx->{running_guests};
    $opts{ha} //= $ctx->{ha};
    my $context = $class->reboot_preflight($node, %opts);
    MMPve::Core::Runner->pvesh('create', "/nodes/" . _safe_node($node) . '/status', command => 'reboot');
    return $context;
}

sub log_page {
    my ($class, $node, $id, %opts) = @_;
    $node = _safe_node($node); $id = _safe_job($id);
    my $state = _read_json(_history_path($node, $id)) || _read_json(_current_path($node));
    die "job não pertence ao node\n" unless $state && $state->{id} eq $id && $state->{node} eq $node;
    my $start = defined($opts{start}) && $opts{start} =~ /^\d+$/ ? 0 + $opts{start} : 0;
    my $limit = defined($opts{limit}) && $opts{limit} =~ /^\d+$/ ? 0 + $opts{limit} : 100;
    die "limite de log inválido\n" if $limit < 1 || $limit > MAX_LOG_LIMIT;
    my @lines;
    my $log_path = _safe_path($state->{log});
    if (open(my $fh, '<', $log_path)) { @lines = <$fh>; close($fh) }
    chomp @lines;
    return { node => $node, job => $id, start => $start, limit => $limit,
        total => scalar(@lines), lines => [ @lines[$start .. (($start + $limit - 1 < $#lines) ? $start + $limit - 1 : $#lines)] ] } if @lines && $start <= $#lines;
    return { node => $node, job => $id, start => $start, limit => $limit, total => scalar(@lines), lines => [] };
}

sub cli {
    my ($class, $argv) = @_;
    require Getopt::Long;
    my $sub = shift @{$argv} // '';
    my ($node, $nodes, $mode, $job, $bulk, $confirm, $start, $limit, $override);
    local @ARGV = @{$argv};
    Getopt::Long::GetOptions(
        'node=s' => \$node, 'nodes=s' => \$nodes, 'mode=s' => \$mode,
        'job=s' => \$job, 'bulk=s' => \$bulk, 'confirm=s' => \$confirm, 'start=i' => \$start,
        'limit=i' => \$limit, 'override-preflight' => \$override,
    ) or return 2;
    $node //= hostname();
    my $out;
    if ($sub eq 'status') { $out = $class->status($node) }
    elsif ($sub eq 'refresh') { $out = $class->refresh($node) }
    elsif ($sub eq 'run') {
        if (defined $nodes) { $out = $class->run_bulk([split /,/, $nodes], mode => $mode, actor => 'root@pam', override => $override) }
        else { $out = { job => $class->request_run($node, actor => 'root@pam') } }
    }
    elsif ($sub eq 'worker') { return $class->run_job($node, $job)->{ok} ? 0 : 1 }
    elsif ($sub eq 'bulk-worker') { return $class->bulk_worker($bulk // $job)->{state} eq 'succeeded' ? 0 : 1 }
    elsif ($sub eq 'log') { $out = $class->log_page($node, $job, start => $start, limit => $limit) }
    elsif ($sub eq 'reboot') { $out = $class->reboot($node, confirm => $confirm) }
    else { print STDERR "uso: mm-pve updates status|refresh|run|log|reboot\n"; return 2 }
    print JSON::PP->new->canonical->pretty->utf8->encode($out), "\n";
    return 0;
}

1;
