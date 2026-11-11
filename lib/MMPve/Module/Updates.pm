package MMPve::Module::Updates;

# Atualização segura de um node PVE. O estado compartilhado fica no pmxcfs;
# o trabalho pesado é sempre executado por uma unit transitória do systemd.

use strict;
use warnings;
use base qw(MMPve::Core::ModuleBase);

use Fcntl qw(:flock);
use JSON::PP qw(decode_json);
use POSIX qw(strftime);
use Time::HiRes ();
use Sys::Hostname qw(hostname);

use MMPve::Core::Apply;
use MMPve::Core::Config;
use MMPve::Core::Runner;
use MMPve::Core::Util qw(root_path read_file write_file_atomic ensure_dir random_uuid log_line json_encode utf8_bytes);

our $VERSION = '@MM_PVE_VERSION@';

use constant {
    DEFAULT_JOB_TIMEOUT => 3600,
    DEFAULT_LOCK_TIMEOUT => 300,
    DEFAULT_RETENTION => 10,
    MAX_LOG_LIMIT => 1000,
    BULK_HEARTBEAT_TIMEOUT => 120,
};

sub name { 'updates' }
sub state_dir { MMPve::Core::Config->config_dir . '/updates' }
sub log_dir { root_path('/var/log/mm-pve-tools/updates') }

sub validate_section {
    my ($class, $cfg) = @_;
    return () unless ref($cfg) eq 'HASH' && exists $cfg->{updates};
    my $u = $cfg->{updates};
    return ('updates must be an object') unless ref($u) eq 'HASH';
    my %known = map { $_ => 1 } qw(job_timeout dpkg_lock_timeout retention);
    my @errors;
    for my $k (sort keys %{$u}) {
        push @errors, "updates: unknown key '$k'" unless $known{$k};
        next unless $known{$k};
        push @errors, "updates.$k must be an integer >= 1"
            unless defined($u->{$k}) && !ref($u->{$k}) && $u->{$k} =~ /^\d+$/ && $u->{$k} >= 1;
    }
    return @errors;
}

sub apply { return { ok => 1, changed => 0, message => 'updates ready (no local patch)' } }
sub revert { return { ok => 1, changed => 0, message => 'updates reverted (no local patch)' } }
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
    die "invalid node\n" unless defined $safe;
    return $safe;
}
sub _safe_job {
    my ($job) = @_;
    my ($safe) = defined($job) && !ref($job)
        ? ($job =~ /\A([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\z/) : ();
    die "invalid job id\n" unless defined $safe;
    return $safe;
}
sub _safe_actor {
    my ($actor) = @_;
    $actor = 'root@pam' unless defined($actor) && !ref($actor) && length($actor);
    $actor =~ s/![^!\x00-\x1f\x7f]*\z//;
    my ($safe) = $actor =~ /\A([A-Za-z0-9._-]{1,64}\@[A-Za-z0-9._-]{1,64})\z/;
    die "invalid principal\n" unless defined $safe;
    return $safe;
}
sub _safe_path {
    my ($path) = @_;
    my ($safe) = defined($path) && !ref($path)
        ? ($path =~ /\A(\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*)\z/) : ();
    die "invalid internal path\n" unless defined $safe;
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
    die "invalid update state: $path: $@\n" if $@ || ref($data) ne 'HASH';
    return $data;
}
sub _write_json {
    my ($path, $data) = @_;
    ensure_dir(state_dir());
    write_file_atomic($path, json_encode($data, pretty => 1) . "\n", 0644);
}
sub _bulk_path { state_dir() . '/bulk-' . _safe_job($_[0]) . '.json' }

sub _bulk_elapsed {
    my ($bulk) = @_;
    my $start = $bulk->{started_epoch} // $bulk->{created_epoch};
    return 0 unless defined $start;
    my $end = $bulk->{finished_epoch} // Time::HiRes::time();
    my $elapsed = int($end - $start);
    return $elapsed > 0 ? $elapsed : 0;
}

sub _job_elapsed {
    my ($job) = @_;
    my $start = $job->{started_epoch} // $job->{created_epoch};
    return 0 unless defined $start;
    my $end = $job->{finished_epoch} // Time::HiRes::time();
    my $elapsed = int($end - $start);
    return $elapsed > 0 ? $elapsed : 0;
}

sub _bulk_active_state {
    my ($state) = @_;
    return defined($state) && $state =~ /\A(?:queued|launching|running)\z/;
}

sub _bulk_nodes_init {
    my ($nodes) = @_;
    my %states = map { $_ => { state => 'queued' } } @{$nodes || []};
    return \%states;
}

sub _decorate_bulk {
    my ($bulk) = @_;
    return undef unless $bulk;
    $bulk->{elapsed_seconds} = _bulk_elapsed($bulk);
    $bulk->{orchestrator_lost} = (($bulk->{state} // '') eq 'lost') ? 1 : 0;
    return $bulk;
}

sub _mark_bulk_lost_locked {
    my ($bulk, $path) = @_;
    return $bulk unless _bulk_active_state($bulk->{state});
    return $bulk unless time - ($bulk->{heartbeat_epoch} // 0) > BULK_HEARTBEAT_TIMEOUT;
    $bulk->{state} = 'lost';
    $bulk->{error} = 'bulk worker heartbeat is stale';
    $bulk->{finished} = _now();
    $bulk->{finished_epoch} = Time::HiRes::time();
    delete $bulk->{current_node};
    for my $node (@{ $bulk->{nodes} || [] }) {
        my $item = $bulk->{node_states}{$node} ||= {};
        $item->{state} = 'skipped' if ($item->{state} // '') eq 'queued';
    }
    _write_json($path, $bulk);
    return $bulk;
}

sub _bulk_files_locked {
    my @items;
    return @items unless opendir(my $dh, state_dir());
    while (my $entry = readdir($dh)) {
        next unless $entry =~ /\Abulk-([0-9a-f-]+)\.json\z/;
        my $path = state_dir() . '/' . $entry;
        my $item = eval { _read_json($path) };
        next unless $item && $item->{id};
        $item = _mark_bulk_lost_locked($item, $path);
        push @items, $item;
    }
    closedir($dh);
    return @items;
}

sub _active_bulk_locked {
    my @active = grep { _bulk_active_state($_->{state}) } _bulk_files_locked();
    @active = sort { ($b->{created_epoch} // 0) <=> ($a->{created_epoch} // 0) } @active;
    return $active[0];
}

sub active_bulk {
    my ($class) = @_;
    return MMPve::Core::Config->with_domain_lock('updates-bulk', sub {
        return _decorate_bulk(_active_bulk_locked());
    });
}

sub _bulk_for_node {
    my ($node) = @_;
    my $matching = MMPve::Core::Config->with_domain_lock('updates-bulk', sub {
        my @items = _bulk_files_locked();
        return [grep {
            my $item = $_;
            grep { $_ eq $node } @{ $item->{nodes} || [] };
        } @items];
    });
    my @bulk = @{$matching || []};
    @bulk = sort { ($b->{created_epoch} // 0) <=> ($a->{created_epoch} // 0) } @bulk;
    return _decorate_bulk($bulk[0]);
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
    open(my $fh, '>>', $path) or die "could not open job log: $!\n";
    binmode($fh, ':raw');
    for my $line (split /\n/, $text // '', -1) {
        print {$fh} utf8_bytes(_sanitize_log($line) . "\n");
    }
    close($fh) or die "could not close job log: $!\n";
}
sub _unit_active {
    my ($unit) = @_;
    return 0 unless defined($unit) && $unit =~ /\Amm-pve-update-[0-9a-f-]+\z/;
    # A unit é oneshot: enquanto o worker roda ela fica em "activating", e
    # "systemctl is-active" sai com erro nesse estado. Só inactive/failed (ou
    # unit já coletada, que aparece como inactive) significa worker morto. Se
    # o systemd não responder, o job continua ativo: na dúvida, nada de
    # liberar um segundo apt em paralelo.
    my $r = MMPve::Core::Runner->run(['systemctl', 'show', '--property=ActiveState', '--value', $unit], timeout => 15);
    return 1 unless $r->{ok};
    my ($state) = ($r->{out} // '') =~ /\A\s*([a-z-]+)/;
    return 1 unless defined $state;
    return $state =~ /\A(?:inactive|failed)\z/ ? 0 : 1;
}

sub _set_job_phase {
    my ($node, $id, $state, $phase) = @_;
    my $updated = _with_node_lock($node, sub {
        my $current = _read_json(_current_path($node));
        return $state unless $current && $current->{id} eq $id;
        my $now = _now();
        my $epoch = Time::HiRes::time();
        my $last = $current->{phase_history} && @{$current->{phase_history}}
            ? $current->{phase_history}[-1] : undef;
        return $current if $last && ($last->{phase} // '') eq $phase;
        if ($last && !defined($last->{finished})) {
            $last->{finished} = $now;
            $last->{finished_epoch} = $epoch;
        }
        $current->{phase} = $phase;
        $current->{phase_started} = $now;
        $current->{phase_started_epoch} = $epoch;
        push @{$current->{phase_history}}, {
            phase => $phase, started => $now, started_epoch => $epoch,
        };
        $current->{phase_timestamps}{$phase} = {
            started => $now, started_epoch => $epoch,
        };
        $current->{elapsed_seconds} = _job_elapsed($current);
        _write_json(_current_path($node), $current);
        return $current;
    });
    %{$state} = %{$updated} if ref($updated) eq 'HASH';
    return $state;
}

sub _reconcile_locked {
    my ($node, $state) = @_;
    return $state unless $state && ($state->{state} eq 'queued' || $state->{state} eq 'running');
    return $state if $state->{launching} && ($state->{launch_deadline} // 0) > time;
    return $state if _unit_active($state->{unit});
    $state->{state} = 'lost';
    $state->{finished} = _now();
    $state->{error} = 'transient unit is inactive without a final state';
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
    $state->{elapsed_seconds} = _job_elapsed($state) if $state;
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
    return MMPve::Core::Config->with_domain_lock('updates-bulk', sub {
        my $bulk = _active_bulk_locked();
        if ($bulk && (!$opts{bulk_id} || $opts{bulk_id} ne $bulk->{id})
            && grep { $_ eq $node } @{ $bulk->{nodes} || [] }) {
            die "node $node belongs to active update bulk $bulk->{id}\n";
        }
        return _with_node_lock($node, sub {
            my $current = _read_json(_current_path($node));
            if ($current && ($current->{state} eq 'queued' || $current->{state} eq 'running')) {
                $current = _reconcile_locked($node, $current);
                die "an update job is already active on node $node ($current->{id})\n"
                    if $current->{state} eq 'queued' || $current->{state} eq 'running';
            }
            my $id = random_uuid();
            my $now = _now();
            my $epoch = Time::HiRes::time();
            my $state = {
                id => $id, node => $node, requested_by => $actor,
                state => 'queued', phase => 'queued', created => $now, created_epoch => $epoch,
                phase_started => $now, phase_started_epoch => $epoch,
                phase_history => [{ phase => 'queued', started => $now, started_epoch => $epoch }],
                phase_timestamps => { queued => { started => $now, started_epoch => $epoch } },
                elapsed_seconds => 0,
                unit => _unit_name($id),
                launching => 1, launch_deadline => time + 60,
                bulk_id => $opts{bulk_id},
                log => log_dir() . '/' . $id . '.log',
            };
            delete $state->{bulk_id} unless defined $state->{bulk_id};
            _write_json(_current_path($node), $state);
            return $state;
        });
    });
}

sub _finish {
    my ($class, $node, $id, $state, $result) = @_;
    _with_node_lock($node, sub {
        my $current = _read_json(_current_path($node));
        return unless $current && $current->{id} eq $id;
        my $now = _now();
        my $epoch = Time::HiRes::time();
        my $last = $current->{phase_history} && @{$current->{phase_history}}
            ? $current->{phase_history}[-1] : undef;
        if (!$last || ($last->{phase} // '') ne 'done') {
            if ($last && !defined($last->{finished})) {
                $last->{finished} = $now;
                $last->{finished_epoch} = $epoch;
                my $stamp = $current->{phase_timestamps}{$last->{phase}};
                if (ref($stamp) eq 'HASH') {
                    $stamp->{finished} = $now;
                    $stamp->{finished_epoch} = $epoch;
                }
            }
            push @{$current->{phase_history}}, {
                phase => 'done', started => $now, started_epoch => $epoch,
                finished => $now, finished_epoch => $epoch,
            };
            $current->{phase_timestamps}{done} = {
                started => $now, started_epoch => $epoch,
                finished => $now, finished_epoch => $epoch,
            };
            $current->{phase} = 'done';
            $current->{phase_started} = $now;
            $current->{phase_started_epoch} = $epoch;
        }
        delete $state->{launching};
        my $final_state = (defined($result->{state}) && $result->{state} =~ /\A(?:succeeded|warning|failed)\z/)
            ? $result->{state} : ($result->{ok} ? 'succeeded' : 'failed');
        $current->{state} = $final_state;
        $current->{finished} = $now;
        $current->{finished_epoch} = $epoch;
        $current->{elapsed_seconds} = _job_elapsed($current);
        $current->{result} = $result;
        if (!$result->{ok} || ($result->{state} // '') eq 'warning') {
            $current->{error} = $result->{error} // $result->{warning} if defined($result->{error} // $result->{warning});
        }
        _write_json(_current_path($node), $current);
        _write_json(_history_path($node, $id), $current);
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
        $class->_finish($node, $id, $state, { ok => 0, error => 'systemd-run failed: ' . ($res->{err} || $res->{error} || "rc=$res->{rc}") });
        die "could not start job unit $id: " . ($res->{err} || $res->{error} || "rc=$res->{rc}") . "\n";
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
    my $state = $class->_reserve($node, $opts{actor}, mode => 'single', bulk_id => $opts{bulk_id});
    return $class->_launch($state);
}

sub run_job {
    my ($class, $node, $id) = @_;
    $node = _safe_node($node); $id = _safe_job($id);
    my $state = _with_node_lock($node, sub {
        my $s = _read_json(_current_path($node));
        die "update job not found\n" unless $s && $s->{id} eq $id;
        die "update job is not queued\n" unless $s->{state} eq 'queued';
        $s->{state} = 'running';
        $s->{started} = _now();
        $s->{started_epoch} = Time::HiRes::time();
        delete $s->{launching};
        _write_json(_current_path($node), $s);
        return $s;
    });
    _append_log($state->{log}, "job $id started; requested by $state->{requested_by}\n");
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
    _set_job_phase($node, $id, $state, 'apt-update');
    my $update = $run->($timeout, 'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'update',
        '-o', "DPkg::Lock::Timeout=$lock_timeout");
    if (!$update->{ok}) {
        $result->{error} = 'apt-get update failed';
    } else {
        _set_job_phase($node, $id, $state, 'upgrade');
        my $upgrade = $run->(undef, 'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', '-y', 'dist-upgrade',
            '-o', 'Dpkg::Options::=--force-confdef', '-o', 'Dpkg::Options::=--force-confold',
            '-o', "DPkg::Lock::Timeout=$lock_timeout");
        if (!$upgrade->{ok}) {
            $result->{error} = 'apt-get dist-upgrade failed';
        } else {
            _set_job_phase($node, $id, $state, 'triggers');
            my $triggers = $run->($timeout, 'dpkg', '--configure', '--pending');
            if (!$triggers->{ok}) {
                $result->{error} = 'dpkg pending triggers failed';
            } else {
                _set_job_phase($node, $id, $state, 'apply');
                my $apply = eval {
                    MMPve::Core::Apply->apply_all(
                        patches => (-d root_path('/usr/share/pve-manager') ? 1 : 0),
                        allow_updates => 1,
                    )
                };
                if ($@ || ref($apply) ne 'HASH' || !$apply->{ok}) {
                    my $detail = $@ || (ref($apply) eq 'HASH' && ($apply->{error} || $apply->{reason} || $apply->{message}))
                        || 'apply returned no result';
                    $detail =~ s/\s+\z//;
                    $result = { ok => 1, state => 'warning',
                        warning => "post-update apply failed: $detail", error => "post-update apply failed: $detail" };
                } else {
                    $result = { ok => 1, apply => $apply };
                }
            }
        }
    }
    _append_log($state->{log}, $result->{state} && $result->{state} eq 'warning'
        ? "job completed with warning: $result->{warning}\n"
        : ($result->{ok} ? "job completed successfully\n" : "job failed: $result->{error}\n"));
    $class->_finish($node, $id, $state, $result);
    return $result;
}

sub refresh {
    my ($class, $node) = @_;
    $node = _safe_node($node // hostname());
    my $res = MMPve::Core::Runner->run(['env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'update'], timeout => 900);
    die "apt-get update failed: " . ($res->{err} || "rc=$res->{rc}") . "\n" unless $res->{ok};
    return { ok => 1, node => $node };
}

sub _cluster_preflight {
    my ($nodes) = @_;
    my $cluster = MMPve::Core::Runner->pvesh(get => '/cluster/status');
    die "preflight: cluster has no quorum\n" if ref($cluster) eq 'ARRAY'
        && grep { ref($_) eq 'HASH' && exists($_->{quorate}) && !$_->{quorate} } @{$cluster};
    my %online = map { ($_->{name} // $_->{node} => $_->{online}) }
        grep { ref($_) eq 'HASH' && ($_->{type} // '') eq 'node' } (ref($cluster) eq 'ARRAY' ? @{$cluster} : ());
    for my $node (@{$nodes}) {
        die "preflight: unknown node $node\n" unless exists $online{$node};
        die "preflight: node $node offline\n" unless $online{$node};
    }
    my $ha = eval { MMPve::Core::Runner->pvesh(get => '/cluster/ha/status/current') };
    if (ref($ha) eq 'ARRAY') {
        for my $item (@{$ha}) {
            my $text = json_encode($item);
            die "preflight: HA has an error or migration\n" if $text =~ /(?:error|migrat)/i;
        }
    }
    my $ceph = eval { MMPve::Core::Runner->pvesh(get => '/cluster/ceph/status') };
    if ($ceph && ref($ceph) eq 'HASH') {
        my $health = ref($ceph->{health}) eq 'HASH' ? $ceph->{health}{status} : $ceph->{health};
        die "preflight: Ceph is not HEALTH_OK\n" if defined($health) && $health ne 'HEALTH_OK';
    }
    return { ok => 1, quorum => 1, nodes => \@{$nodes}, ha => 'ok', ceph => $ceph ? 'ok' : 'absent' };
}

sub _bulk_mutate {
    my ($id, $code) = @_;
    my $path = _bulk_path($id);
    return MMPve::Core::Config->with_domain_lock('updates-bulk', sub {
        my $bulk = _read_json($path) or die "update bulk not found\n";
        my $value = $code->($bulk);
        _write_json($path, $bulk);
        return $value || $bulk;
    });
}

sub _bulk_set_node {
    my ($id, $node, $state, %extra) = @_;
    return _bulk_mutate($id, sub {
        my ($bulk) = @_;
        $bulk->{node_states}{$node} ||= {};
        $bulk->{node_states}{$node}{state} = $state;
        $bulk->{node_states}{$node}{$_} = $extra{$_} for keys %extra;
        if ($state eq 'running') {
            $bulk->{state} = 'running' if ($bulk->{state} // '') eq 'launching';
            $bulk->{current_node} = $node;
            $bulk->{current_phase} = 'queued';
        } elsif (($bulk->{current_node} // '') eq $node) {
            delete $bulk->{current_node};
            delete $bulk->{current_phase};
        }
        $bulk->{heartbeat} = _now();
        $bulk->{heartbeat_epoch} = time;
        return $bulk;
    });
}

sub _bulk_finish {
    my ($id, $state, %extra) = @_;
    return _bulk_mutate($id, sub {
        my ($bulk) = @_;
        $bulk->{state} = $state;
        $bulk->{$_} = $extra{$_} for keys %extra;
        $bulk->{finished} = _now();
        $bulk->{finished_epoch} = Time::HiRes::time();
        delete $bulk->{current_node};
        return $bulk;
    });
}

sub run_bulk {
    my ($class, $nodes, %opts) = @_;
    die "nodes must be a list\n" unless ref($nodes) eq 'ARRAY' && @{$nodes};
    my %seen; my @authorized = map { _safe_node($_) } @{$nodes};
    @authorized = grep { !$seen{$_}++ } @authorized;
    my $mode = $opts{mode} // 'sequential';
    die "mode must be sequential or parallel\n" unless $mode eq 'sequential' || $mode eq 'parallel';
    return MMPve::Core::Config->with_domain_lock('updates-bulk', sub {
        my $active = _active_bulk_locked();
        die "another update bulk is active: $active->{id}\n" if $active;
        my $preflight = $opts{preflight_cb} || sub { _cluster_preflight($_[0]) };
        my ($pf, $preflight_error);
        eval { $pf = $preflight->(\@authorized); 1 } or $preflight_error = $@;
        if ($preflight_error) {
            die $preflight_error unless $opts{override};
            $pf = { ok => 0, error => $preflight_error };
        }
        die "bulk preflight blocked\n" unless $opts{override} || ($pf && $pf->{ok});
        my $id = random_uuid();
        ensure_dir(state_dir());
        my $now = _now();
        my $epoch = Time::HiRes::time();
        my $state = { id => $id, state => 'launching', requested_by => _safe_actor($opts{actor}),
            mode => $mode, nodes => \@authorized, node_states => _bulk_nodes_init(\@authorized),
            override => $opts{override} ? 1 : 0, preflight => $pf,
            created => $now, created_epoch => $epoch, started_epoch => $epoch,
            heartbeat => $now, heartbeat_epoch => time, results => {} };
        my $path = _bulk_path($id);
        _write_json($path, $state);
        my $cfg = eval { MMPve::Core::Config->load } || MMPve::Core::Config->default;
        _prune_bulk($cfg->{updates}{retention} // DEFAULT_RETENTION);
        my $bin = _safe_path($ENV{MM_PVE_BIN} || '/usr/sbin/mm-pve');
        my @cmd = ('systemd-run', '--no-block', '--collect', '--service-type=oneshot',
            '--unit=mm-pve-bulk-' . $id, 'env', '-i',
            'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'DEBIAN_FRONTEND=noninteractive',
            'MM_PVE_CONFIG_DIR=' . _safe_path(MMPve::Core::Config->config_dir),
            $bin, 'updates', 'bulk-worker', '--bulk', $id);
        my $res = MMPve::Core::Runner->run(\@cmd, timeout => 30);
        if (!$res->{ok}) {
            $state->{state} = 'failed';
            $state->{error} = 'could not start bulk worker';
            $state->{finished} = _now();
            $state->{finished_epoch} = Time::HiRes::time();
            _write_json($path, $state);
            die "could not start bulk worker\n";
        }
        return { bulk_id => $id, nodes => \@authorized, mode => $mode, preflight => $pf,
            node_states => $state->{node_states} };
    });
}

sub cancel_bulk {
    my ($class, $id) = @_;
    $id = _safe_job($id);
    my $bulk = MMPve::Core::Config->with_domain_lock('updates-bulk', sub {
        my $path = _bulk_path($id);
        my $current = _read_json($path) or die "update bulk not found\n";
        die "update bulk is already finished\n" unless _bulk_active_state($current->{state});
        $current->{cancel_requested} = 1;
        for my $node (@{ $current->{nodes} || [] }) {
            my $item = $current->{node_states}{$node} ||= {};
            if (($item->{state} // '') eq 'queued') {
                $item->{state} = 'cancelled';
                $current->{results}{$node} = { ok => 0, state => 'cancelled' };
            }
        }
        $current->{heartbeat} = _now();
        $current->{heartbeat_epoch} = time;
        my $has_running = grep { ($_->{state} // '') eq 'running' } values %{ $current->{node_states} || {} };
        $current->{state} = 'cancelled' unless $has_running;
        if ($current->{state} eq 'cancelled') {
            $current->{finished} = _now();
            $current->{finished_epoch} = Time::HiRes::time();
        }
        _write_json($path, $current);
        return $current;
    });
    return _decorate_bulk($bulk);
}

sub bulk_worker {
    my ($class, $id) = @_;
    $id = _safe_job($id);
    my $path = _bulk_path($id);
    my $bulk = _bulk_mutate($id, sub {
        my ($current) = @_;
        die "update bulk is not launchable\n" unless _bulk_active_state($current->{state});
        $current->{state} = 'running';
        $current->{started} = _now();
        $current->{started_epoch} = Time::HiRes::time();
        $current->{heartbeat} = _now();
        $current->{heartbeat_epoch} = time;
        return $current;
    });
    my @nodes = @{ $bulk->{nodes} || [] };
    my @started;
    my $stop = 0;
    for my $node (@nodes) {
        my $current = _read_json($path) || {};
        if ($current->{cancel_requested}) {
            _bulk_mutate($id, sub {
                my ($item) = @_;
                for my $remaining (@nodes) {
                    my $state = $item->{node_states}{$remaining}{state} // 'queued';
                    if ($state eq 'queued') {
                        $item->{node_states}{$remaining}{state} = 'cancelled';
                        $item->{results}{$remaining} = { ok => 0, state => 'cancelled' };
                    }
                }
                return $item;
            });
            last;
        }
        if ($bulk->{mode} eq 'sequential' && !$bulk->{override}) {
            my ($pf, $error);
            eval { $pf = _cluster_preflight([$node]); 1 } or $error = $@;
            if ($error || !$pf || !$pf->{ok}) {
                _bulk_set_node($id, $node, 'failed', error => $error || $pf->{error} || "preflight blocked before node $node");
                _bulk_finish($id, 'failed', error => 'bulk stopped by preflight failure');
                die "bulk preflight failed\n";
            }
        }
        _bulk_set_node($id, $node, 'running');
        my $result = eval {
            if ($node eq hostname()) {
                my $job = $class->request_run($node, actor => $bulk->{requested_by}, bulk_id => $id);
                return { ok => 1, job => $job };
            }
            my $upid = MMPve::Core::Runner->pvesh_task('create', "/nodes/$node/mm-tools/updates/run",
                requested_by => $bulk->{requested_by}, bulk_id => $id);
            return { ok => 1, upid => $upid };
        };
        $result = { ok => 0, error => $@ } if $@;
        _bulk_mutate($id, sub { $_[0]{results}{$node} = $result; return $_[0] });
        if (!$result->{ok}) {
            _bulk_set_node($id, $node, 'failed', error => $result->{error});
            if ($bulk->{mode} eq 'sequential') {
                _bulk_finish($id, 'failed', error => "bulk stopped at node $node");
                die "bulk failed to start node $node\n";
            }
            next;
        }
        push @started, $node;
        if ($bulk->{mode} eq 'sequential') {
            my $done = $class->_wait_for_node($node, bulk_path => $path);
            _bulk_mutate($id, sub { $_[0]{results}{$node}{result} = $done; return $_[0] });
            my $node_state = $done->{state} eq 'warning' ? 'warning'
                : ($done->{ok} ? 'succeeded' : 'failed');
            _bulk_set_node($id, $node, $node_state, result => $done);
            if (!$done->{ok}) {
                _bulk_mutate($id, sub {
                    my ($item) = @_;
                    for my $remaining (@nodes) {
                        $item->{node_states}{$remaining}{state} = 'skipped'
                            if ($item->{node_states}{$remaining}{state} // '') eq 'queued';
                    }
                    return $item;
                });
                _bulk_finish($id, 'failed', error => "bulk stopped at node $node");
                $stop = 1;
                last;
            }
        }
    }
    if (!$stop && $bulk->{mode} eq 'parallel') {
        for my $node (@started) {
            my $done = $class->_wait_for_node($node, bulk_path => $path);
            _bulk_mutate($id, sub { $_[0]{results}{$node}{result} = $done; return $_[0] });
            my $node_state = $done->{state} eq 'warning' ? 'warning'
                : ($done->{ok} ? 'succeeded' : 'failed');
            _bulk_set_node($id, $node, $node_state, result => $done);
        }
    }
    my $final = _read_json($path) || {};
    if (($final->{state} // '') =~ /\A(?:failed|lost)\z/) {
        return $final;
    }
    my $failed = grep { ($_->{state} // '') eq 'failed' } values %{ $final->{node_states} || {} };
    my $cancelled = $final->{cancel_requested} ? 1 : 0;
    return _bulk_finish($id, $cancelled ? 'cancelled' : ($failed ? 'failed' : 'succeeded'));
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
            if ($bulk && _bulk_active_state($bulk->{state})) {
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
        if (ref($state) eq 'HASH' && ($state->{state} // '') =~ /^(?:succeeded|warning|failed|lost)$/) {
            return { ok => $state->{state} eq 'failed' || $state->{state} eq 'lost' ? 0 : 1,
                state => $state->{state}, error => $state->{error}, warning => $state->{result}{warning},
                elapsed_seconds => $state->{elapsed_seconds} // _job_elapsed($state) };
        }
        if ($opts{bulk_path} && ref($state) eq 'HASH' && $state->{phase}) {
            my ($bulk_id) = $opts{bulk_path} =~ m{/bulk-([0-9a-f-]+)\.json\z};
            if ($bulk_id) {
                _bulk_mutate($bulk_id, sub {
                    my ($bulk) = @_;
                    return $bulk unless ($bulk->{current_node} // '') eq $node;
                    $bulk->{current_phase} = $state->{phase};
                    $bulk->{node_states}{$node}{phase} = $state->{phase};
                    $bulk->{node_states}{$node}{elapsed_seconds} = $state->{elapsed_seconds} // _job_elapsed($state);
                    return $bulk;
                });
            }
        }
        select(undef, undef, undef, 1);
    }
    return { ok => 0, state => 'timed_out', error => 'timeout waiting for node job' };
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
    die "invalid confirmation: type the node name\n" unless defined($opts{confirm}) && $opts{confirm} eq $node;
    my $s = $class->status($node, pending_cb => ($opts{pending_cb} || sub { _default_pending($_[0]) }),
        online => exists($opts{online}) ? $opts{online} : 1);
    die "node $node is offline\n" unless $s->{online};
    die "an update job is active on node $node\n" if $s->{job} && ($s->{job}{state} eq 'queued' || $s->{job}{state} eq 'running');
    die "no new kernel is pending\n" unless $s->{kernel}{reboot_suggested};
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
    die "job does not belong to the node\n" unless $state && $state->{id} eq $id && $state->{node} eq $node;
    my $start = defined($opts{start}) && $opts{start} =~ /^\d+$/ ? 0 + $opts{start} : 0;
    my $limit = defined($opts{limit}) && $opts{limit} =~ /^\d+$/ ? 0 + $opts{limit} : 100;
    die "invalid log limit\n" if $limit < 1 || $limit > MAX_LOG_LIMIT;
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
    else { print STDERR "usage: mm-pve updates status|refresh|run|log|reboot\n"; return 2 }
    print json_encode($out, pretty => 1), "\n";
    return 0;
}

1;
