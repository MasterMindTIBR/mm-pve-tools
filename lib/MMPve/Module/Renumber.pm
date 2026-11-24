package MMPve::Module::Renumber;

# Módulo renumber — troca de VMID via move_disk (plano: "Módulo renumber").
#
# Fluxo: precheck (somente leitura) → passos com journal antes/depois
# (reserve, move_disks, config, firewall, refs, verify, destroy).
# --dry-run mostra o plano; --resume continua do primeiro passo pendente;
# --rollback desfaz os passos concluídos em ordem inversa.

use strict;
use warnings;
use base qw(MMPve::Core::ModuleBase);

use JSON::PP ();
use MMPve::Core::Runner;
use MMPve::Core::Config;
use MMPve::Journal;
use MMPve::Core::Util qw(read_file write_file_atomic root_path log_line json_encode);
use Sys::Hostname qw(hostname);
use POSIX qw(getpid);

our $VERSION = '@MM_PVE_VERSION@';

# Espera de tarefa pvesh (testes reduzem o intervalo/timeout).
our $TASK_POLL    = 2;      # segundos entre consultas a /nodes/<n>/tasks/<upid>/status
our $TASK_TIMEOUT = 21600;  # 6h por tarefa (move_disk de disco grande demora)
our $RUN_MARKER_TTL = 120;
our $CONFIG_LOCK;           # injetável nos testes; em PVE usa PVE::QemuConfig

# Grammar real de um volid de volume (ver PVE::GuestHelpers/QemuServer):
# <storage>:(<vmid>/)?(vm|base)-<vmid>-..., com storage podendo ter hífen
# (ex.: local-zfs, nfs-bkp) e storages baseados em arquivo (nfs/dir/cifs)
# aninhando o volume numa subpasta <vmid>/.
my $VOLID_RE = qr/^[A-Za-z0-9][A-Za-z0-9_.\-]*:(?:\d+\/)?(?:vm|base)-\d+-/;

my @STEPS = qw(reserve move_disks config firewall refs verify destroy);

# ------------------------------------------------------------- helpers

sub _vmid_ok { return defined $_[0] && $_[0] =~ /^\d+$/ && $_[0] >= 100 && $_[0] <= 9999999 }

sub _chomp { my $s = $_[0]; return '' unless defined $s; chomp $s; return $s }

sub _check {
    my ($list, $name, $ok, $detail, $warning) = @_;
    push @{$list}, {
        check => $name, ok => $ok ? 1 : 0,
        detail => $detail // '',
        ($warning ? (warning => 1) : ()),
    };
    return $ok;
}

sub _pvesh_opt {
    # pvesh que devolve eval-error em vez de die (para precheck).
    my ($class, $method, $path, %args) = @_;
    my $d = eval { MMPve::Core::Runner->pvesh($method, $path, %args) };
    return ($d, $@ ? $@ : undef);
}

sub _find_node {
    my ($class, $vmid) = @_;
    my ($res) = $class->_pvesh_opt(get => '/cluster/resources', type => 'vm');
    return undef if !$res;
    for my $e (@{$res || []}) {
        next unless ($e->{vmid} // '') eq $vmid && ($e->{type} // '') eq 'qemu';
        return $e->{node};
    }
    return undef;
}

# Classificação dos drives (plano, pré-checagem 6).
# kind: copy_line (CD/ISO, passthrough /dev/), cloudinit, volume.
sub _classify_drives {
    my ($class, $conf, $storage_types) = @_;
    my @drives;
    for my $k (sort keys %{$conf || {}}) {
        next unless $k =~ /^(?:ide|sata|scsi|virtio)\d+$/
            || $k =~ /^unused\d+$/ || $k eq 'efidisk0' || $k eq 'tpmstate0';
        my $v = $conf->{$k};
        next unless defined $v && !ref $v;
        my $kind;
        if ($v eq 'none' || ($v =~ /media=cdrom/ && $v !~ /cloudinit/)) {
            $kind = 'copy_line';
        } elsif ($v =~ /cloudinit/) {
            $kind = 'cloudinit';
        } elsif ($v =~ m{^/dev/}) {
            $kind = 'copy_line';
        } elsif ($v =~ $VOLID_RE) {
            $kind = 'volume';
        } else {
            $kind = 'copy_line';    # ex.: "local:iso/..." sem cdrom — copia
        }
        my ($sid) = $kind eq 'volume' ? ($v =~ /^([A-Za-z0-9][A-Za-z0-9_.\-]*):/) : ();
        push @drives, {
            key => $k, kind => $kind, value => $v,
            storage => $sid,
            storage_type => $sid ? $storage_types->{$sid} : undef,
        };
    }
    return @drives;
}

sub _scheme_warning {
    my ($class, $to) = @_;
    my ($cfg) = eval { MMPve::Core::Config->load };
    my $ranges = ($cfg && ref $cfg->{vmid_scheme} eq 'ARRAY') ? $cfg->{vmid_scheme} : [];
    return undef unless @{$ranges};
    for my $r (@{$ranges}) {
        return undef if $to >= $r->{from} && $to <= $r->{to};
    }
    my @labels = map { $_->{label} } @{$ranges};
    return "ID $to is outside the configured scheme (ranges: " . join(', ', @labels) . ")";
}

sub journal_id {
    my ($class, $from, $to) = @_;
    return "renumber-$from-$to";
}

# Descrição do journal inacabado (qualquer estado fora de 'finished') para o
# par, ou undef quando não há journal ou ele terminou.
sub _pending_journal {
    my ($class, $from, $to) = @_;
    my $id = $class->journal_id($from, $to);
    my $file = MMPve::Journal->path_for($id);
    return undef unless -e $file;
    my $j = eval { MMPve::Journal->open($id) };
    return "journal $id is unreadable; check $file before continuing" unless $j;
    my $state = $j->state // '';
    return undef if $state eq 'finished';
    my @done = $j->done_steps;
    return "renumber $from>$to is unfinished (journal $id, state $state"
        . (@done ? ', completed: ' . join(', ', @done) : '')
        . "); use --resume or --rollback. If the operation was cleaned manually, "
        . "remove $file";
}

sub _config_digest {
    my ($class, $conf) = @_;
    die "PVE did not return a configuration digest; unsafe operation\n"
        unless ref $conf eq 'HASH' && defined $conf->{digest} && length $conf->{digest};
    return $conf->{digest};
}

sub _source_snapshot {
    my ($class, $meta) = @_;
    my $path = "/nodes/$meta->{node}/qemu/$meta->{from}";
    my ($status, $status_err) = $class->_pvesh_opt(get => "$path/status/current");
    my ($conf, $conf_err) = $class->_pvesh_opt(get => "$path/config");
    return (undef, undef, 0) if $conf_err && $conf_err =~ /not found|does not exist|no such/i;
    die "could not query VM $meta->{from} status: " . _chomp($status_err)
        if $status_err;
    die "could not query VM $meta->{from} configuration: " . _chomp($conf_err)
        if $conf_err || !$conf;
    return ($status, $conf, 1);
}

sub _guard_source {
    my ($class, $j, $meta, %opt) = @_;
    my ($status, $conf, $exists) = $class->_source_snapshot($meta);
    return (undef, undef, 0) if !$exists && $opt{allow_absent};
    die "VM $meta->{from} disappeared before step $opt{step}\n" unless $exists;
    die "VM $meta->{from} is not stopped before step $opt{step}\n"
        unless ($status->{status} // '') eq 'stopped';
    my $expected = $meta->{config_digest};
    my $actual = $class->_config_digest($conf);
    die "VM $meta->{from} digest changed before step $opt{step}\n"
        unless defined $expected && $actual eq $expected;
    return ($status, $conf, 1);
}

sub _refresh_source_digest {
    my ($class, $j, $meta, $where) = @_;
    my ($status, $conf, $exists) = $class->_source_snapshot($meta);
    return undef unless $exists;
    die "VM $meta->{from} is not stopped after $where\n"
        unless ($status->{status} // '') eq 'stopped';
    my $digest = $class->_config_digest($conf);
    $meta->{config_digest} = $digest;
    $j->set_meta(config_digest => $digest);
    return $digest;
}

sub _before_step {
    my ($class, $j, $meta, $step) = @_;
    $j->heartbeat_run(owner_node => hostname(), pid => getpid());
    return $class->_guard_source($j, $meta, step => $step,
        allow_absent => ($step eq 'destroy'));
}

sub _with_config_lock {
    my ($class, $vmid, $code) = @_;
    return $CONFIG_LOCK->($vmid, $code) if $CONFIG_LOCK;
    if (eval { require PVE::QemuConfig; PVE::QemuConfig->can('lock_config') }) {
        my $out = PVE::QemuConfig->lock_config($vmid, $code);
        die $@ if $@;
        return $out;
    }
    return $code->();
}

sub _config_edit {
    my ($class, $node, $vmid, %args) = @_;
    if ($CONFIG_LOCK) {
        return $class->_with_config_lock($vmid, sub {
            return MMPve::Core::Runner->pvesh(set => "/nodes/$node/qemu/$vmid/config", %args);
        });
    }
    # pvesh is a separate process and would deadlock if called while this
    # process holds the same local config flock. For a local VM use the real
    # PVE config writer inside lock_config; a remote node owns its own lock and
    # is updated through its API endpoint.
    if ($node eq hostname()
        && eval { require PVE::QemuConfig; PVE::QemuConfig->can('load_config')
            && PVE::QemuConfig->can('write_config') }) {
        return $class->_with_config_lock($vmid, sub {
            my $conf = PVE::QemuConfig->load_config($vmid);
            die "could not load VM $vmid configuration\n" unless $conf;
            if (exists $args{delete}) {
                delete $conf->{ $args{delete} };
                delete $args{delete};
            }
            $conf->{$_} = $args{$_} for keys %args;
            return PVE::QemuConfig->write_config($vmid, $conf);
        });
    }
    return MMPve::Core::Runner->pvesh(set => "/nodes/$node/qemu/$vmid/config", %args);
}

sub _maybe_fail_after {
    my ($class, $step) = @_;
    return unless defined $ENV{MM_RENUMBER_FAIL_AFTER} && length $ENV{MM_RENUMBER_FAIL_AFTER};
    return unless $ENV{MM_RENUMBER_FAIL_AFTER} eq $step;
    die "failure injected after step '$step' (MM_RENUMBER_FAIL_AFTER)\n";
}

# ------------------------------------------------------------- precheck

sub precheck {
    my ($class, %o) = @_;
    my ($from, $to) = ($o{from}, $o{to});
    my @checks;
    my @warnings;
    my %info;

    if (!_vmid_ok($from) || !_vmid_ok($to)) {
        _check(\@checks, 'ids', 0, '--from and --to must be integers from 100 to 9999999');
        return { ok => 0, checks => \@checks, warnings => \@warnings, info => \%info };
    }
    _check(\@checks, 'ids-diferentes', ($from != $to ? 1 : 0),
        $from == $to ? 'new ID equals old ID' : 'ok');

    # 0. Nenhum renumber inacabado para o mesmo par. Começar do zero por cima
    # de um journal running/failed pularia os passos 'done' e iria direto ao
    # destroy da VM antiga com os discos ainda nela.
    my $open_journal = $class->_pending_journal($from, $to);
    _check(\@checks, 'sem-journal-pendente', ($open_journal ? 0 : 1),
        $open_journal // 'no unfinished renumber for this pair');

    # 1. ID novo livre (GET /cluster/nextid --vmid dá erro se em uso).
    my ($next, $next_err) = $class->_pvesh_opt(get => '/cluster/nextid', vmid => $to);
    _check(\@checks, 'id-novo-livre', ($next ? 1 : 0),
        $next ? "free (nextid suggests $next)"
              : ($next_err ? _chomp($next_err) : "ID $to is already in use"));

    # 2. Esquema de VMID.
    my $sw = $class->_scheme_warning($to);
    if ($sw) {
        push @warnings, $sw;
        _check(\@checks, 'esquema', ($o{force_scheme} ? 1 : 0),
            "$sw (use --force-scheme to force)", 1);
    } else {
        _check(\@checks, 'esquema', 1, 'inside the configured scheme (or no scheme)');
    }

    # Localizar a VM (com --node, confere que ela está mesmo lá).
    my $found = $class->_find_node($from) // '';
    my $node = ($o{node} && $o{node} ne $found) ? '' : $found;
    $info{node} = $node;
    _check(\@checks, 'vm-existe', ($node ? 1 : 0),
        $node ? "VM $from on node $node"
            : $o{node} && $found ? "VM $from is on node $found, not on $o{node}"
            : ("VM $from was not found" . ($o{node} ? " on node $o{node}" : ' in the cluster')));

    my $ok = (grep { !$_->{ok} } @checks) ? 0 : 1;
    return { ok => 0, checks => \@checks, warnings => \@warnings, info => \%info } if !$ok;

    # 3. Volumes órfãos vm-<novo>-*/base-<novo>-* em storages com images/rootdir.
    # Qualquer erro de API aqui é falha dura do check (antes virava "sem
    # órfão" escondido — RODADA2 #8).
    my ($nodes, $nodes_err) = $class->_pvesh_opt(get => '/cluster/status');
    my $orphan_detail = '';
    my $orphan_err = $nodes_err;
    if (!$orphan_err) {
        my @online = grep { ($_->{type} // '') eq 'node' && $_->{online} } @{$nodes || []};
        my %shared_seen;    # storage compartilhado: consulta 1x
        NODE: for my $n (@online) {
            my ($st, $st_err) = $class->_pvesh_opt(get => "/nodes/$n->{name}/storage");
            if ($st_err) { $orphan_err = $st_err; last NODE }
            for my $s (@{$st || []}) {
                next unless ($s->{enabled} // 1);
                my @content_types = split(/,/, $s->{content} // '');
                next unless grep { $_ eq 'images' || $_ eq 'rootdir' } @content_types;
                my $sid = $s->{storage};
                next if ($s->{shared} ? 1 : 0) && $shared_seen{$sid}++;
                my ($content, $content_err) = $class->_pvesh_opt(
                    get => "/nodes/$n->{name}/storage/$sid/content", vmid => $to);
                if ($content_err) { $orphan_err = $content_err; last NODE }
                if ($content && @{$content}) {
                    $orphan_detail = "storage $sid already has " . scalar(@{$content})
                        . " volume(s) for ID $to (" . join(', ', map { $_->{volid} // '?' } @{$content}) . ")";
                    last NODE;
                }
            }
        }
    }
    if ($orphan_err) {
        _check(\@checks, 'sem-volumes-orfaos', 0, 'error querying storages: ' . _chomp($orphan_err));
    } else {
        _check(\@checks, 'sem-volumes-orfaos', ($orphan_detail ? 0 : 1),
            $orphan_detail || "no vm-$to-* / base-$to-* volume on an images/rootdir storage");
    }

    # 4. Estado da VM de origem (status/lock vêm de status/current — GET
    # /nodes/<n>/qemu/<id> sozinho é só o índice de sub-rotas, não o status
    # real da VM — RODADA2 #1).
    my $vmpath = "/nodes/$node/qemu/$from";
    my ($vmstat, $vmstat_err) = $class->_pvesh_opt(get => "$vmpath/status/current");
    my ($conf, $conf_err) = $class->_pvesh_opt(get => "$vmpath/config");
    _check(\@checks, 'config-legivel', ($conf ? 1 : 0),
        $conf ? 'ok' : ($conf_err ? 'error reading configuration: ' . _chomp($conf_err)
                                   : 'could not read VM configuration'));
    return { ok => 0, checks => \@checks, warnings => \@warnings, info => \%info } if !$conf;

    if ($vmstat_err) {
        _check(\@checks, 'desligada', 0, 'error querying status: ' . _chomp($vmstat_err));
    } else {
        my $status = $vmstat->{status} // '?';
        _check(\@checks, 'desligada', ($status eq 'stopped' ? 1 : 0),
            "status: $status" . ($status eq 'stopped' ? '' : ' (must be stopped)'));
    }
    my $lock = ($vmstat && $vmstat->{lock}) // $conf->{lock};
    _check(\@checks, 'sem-lock', ($lock ? 0 : 1), $lock ? "lock: $lock" : 'no lock');
    _check(\@checks, 'nao-template', ($conf->{template} ? 0 : 1),
        $conf->{template} ? 'is a template' : 'is not a template');

    my ($snaps, $snaps_err) = $class->_pvesh_opt(get => "$vmpath/snapshot");
    if ($snaps_err) {
        _check(\@checks, 'sem-snapshots', 0, 'error querying snapshots: ' . _chomp($snaps_err));
    } else {
        my @extra_snaps = grep { ($_->{name} // '') ne 'current' } @{$snaps || []};
        _check(\@checks, 'sem-snapshots', (@extra_snaps ? 0 : 1),
            @extra_snaps ? 'snapshots: ' . join(', ', map { $_->{name} } @extra_snaps) : 'current only');
    }

    # /pending devolve TODAS as chaves da config ({key,value,...}); só tem
    # mudança pendente de verdade se a entrada tiver 'pending' (valor novo
    # ainda não aplicado) ou 'delete' (remoção pendente) — ver
    # PVE::GuestHelpers::config_with_pending_array. Antes, qualquer entrada
    # presente (o normal) já acusava "pendente" — RODADA2 #2.
    my ($pending, $pending_err) = $class->_pvesh_opt(get => "$vmpath/pending");
    if ($pending_err) {
        _check(\@checks, 'sem-pending', 0, 'error querying pending changes: ' . _chomp($pending_err));
    } else {
        my @active = grep { defined $_->{pending} || defined $_->{delete} } @{$pending || []};
        _check(\@checks, 'sem-pending', (@active ? 0 : 1),
            @active
                ? scalar(@active) . ' pending change(s): '
                    . join(', ', map { $_->{key} // '?' } @active)
                : 'no pending changes');
    }

    # 5. HA e replicação.
    my ($ha, $ha_err) = $class->_pvesh_opt(get => '/cluster/ha/resources');
    my $ha_entry;
    if ($ha_err) {
        _check(\@checks, 'ha', 0, 'error querying HA: ' . _chomp($ha_err));
    } else {
        ($ha_entry) = grep { ($_->{sid} // '') eq "vm:$from" } @{$ha || []};
        if ($ha_entry) {
            if ($o{handle_ha}) {
                push @warnings, 'VM is in HA: it will be removed and recreated with the new ID (--handle-ha)';
                _check(\@checks, 'ha', 1, 'in HA - handled with --handle-ha', 1);
            } else {
                _check(\@checks, 'ha', 0, 'VM is in HA (use --handle-ha)');
            }
        } else {
            _check(\@checks, 'ha', 1, 'not in HA');
        }
    }

    my ($ha_rules, $ha_rules_err) = $class->_pvesh_opt(get => '/cluster/ha/rules');
    my @ha_rules_for_vm;
    if ($ha_rules_err) {
        _check(\@checks, 'ha-regras', 0, 'error querying HA rules: ' . _chomp($ha_rules_err));
    } else {
        @ha_rules_for_vm = grep {
            my @resources = split /\s*,\s*/, ($_->{resources} // '');
            grep { $_ eq "vm:$from" } @resources;
        } @{$ha_rules || []};
        if (@ha_rules_for_vm && !$o{handle_ha}) {
            _check(\@checks, 'ha-regras', 0,
                'VM appears in an HA rule (use --handle-ha)');
        } else {
            _check(\@checks, 'ha-regras', 1,
                @ha_rules_for_vm ? scalar(@ha_rules_for_vm) . ' HA rule(s) will be migrated' : 'no HA rule');
        }
    }

    my ($repl, $repl_err) = $class->_pvesh_opt(get => '/cluster/replication');
    my @repl_jobs;
    if ($repl_err) {
        _check(\@checks, 'replicacao', 0, 'error querying replication: ' . _chomp($repl_err));
    } else {
        @repl_jobs = grep { ($_->{guest} // '') eq $from } @{$repl || []};
        my @invalid_repl;
        for my $r (@repl_jobs) {
            my ($suffix) = ($r->{id} // '') =~ /^\Q$from\E-(\d+)$/;
            my $valid = defined($suffix) && defined($r->{jobnum}) && $r->{jobnum} eq $suffix
                && defined($r->{type}) && defined($r->{target});
            my %create = map { $_ => 1 } qw(comment disable rate schedule source target type);
            push @invalid_repl, $r->{id} // '?' if !$valid
                || grep { !exists $create{$_} && !/^(?:id|guest|jobnum|digest)$/ } keys %{$r};
        }
        if (@invalid_repl) {
            _check(\@checks, 'replicacao-preservavel', 0,
                'job(s) without a preservable schema: ' . join(', ', @invalid_repl));
        } else {
            _check(\@checks, 'replicacao-preservavel', 1,
                @repl_jobs ? 'all replication fields are preservable' : 'no replication');
        }
        if (@repl_jobs) {
            if ($o{handle_replication}) {
                push @warnings, 'VM has replication (' . join(', ', map { $_->{id} } @repl_jobs)
                    . '): it will be removed and recreated; recreation performs a FULL sync';
                _check(\@checks, 'replicacao', 1, 'replication handled with --handle-replication', 1);
            } else {
                _check(\@checks, 'replicacao', 0, 'VM has replication (use --handle-replication)');
            }
        } else {
            _check(\@checks, 'replicacao', 1, 'no replication');
        }
    }

    # 6. Classificação dos drives — storage precisa suportar rename de
    # volume de verdade (PVE::Storage::volume_has_feature), não uma lista
    # fixa de tipos de storage (que rejeitava LVM/RBD à toa) — RODADA2 #9.
    # Exceção documentada ao "só API pública": não existe endpoint de API
    # pra "este storage suporta rename"; mesmo padrão usado em Restore.pm
    # pra ler storage.cfg.
    my $storage_cfg = eval { require PVE::Storage; PVE::Storage::config() };
    my $storage_cfg_err = $@;
    my ($storages, $storages_err) = $class->_pvesh_opt(get => '/storage');
    my %storage_types = map { ($_->{storage} // '') => ($_->{type} // '') } @{$storages || []};
    my @drives = $class->_classify_drives($conf, \%storage_types);
    my $bad_storage = '';
    if ($storages_err) {
        $bad_storage = 'error querying /storage: ' . _chomp($storages_err);
    } elsif ($storage_cfg_err) {
        $bad_storage = 'could not read storage.cfg: ' . _chomp($storage_cfg_err);
    } else {
        for my $d (@drives) {
            next unless $d->{kind} eq 'volume';
            my $t = $d->{storage_type};
            if (!defined $t || $t eq '') {
                $bad_storage = "storage '$d->{storage}' for drive $d->{key} was not found in the cluster";
                last;
            }
            (my $volid = $d->{value}) =~ s/,.*$//;
            my $has_rename = eval { PVE::Storage::volume_has_feature($storage_cfg, 'rename', $volid) };
            if ($@ || !$has_rename) {
                $bad_storage = "drive $d->{key} no storage $d->{storage} (tipo $t) sem feature rename";
                last;
            }
        }
    }
    _check(\@checks, 'drives', ($bad_storage ? 0 : 1),
        $bad_storage || join('; ', map { "$_->{key}=$_->{kind}" } @drives) || 'sem drives');
    $info{drives} = \@drives;

    $info{original_config} = $conf;
    $info{config_digest} = _config_digest($class, $conf);
    $info{name} = $conf->{name};
    $info{ha} = $ha_entry ? $ha_entry : undef;
    $info{ha_rules} = \@ha_rules_for_vm;
    $info{replication} = \@repl_jobs;

    my $ok_all = (grep { !$_->{ok} } @checks) ? 0 : 1;
    return { ok => $ok_all, checks => \@checks, warnings => \@warnings, info => \%info };
}

# --------------------------------------------------------- espera tarefa

sub wait_task {
    my ($class, $upid, %o) = @_;
    my ($node) = $upid =~ /^UPID:([^:]+):/;
    die "invalid UPID (missing node): $upid\n" unless $node;
    my $timeout = $o{timeout} // $TASK_TIMEOUT;
    my $start = time;
    my $deadline = $start + $timeout;
    while (1) {
        $o{journal}->heartbeat_run(owner_node => hostname(), pid => getpid())
            if $o{journal};
        my ($t) = $class->_pvesh_opt(get => "/nodes/$node/tasks/$upid/status");
        if ($t && (($t->{status} // '') eq 'stopped')) {
            my $es = $t->{exitstatus} // '';
            die "task failed: $upid -> $es\n" unless $es eq 'OK';
            return 1;
        }
        if (time >= $deadline) {
            die sprintf("timeout waiting for task %s (%ds elapsed)\n", $upid, time - $start);
        }
        sleep($TASK_POLL);
    }
}

# ------------------------------------------------------------- execução

# Copia chaves de config (menos drives de volume, que já foram movidos).
# protection vai por último, em chamada separada.
sub _vm_set_config {
    my ($class, $node, $vmid, $conf, %opt) = @_;
    my %skip = map { $_ => 1 } qw(digest pending lock template vmid protection);
    my %params;
    for my $k (sort keys %{$conf || {}}) {
        next if $skip{$k};
        next if $opt{skip_drives} && ($k =~ /^(?:ide|sata|scsi|virtio)\d+$/
            || $k =~ /^unused\d+$/ || $k eq 'efidisk0' || $k eq 'tpmstate0');
        next unless defined $conf->{$k} && !ref $conf->{$k};
        $params{$k} = $conf->{$k};
    }
    $class->_config_edit($node, $vmid, %params) if %params;
    if ($opt{protection}) {
        $class->_config_edit($node, $vmid, protection => 1);
    } elsif (exists $opt{protection} && $opt{protection} == 0) {
        $class->_config_edit($node, $vmid, protection => 0);
    }
    return 1;
}

sub _step_reserve {
    my ($class, $j, $meta) = @_;
    my $tmpname = ($meta->{name} // "vm") . '-renumber';
    my $marker = $meta->{reservation_marker};
    my ($existing, $err) = $class->_pvesh_opt(
        get => "/nodes/$meta->{node}/qemu/$meta->{to}/config");
    if (!$err && $existing) {
        die "VM $meta->{to} exists but does not belong to this renumber\n"
            unless ($existing->{name} // '') eq $tmpname
                && ($existing->{description} // '') eq $marker;
        return "ID $meta->{to} was already reserved by this journal";
    }
    MMPve::Core::Runner->pvesh(create => "/nodes/$meta->{node}/qemu",
        vmid => $meta->{to}, name => $tmpname, description => $marker);
    return "ID $meta->{to} reserved (temporary name $tmpname)";
}

sub _step_move_disks {
    my ($class, $j, $meta) = @_;
    my $path = "/nodes/$meta->{node}/qemu/$meta->{from}";

    # Sempre lê a config ATUAL da VM antiga (não confia no snapshot do
    # precheck): se --resume estiver retomando depois de uma queda no meio
    # deste passo, drives que já saíram daqui não podem ser mexidos de novo
    # — RODADA2 #6.
    my ($old_conf) = $class->_pvesh_opt(get => "$path/config");
    die "could not read the current configuration of VM $meta->{from}\n" unless $old_conf;

    # protection bloqueia destroy_vm e remoção de drive
    # (PVE::QemuConfig::check_protection, chamado em destroy_vm e no delete
    # de drive/unused/vmstate do update_vm) — limpa ANTES de mexer em
    # qualquer coisa; o rollback (_undo_move_disks) restaura na antiga se
    # desfizer, e _step_config aplica na nova se concluir — RODADA2 #7.
    if ($meta->{original_config}{protection} && $old_conf->{protection}) {
        $class->_guard_source($j, $meta, step => 'move_disks/protection');
        $class->_config_edit($meta->{node}, $meta->{from}, protection => 0);
        $class->_refresh_source_digest($j, $meta, 'protection cleanup');
    }

    my $moved = 0;
    for my $d (@{$meta->{drives} || []}) {
        if ($d->{kind} eq 'cloudinit') {
            next unless exists $old_conf->{ $d->{key} };    # já removido (retomada)
            my $ci = $j->step_info('move_disks')->{cloudinit} || {};
            $ci->{$d->{key}} = $d->{value};
            $j->record('move_disks', cloudinit => $ci);
            $class->_guard_source($j, $meta, step => 'move_disks/cloudinit');
            $class->_config_edit($meta->{node}, $meta->{from}, delete => $d->{key});
            $class->_refresh_source_digest($j, $meta, 'removal of cloud-init');
            next;
        }
        next unless $d->{kind} eq 'volume';
        next unless exists $old_conf->{ $d->{key} };        # já movido (retomada)
        $class->_guard_source($j, $meta, step => 'move_disks/' . $d->{key});
        my $upid = MMPve::Core::Runner->pvesh_task(create => "$path/move_disk",
            disk => $d->{key}, 'target-vmid' => $meta->{to}, 'target-disk' => $d->{key});
        $class->wait_task($upid, journal => $j);
        $class->_refresh_source_digest($j, $meta, 'move de ' . $d->{key});
        $moved++;
    }
    return $moved ? "$moved disk(s) moved (one expected task per drive)" : 'no volume disks';
}

sub _step_config {
    my ($class, $j, $meta) = @_;
    my $conf = $meta->{original_config};
    my %params;

    # cloudinit recriado com o mesmo storage da linha original.
    my $ci = $j->step_info('move_disks')->{cloudinit} || {};
    for my $k (sort keys %$ci) {
        my ($sid) = ($ci->{$k} =~ /^([A-Za-z0-9][A-Za-z0-9_.\-]*):/);
        $params{$k} = "$sid:cloudinit" if $sid;
    }

    # Copia o resto, preservando net* (MACs), smbios1 (uuid), vmgenid.
    my %skip = map { $_ => 1 } qw(digest pending lock template vmid protection);
    my %drive_skip = map { $_->{key} => 1 } grep { $_->{kind} eq 'volume' }
        @{$meta->{drives} || []};
    for my $k (sort keys %{$conf || {}}) {
        next if $skip{$k} || $drive_skip{$k} || $ci->{$k};
        next unless defined $conf->{$k} && !ref $conf->{$k};
        $params{$k} = $conf->{$k};
    }
    $class->_guard_source($j, $meta, step => 'config');
    $class->_config_edit($meta->{node}, $meta->{to}, %params) if %params;

    # protection por último (aplicada na VM nova; a antiga já teve a dela
    # limpa no move_disks — RODADA2 #7).
    if ($conf->{protection}) {
        $class->_config_edit($meta->{node}, $meta->{to}, protection => 1);
    }
    return 'configuration copied (MACs, smbios1 UUID, and vmgenid preserved; protection last)';
}

sub _fw_path {
    my ($class, $vmid) = @_;
    return root_path("/etc/pve/firewall/$vmid.fw");
}

sub _step_firewall {
    my ($class, $j, $meta) = @_;
    my $old = $class->_fw_path($meta->{from});
    my $new = $class->_fw_path($meta->{to});
    if (-f $old) {
        my $content = read_file($old);
        $j->record('firewall', fw_content => $content);   # ANTES (rollback)
        if (-f $new) {
            die "new firewall already exists with different content\n"
                unless read_file($new) eq $content;
            return 'firewall was already copied';
        }
        $class->_guard_source($j, $meta, step => 'firewall');
        write_file_atomic($new, $content, 0644);
        return 'firewall copied';
    }
    return 'no firewall file';
}

sub _replace_vmid_list {
    my ($value, $from, $to) = @_;
    return undef if !defined($value) || ref($value);
    my @ids = split /\s*,\s*/, $value;
    return undef unless grep { $_ eq "$from" } @ids;
    my %seen;
    @ids = map { $_ eq "$from" ? "$to" : $_ } @ids;
    @ids = grep { !$seen{$_}++ } @ids;
    return join(',', @ids);
}

sub _acl_args {
    my ($class, $path, $a) = @_;
    my %args = (path => $path, roles => $a->{roleid}, propagate => $a->{propagate} // 0);
    my $t = $a->{type} // 'user';
    if    ($t eq 'token') { $args{tokens} = $a->{ugid} }
    elsif ($t eq 'group') { $args{groups} = $a->{ugid} }
    else                  { $args{users}  = $a->{ugid} }
    return \%args;
}

sub _step_refs {
    my ($class, $j, $meta) = @_;
    my ($from, $to) = @{$meta}{qw(from to)};
    my @done;
    my @pool_changes;

    my ($pools) = $class->_pvesh_opt(get => '/pools');
    for my $p (@{$pools || []}) {
        my $pname = $p->{poolid} // next;
        my ($pd) = $class->_pvesh_opt(get => "/pools/$pname");
        my @members = map { $_->{vmid} } grep { ($_->{id} // '') =~ /^qemu\// }
            @{$pd->{members} || []};
        next unless grep { $_ == $from } @members;
        push @pool_changes, { pool => $pname, old_member => 1 };
        next if grep { $_ == $to } @members;
        $class->_guard_source($j, $meta, step => "refs/pool/$pname");
        MMPve::Core::Runner->pvesh(set => "/pools/$pname", vms => $to);
        push @done, "pool $pname";
    }
    $j->record('refs', pool_changes => \@pool_changes) if @pool_changes;

    my ($acls) = $class->_pvesh_opt(get => '/access/acl');
    my @mine = grep { ($_->{path} // '') eq "/vms/$from" } @{$acls || []};
    my @acl_changes;
    for my $a (@mine) {
        my $new_args = $class->_acl_args("/vms/$to", $a);
        my $old_args = $class->_acl_args("/vms/$from", $a);
        push @acl_changes, { original => { %$a }, new_args => $new_args, old_args => $old_args };
        my $already = grep {
            ($_->{path} // '') eq "/vms/$to" && ($_->{ugid} // '') eq ($a->{ugid} // '')
                && ($_->{type} // 'user') eq ($a->{type} // 'user')
                && ($_->{roleid} // '') eq ($a->{roleid} // '')
        } @{$acls || []};
        if (!$already) {
            $class->_guard_source($j, $meta, step => 'refs/acl-create');
            MMPve::Core::Runner->pvesh(set => '/access/acl', %$new_args);
        }
        $class->_guard_source($j, $meta, step => 'refs/acl-delete');
        MMPve::Core::Runner->pvesh(delete => '/access/acl', %$old_args);
    }
    $j->record('refs', acl_changes => \@acl_changes) if @acl_changes;
    push @done, scalar(@acl_changes) . ' ACL(s)' if @acl_changes;

    my ($jobs) = $class->_pvesh_opt(get => '/cluster/backup');
    my @backup_changes;
    for my $jb (@{$jobs || []}) {
        for my $field (qw(vmid exclude)) {
            my $old_value = $jb->{$field};
            my $new_value = _replace_vmid_list($old_value, $from, $to);
            next unless defined $new_value;
            push @backup_changes, { id => $jb->{id}, field => $field, value => $old_value };
            next if $old_value eq $new_value;
            $class->_guard_source($j, $meta, step => "refs/backup/$jb->{id}/$field");
            MMPve::Core::Runner->pvesh(set => "/cluster/backup/$jb->{id}", $field => $new_value);
        }
    }
    $j->record('refs', backups => \@backup_changes) if @backup_changes;
    push @done, scalar(@backup_changes) . ' backup field(s)' if @backup_changes;

    if ($meta->{ha} && $meta->{handle_ha}) {
        my $h = $meta->{ha};
        $j->record('refs', ha => { original => { %$h }, old_sid => "vm:$from", new_sid => "vm:$to" });
        my ($current) = $class->_pvesh_opt(get => '/cluster/ha/resources');
        my ($old) = grep { ($_->{sid} // '') eq "vm:$from" } @{$current || []};
        my ($new) = grep { ($_->{sid} // '') eq "vm:$to" } @{$current || []};
        if ($old && !$new) {
            $class->_guard_source($j, $meta, step => 'refs/ha-delete');
            MMPve::Core::Runner->pvesh(delete => "/cluster/ha/resources/vm:$from");
        }
        if (!$new) {
            $class->_guard_source($j, $meta, step => 'refs/ha-create');
            MMPve::Core::Runner->pvesh(create => '/cluster/ha/resources', sid => "vm:$to");
        }
        my %extra;
        $extra{state} = $h->{state} if defined $h->{state} && $h->{state} ne 'started';
        $extra{comment} = $h->{comment} if defined $h->{comment} && length $h->{comment};
        if (%extra) {
            $class->_guard_source($j, $meta, step => 'refs/ha-set');
            MMPve::Core::Runner->pvesh(set => "/cluster/ha/resources/vm:$to", %extra);
        }
        push @done, "HA resource vm:$from -> vm:$to";
    }

    my @rule_changes;
    for my $r (@{$meta->{ha_rules} || []}) {
        my $old_resources = $r->{resources} // '';
        my $new_resources = $old_resources;
        $new_resources =~ s/\bvm:\Q$from\E\b/vm:$to/g;
        next if $new_resources eq $old_resources;
        push @rule_changes, { rule => $r->{rule}, resources => $old_resources };
        $class->_guard_source($j, $meta, step => 'refs/ha-rule');
        MMPve::Core::Runner->pvesh(set => "/cluster/ha/rules/$r->{rule}", resources => $new_resources);
    }
    $j->record('refs', ha_rules => \@rule_changes) if @rule_changes;
    push @done, scalar(@rule_changes) . ' HA rule(s)' if @rule_changes;

    if ($meta->{handle_replication} && @{$meta->{replication} || []}) {
        my @new_jobs;
        my ($current) = $class->_pvesh_opt(get => '/cluster/replication');
        for my $r (@{$meta->{replication}}) {
            my $new_id = "$to-$r->{jobnum}";
            my ($old) = grep { ($_->{id} // '') eq $r->{id} } @{$current || []};
            my ($new) = grep { ($_->{id} // '') eq $new_id } @{$current || []};
            push @new_jobs, { old_id => $r->{id}, new_id => $new_id, original => { %$r } };
            if ($old && !$new) {
                $class->_guard_source($j, $meta, step => "refs/replication-delete/$r->{id}");
                MMPve::Core::Runner->pvesh(delete => "/cluster/replication/$r->{id}");
            }
            next if $new;
            my %args = (id => $new_id);
            $args{$_} = $r->{$_} for grep { exists $r->{$_} }
                qw(comment disable rate schedule source target type);
            $class->_guard_source($j, $meta, step => "refs/replication-create/$new_id");
            MMPve::Core::Runner->pvesh(create => '/cluster/replication', %args);
        }
        $j->record('refs', replication => \@new_jobs);
        push @done, scalar(@new_jobs) . ' replication job(s) preserved';
    }

    return @done ? join('; ', @done) : 'no external references';
}

sub _config_volumes {
    my ($class, $conf) = @_;
    my @vols;
    for my $k (sort keys %{$conf || {}}) {
        next unless $k =~ /^(?:ide|sata|scsi|virtio)\d+$/
            || $k =~ /^unused\d+$/ || $k eq 'efidisk0' || $k eq 'tpmstate0';
        push @vols, "$k=$conf->{$k}"
            if defined $conf->{$k} && $conf->{$k} =~ $VOLID_RE;
    }
    return @vols;
}

sub _step_verify {
    my ($class, $j, $meta) = @_;
    my ($conf) = $class->_pvesh_opt(get => "/nodes/$meta->{node}/qemu/$meta->{from}/config");
    my @left = $class->_config_volumes($conf);
    die "old VM still has volumes: " . join(', ', @left) . "\n" if @left;
    return 'old VM has no volumes';
}

sub _step_destroy {
    my ($class, $j, $meta) = @_;
    my ($destroy_status, $destroy_conf, $exists) = $class->_source_snapshot($meta);
    return "VM $meta->{from} was already deleted" unless $exists;
    my (undef, $conf) = $class->_guard_source($j, $meta, step => 'destroy');
    # --purge apaga todo volume que ainda estiver na config: confere de novo,
    # logo antes, que os discos saíram da VM antiga e que a nova existe.
    my @left = $class->_config_volumes($conf);
    die "destroy refused: old VM still has volumes: " . join(', ', @left) . "\n"
        if @left;
    my ($new_conf) = $class->_pvesh_opt(get => "/nodes/$meta->{node}/qemu/$meta->{to}/config");
    die "destroy refused: new VM $meta->{to} does not exist on node $meta->{node}\n"
        unless $new_conf;
    MMPve::Core::Runner->pvesh(delete => "/nodes/$meta->{node}/qemu/$meta->{from}",
        purge => 1, 'destroy-unreferenced-disks' => 0);
    return "VM $meta->{from} deleted (purge; disks already moved)";
}

my %STEP_IMPL = (
    reserve     => \&_step_reserve,
    move_disks  => \&_step_move_disks,
    config      => \&_step_config,
    firewall    => \&_step_firewall,
    refs        => \&_step_refs,
    verify      => \&_step_verify,
    destroy     => \&_step_destroy,
);

my %STEP_DESC = (
    reserve     => 'reserve the new ID (qemu create)',
    move_disks  => 'move disks (move_disk per drive, waiting for the task)',
    config      => 'copy the remaining configuration (MACs/smbios1/vmgenid; protection last)',
    firewall    => 'copy /etc/pve/firewall/<old>.fw to <new>.fw',
    refs        => 'pool, ACLs /vms/<id>, backup jobs, HA, and replication',
    verify      => 'verify that the old VM has no volumes',
    destroy     => 'delete the old VM (--purge 1 --destroy-unreferenced-disks 0)',
);

sub plan {
    my ($class) = @_;
    return map { +{ step => $_, description => $STEP_DESC{$_} } } @STEPS;
}

sub run {
    my ($class, %o) = @_;
    my $pre = $class->precheck(%o);
    if (!$pre->{ok}) {
        return { ok => 0, phase => 'precheck', checks => $pre->{checks}, warnings => $pre->{warnings} };
    }
    my %meta = (
        from => $o{from}, to => $o{to},
        node => $pre->{info}{node},
        name => $pre->{info}{name},
        drives => $pre->{info}{drives},
        original_config => $pre->{info}{original_config},
        config_digest => $pre->{info}{config_digest},
        ha => $pre->{info}{ha},
        ha_rules => $pre->{info}{ha_rules},
        replication => $pre->{info}{replication},
        handle_ha => $o{handle_ha} ? 1 : 0,
        handle_replication => $o{handle_replication} ? 1 : 0,
    );
    my $id = $class->journal_id($o{from}, $o{to});
    $meta{reservation_marker} = "mm-pve-tools renumber $id";
    # journal inacabado só continua por --resume/--rollback (o precheck já
    # recusa; isto cobre quem chegar aqui sem ele). Journal concluído = nova
    # operação do zero.
    if (my $pending = $class->_pending_journal($o{from}, $o{to})) {
        die "$pending\n";
    }
    my $j = MMPve::Journal->create($id, %meta);
    $j->steps([@STEPS]);
    $j->set_state('running');
    return $class->_with_run_marker($j, sub {
        my %jmeta = %{$j->meta};
        return $class->_exec_steps($j, \%jmeta);
    });
}

sub _with_run_marker {
    my ($class, $j, $code) = @_;
    $j->claim_run(owner_node => hostname(), pid => getpid(), ttl => $RUN_MARKER_TTL);
    my ($out, $ok);
    $ok = eval { $out = $code->(); 1 };
    my $err = $@;
    my $release_err = eval { $j->release_run(owner_node => hostname(), pid => getpid()); $@ };
    die $err unless $ok;
    die $release_err if $release_err;
    return $out;
}

sub _exec_steps {
    my ($class, $j, $meta) = @_;
    my ($from, $to) = ($meta->{from}, $meta->{to});
    for my $s ($j->steps) {
        my $st = $j->step_info($s)->{status} // 'pending';
        next if $st eq 'done';
        $j->mark_running($s);                          # ANTES
        my $detail = eval {
            $class->_before_step($j, $meta, $s);
            $STEP_IMPL{$s}->($class, $j, $meta);
        };
        if (my $err = $@) {
            chomp $err;
            $j->mark_failed($s, $err);
            log_line("renumber $from>$to FAILED at step $s: $err");
            die "$err\nStep '$s' failed.\nContinue with: mm-pve renumber --resume --from $from --to $to\n";
        }
        $class->_refresh_source_digest($j, $meta, "passo $s")
            if $s ne 'destroy';
        $j->set_meta(config_digest => $meta->{config_digest});
        $j->mark_done($s);                             # DEPOIS
        print "renumber: step $s ok - $detail\n";
        $class->_maybe_fail_after($s);
    }
    $j->finish({
        from => $from, to => $to, node => $meta->{node},
        note => 'PBS backup history remains in group vm/' . $from
            . ' (it is removed only by a PBS prune job); do not modify old backups.',
    });
    return {
        ok => 1, from => $from, to => $to, node => $meta->{node}, steps => [@STEPS],
        summary => "VM $from > $to completed. Reminder: PBS backup history "
            . "remains in group vm/$from (it is removed only by a PBS prune job); "
            . "old backups must not be modified.",
    };
}

sub resume {
    my ($class, %o) = @_;
    my $id = $o{id} // $class->journal_id($o{from}, $o{to});
    my $j = eval { MMPve::Journal->open($id) };
    die "journal $id not found.\nUse: mm-pve renumber --from <old> --to <new>\n" if $@ || !$j;
    my %meta = (%{$j->meta},
        (defined $o{handle_ha} ? (handle_ha => $o{handle_ha}) : ()),
        (defined $o{handle_replication} ? (handle_replication => $o{handle_replication}) : ()));
    die "journal has no from/to.\n" unless $meta{from} && $meta{to};
    my $next = $j->first_pending;
    die "nothing pending in journal $id (state: " . $j->state . ").\n"
        if !$next && ($j->state // '') eq 'finished';
    print "renumber: resuming at step '$next'\n" if $next;
    $j->set_state('running');
    return $class->_with_run_marker($j, sub { $class->_exec_steps($j, \%meta) });
}

# ------------------------------------------------------------- rollback

sub _undo_verify { return 'nothing to undo (verification)' }

sub _undo_refs {
    my ($class, $j, $meta) = @_;
    my $info = $j->step_info('refs');

    for my $p (@{$info->{pool_changes} || []}) {
        my ($pd) = $class->_pvesh_opt(get => "/pools/$p->{pool}");
        my $has_new = grep { ($_->{vmid} // '') == $meta->{to} } @{$pd->{members} || []};
        if ($has_new) {
            $class->_guard_source($j, $meta, step => 'rollback/pool-delete');
            MMPve::Core::Runner->pvesh(set => "/pools/$p->{pool}",
                vms => $meta->{to}, delete => 1);
        }
        my $has_old = grep { ($_->{vmid} // '') == $meta->{from} } @{$pd->{members} || []};
        if ($p->{old_member} && !$has_old) {
            $class->_guard_source($j, $meta, step => 'rollback/pool-restore');
            MMPve::Core::Runner->pvesh(set => "/pools/$p->{pool}", vms => $meta->{from});
        }
    }

    my ($acls) = $class->_pvesh_opt(get => '/access/acl');
    for my $a (@{$info->{acl_changes} || []}) {
        my $old = $a->{original};
        my $new_args = $a->{new_args};
        my $new_exists = grep {
            ($_->{path} // '') eq ($new_args->{path} // '')
                && ($_->{ugid} // '') eq ($old->{ugid} // '')
                && ($_->{type} // 'user') eq ($old->{type} // 'user')
        } @{$acls || []};
        if ($new_exists) {
            $class->_guard_source($j, $meta, step => 'rollback/acl-delete');
            MMPve::Core::Runner->pvesh(delete => '/access/acl', %$new_args);
        }
        my $old_exists = grep {
            ($_->{path} // '') eq "/vms/$meta->{from}" && ($_->{ugid} // '') eq ($old->{ugid} // '')
                && ($_->{type} // 'user') eq ($old->{type} // 'user')
        } @{$acls || []};
        if (!$old_exists) {
            $class->_guard_source($j, $meta, step => 'rollback/acl-restore');
            MMPve::Core::Runner->pvesh(set => '/access/acl', %{$a->{old_args}});
        }
    }

    for my $b (@{$info->{backups} || []}) {
        $class->_guard_source($j, $meta, step => 'rollback/backup');
        MMPve::Core::Runner->pvesh(set => "/cluster/backup/$b->{id}", $b->{field} => $b->{value});
    }

    if (my $hinfo = $info->{ha}) {
        $class->_guard_source($j, $meta, step => 'rollback/ha-delete');
        MMPve::Core::Runner->pvesh(delete => "/cluster/ha/resources/$hinfo->{new_sid}");
        $class->_guard_source($j, $meta, step => 'rollback/ha-create');
        MMPve::Core::Runner->pvesh(create => '/cluster/ha/resources', sid => $hinfo->{old_sid});
        my %extra;
        my $h = $hinfo->{original} || {};
        $extra{state} = $h->{state} if defined $h->{state} && $h->{state} ne 'started';
        $extra{comment} = $h->{comment} if defined $h->{comment} && length $h->{comment};
        if (%extra) {
            $class->_guard_source($j, $meta, step => 'rollback/ha-set');
            MMPve::Core::Runner->pvesh(set => "/cluster/ha/resources/$hinfo->{old_sid}", %extra);
        }
    }
    for my $r (@{$info->{ha_rules} || []}) {
        $class->_guard_source($j, $meta, step => 'rollback/ha-rule');
        MMPve::Core::Runner->pvesh(set => "/cluster/ha/rules/$r->{rule}", resources => $r->{resources});
    }

    for my $pair (@{$info->{replication} || []}) {
        $class->_guard_source($j, $meta, step => 'rollback/replication-delete');
        MMPve::Core::Runner->pvesh(delete => "/cluster/replication/$pair->{new_id}");
        my $old = $pair->{original} || {};
        my %args = (id => $old->{id});
        $args{$_} = $old->{$_} for grep { exists $old->{$_} }
            qw(comment disable rate schedule source target type);
        $class->_guard_source($j, $meta, step => 'rollback/replication-create');
        MMPve::Core::Runner->pvesh(create => '/cluster/replication', %args);
    }
    return 'references reverted';
}

sub _undo_firewall {
    my ($class, $j, $meta) = @_;
    $class->_guard_source($j, $meta, step => 'rollback/firewall');
    my $content = $j->step_info('firewall')->{fw_content};
    if (defined $content) {
        write_file_atomic($class->_fw_path($meta->{from}), $content, 0644);
    }
    my $new = $class->_fw_path($meta->{to});
    unlink $new if -f $new;
    return 'firewall restored';
}

sub _undo_config { return 'new VM configuration is removed with it when undoing reserve' }

# Desfaz move_disks com base no estado REAL das VMs, não no journal: o
# processo pode ter morrido no meio deste passo (sem marcar nem 'done' nem
# 'failed'), então o número de discos efetivamente movidos só dá pra saber
# lendo a config atual da VM nova — RODADA2 #5/#6.
sub _undo_move_disks {
    my ($class, $j, $meta) = @_;
    my ($from, $to, $node) = @{$meta}{qw(from to node)};
    my $new_path = "/nodes/$node/qemu/$to";
    my $old_path = "/nodes/$node/qemu/$from";

    my ($new_conf) = $class->_pvesh_opt(get => "$new_path/config");
    $new_conf //= {};
    my ($storages) = $class->_pvesh_opt(get => '/storage');
    my %storage_types = map { ($_->{storage} // '') => ($_->{type} // '') } @{$storages || []};
    my @on_new = reverse grep { $_->{kind} eq 'volume' }
        $class->_classify_drives($new_conf, \%storage_types);

    for my $d (@on_new) {
        $class->_guard_source($j, $meta, step => 'rollback/move-disks/' . $d->{key});
        my $upid = MMPve::Core::Runner->pvesh_task(create => "$new_path/move_disk",
            disk => $d->{key}, 'target-vmid' => $from, 'target-disk' => $d->{key});
        $class->wait_task($upid);
        $class->_refresh_source_digest($j, $meta, 'return of ' . $d->{key});
    }

    # devolve o resto da configuração original (MACs/smbios1/vmgenid) e a
    # proteção, se tinha sido limpa antes de mover (ver _step_move_disks).
    $class->_guard_source($j, $meta, step => 'rollback/move-disks');
    $class->_vm_set_config($node, $from, $meta->{original_config},
        skip_drives => 1);
    $class->_refresh_source_digest($j, $meta, 'restore of configuration without volumes');
    if ($meta->{original_config}{protection}) {
        $class->_guard_source($j, $meta, step => 'rollback/protection');
        $class->_config_edit($node, $from, protection => 1);
        $class->_refresh_source_digest($j, $meta, 'restore of protection');
    }

    # cloudinit: se já tinha sido removido da antiga, recria a linha
    # original (storage preservado, ver _step_config).
    my $ci = $j->step_info('move_disks')->{cloudinit} || {};
    if (%$ci) {
        my %restore_ci;
        for my $key (keys %$ci) {
            my ($sid) = ($ci->{$key} =~ /^([A-Za-z0-9][A-Za-z0-9_.\-]*):/);
            $restore_ci{$key} = "$sid:cloudinit" if $sid;
        }
        $class->_guard_source($j, $meta, step => 'rollback/cloudinit');
        $class->_config_edit($node, $from, %restore_ci);
        $class->_refresh_source_digest($j, $meta, 'recreation of cloud-init');
    }

    return @on_new
        ? scalar(@on_new) . ' disk(s) returned to the old VM (verified in the new VM configuration)'
        : 'no disk was on the new VM (nothing to return)';
}

# Só apaga a VM nova depois de confirmar (na config real) que não sobrou
# nenhum volume nela — NUNCA com purge/destroy-unreferenced-disks=1, senão
# um disco já devolvido (ou ainda não conferido) seria destruído de vez —
# RODADA2 #5.
sub _undo_reserve {
    my ($class, $j, $meta) = @_;
    my $path = "/nodes/$meta->{node}/qemu/$meta->{to}";

    my ($conf) = $class->_pvesh_opt(get => "$path/config");
    return "new VM $meta->{to} no longer exists" unless $conf;
    if ($conf) {
        my ($storages) = $class->_pvesh_opt(get => '/storage');
        my %storage_types = map { ($_->{storage} // '') => ($_->{type} // '') } @{$storages || []};
        my @left = grep { $_->{kind} eq 'volume' } $class->_classify_drives($conf, \%storage_types);
        if (@left) {
            die "new VM $meta->{to} still has " . scalar(@left) . " disk(s) ("
                . join(', ', map { $_->{key} } @left) . "); not deleted"
                . " (risk of data loss) - resolve manually and run --rollback again.\n";
        }
    }
    $class->_guard_source($j, $meta, step => 'rollback/reserve');
    MMPve::Core::Runner->pvesh(delete => $path, 'destroy-unreferenced-disks' => 0);
    return "new VM $meta->{to} deleted (no disks; no purge or destroy-unreferenced-disks)";
}

my %UNDO_IMPL = (
    reserve    => \&_undo_reserve,
    move_disks => \&_undo_move_disks,
    config     => \&_undo_config,
    firewall   => \&_undo_firewall,
    refs       => \&_undo_refs,
    verify     => \&_undo_verify,
    destroy    => sub { die "rollback refused: destroy step is already complete\n" },
);

sub rollback {
    my ($class, %o) = @_;
    my $id = $o{id} // $class->journal_id($o{from}, $o{to});
    my $j = eval { MMPve::Journal->open($id) };
    die "journal $id not found.\n" if $@ || !$j;
    my %meta = %{$j->meta};
    die "journal has no from/to.\n" unless $meta{from} && $meta{to};

    my $destroy_state = $j->step_info('destroy')->{status} // '';
    if ($destroy_state eq 'done') {
        die "rollback refused: destroy step is complete; the run is finished\n";
    }
    if ($destroy_state =~ /^(?:running|failed)$/) {
        my ($destroy_status, $destroy_conf, $exists) = $class->_source_snapshot(\%meta);
        die "rollback refused: destroy completed; the run must be resumed\n"
            unless $exists;
    }

    my @done = $j->done_steps;
    # reserve/move_disks são tratados à parte (sempre, se 'reserve' chegou a
    # 'done'): o processo pode ter morrido no meio do move_disks sem o
    # journal marcar 'done' nem 'failed' nesse passo, e nesse caso confiar
    # só na lista de passos 'done' do journal perderia disco (RODADA2 #5).
    my @touched = grep {
        my $status = $j->step_info($_)->{status} // '';
        $status =~ /^(?:done|running|failed)$/ && !$j->step_info($_)->{undone}
    } $j->steps;
    my $reserve_touched = grep { $_ eq 'reserve' } @touched;
    my $move_touched = grep { $_ eq 'move_disks' } @touched;
    my @other_undo = reverse grep {
        $_ ne 'reserve' && $_ ne 'move_disks' && $_ ne 'destroy'
    } @touched;

    die "no completed step to undo (state: " . $j->state . ").\n"
        unless $reserve_touched || $move_touched || @other_undo;

    my @undone;
    my $run_undo = sub {
        my ($step, $code) = @_;
        print "renumber: undoing '$step'\n";
        my $detail = eval { $code->() };
        if (my $err = $@) {
            chomp $err;
            $j->set_state('rollback-failed');
            die "$err\nUndoing '$step' failed.\n"
                . "Continue with: mm-pve renumber --rollback --from $meta{from} --to $meta{to}\n";
        }
        $j->record($step, undone => 1);
        push @undone, $step;
        return;
    };

    return $class->_with_run_marker($j, sub {
        for my $s (@other_undo) {
            $run_undo->($s, sub { $UNDO_IMPL{$s}->($class, $j, \%meta) });
        }
        if ($move_touched) {
            $run_undo->('move_disks', sub { $class->_undo_move_disks($j, \%meta) });
        }
        if ($reserve_touched) {
            $run_undo->('reserve',    sub { $class->_undo_reserve($j, \%meta) });
        }

        $j->finish({ rolled_back => 1, from => $meta{from}, to => $meta{to} });
        return { ok => 1, undone => \@undone };
    });
}

# ------------------------------------------------------------- módulo/CLI

sub validate_section { return () }    # vmid_scheme já validado pelo núcleo

sub apply  { return { ok => 1, changed => 0, message => 'renumber has no per-node state; use mm-pve renumber --from X --to Y' } }
sub revert { return { ok => 1, changed => 0, message => 'renumber: nothing to revert' } }
sub check  {
    my ($c, $cfg) = @_;
    return {
        ok => 1,
        vmid_scheme => $cfg->{vmid_scheme} // [],
        note => 'renumber is an on-demand operation (precheck + journal)',
    };
}

sub cli {
    my ($class, $argv) = @_;
    my ($from, $to, $node, $dry, $resume, $rollback, $force, $hha, $hrep, $json, $id, $help);
    local @ARGV = @{$argv};
    require Getopt::Long;
    Getopt::Long::GetOptions(
        'from=i'             => \$from,
        'to=i'               => \$to,
        'node=s'             => \$node,
        'dry-run'            => \$dry,
        'resume'             => \$resume,
        'rollback'           => \$rollback,
        'force-scheme'       => \$force,
        'handle-ha'          => \$hha,
        'handle-replication' => \$hrep,
        'id=s'               => \$id,
        'json'               => \$json,
        'help|h'             => \$help,
    ) or do { print STDERR "invalid usage (mm-pve renumber --help)\n"; return 2 };

    if ($help) {
        print <<'EOF';
mm-pve renumber - change a VMID using move_disk

usage:
  mm-pve renumber --from <old> --to <new> [options]
  mm-pve renumber --resume   --from <old> --to <new>   (or --id <journal>)
  mm-pve renumber --rollback --from <old> --to <new>   (or --id <journal>)

options:
  --node <n>               VM node (default: locate in the cluster)
  --dry-run                show the plan (precheck + steps), execute nothing
  --force-scheme           continue when the new ID is outside vmid_scheme
  --handle-ha              remove and recreate the HA resource with the new ID
  --handle-replication     remove and recreate replication (full sync) with the new ID
  MM_RENUMBER_FAIL_AFTER=step  (tests/lab only; stop after the step)
  --json                   JSON output
EOF
        return 0;
    }

    my %o = (
        from => $from, to => $to,
        (defined $node ? (node => $node) : ()),
        force_scheme => $force, handle_ha => $hha, handle_replication => $hrep,
    );

    my $dump = sub {
        my ($res) = @_;
        return if $json;
        if ($res->{checks}) {
            printf "%s %-22s %s\n", ($_->{ok} ? 'OK' : 'FAIL'), $_->{check}, $_->{detail}
                for @{$res->{checks}};
        }
        print "WARNING: $_\n" for @{$res->{warnings} || []};
    };

    if ($rollback) {
        my $res = eval { $class->rollback(id => $id, from => $from, to => $to) };
        if (my $err = $@) {
            chomp $err; print STDERR "ERROR: $err\n";
            print STDERR "Continue with: mm-pve renumber --rollback --from $from --to $to\n" if $from && $to;
            return 1;
        }
        print json_encode($res, pretty => 1), "\n" if $json;
        print "rollback completed (steps: @{$res->{undone}})\n" unless $json;
        return 0;
    }

    if ($resume) {
        my $res = eval {
            $class->resume(id => $id, from => $from, to => $to,
                handle_ha => $hha, handle_replication => $hrep);
        };
        if (my $err = $@) {
            chomp $err; print STDERR "ERROR: $err\n";
            print STDERR "Continue with: mm-pve renumber --resume --from $from --to $to\n" if $from && $to;
            return 1;
        }
        print json_encode($res, pretty => 1), "\n" if $json;
        print $res->{summary}, "\n" unless $json;
        return 0;
    }

    unless (defined $from && defined $to) {
        print STDERR "usage: mm-pve renumber --from <old> --to <new> [--dry-run|--resume|--rollback] [options]\n";
        return 2;
    }

    my $pre = $class->precheck(%o);
    $dump->($pre);
    if (!$pre->{ok}) {
        print STDERR "ERROR: precheck failed; nothing was changed.\n";
        print json_encode({ ok => 0, phase => 'precheck', %$pre }, pretty => 1), "\n" if $json;
        return 1;
    }

    if ($dry) {
        my @steps = map { "$_->{step}: $_->{description}" } $class->plan;
        my $res = {
            ok => 1, dry_run => 1,
            from => $from, to => $to, node => $pre->{info}{node},
            steps => \@steps,
            drives => [ map { "$_->{key}=$_->{kind}" } @{$pre->{info}{drives}} ],
        };
        print json_encode($res, pretty => 1), "\n" if $json;
        print "PLAN (dry-run, nothing executed):\n  $_\n" for @steps;
        return 0;
    }

    my $res = eval { $class->run(%o) };
    if (my $err = $@) {
        chomp $err; print STDERR "ERROR: $err\n";
        return 1;
    }
    if (!$res->{ok}) {
        print STDERR "ERROR: precheck failed; nothing was changed.\n";
        print json_encode({ ok => 0, %$res }, pretty => 1), "\n" if $json;
        return 1;
    }
    print json_encode($res, pretty => 1), "\n" if $json;
    print $res->{summary}, "\n" unless $json;
    return 0;
}

1;

__END__

=head1 NAME

MMPve::Module::Renumber — troca de VMID via move_disk

=head1 DESCRIPTION

Implementa o plano "Módulo renumber": precheck somente-leitura, execução em
passos com journal (reserve → move_disks → config → firewall → refs → verify
→ destroy), --dry-run/--resume/--rollback. Toda saída para o cluster passa
por MMPve::Core::Runner (pvesh).
