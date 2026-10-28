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
use MMPve::Core::Util qw(read_file write_file_atomic root_path log_line);

our $VERSION = '0.1.0';

# Espera de tarefa pvesh (testes reduzem o intervalo).
our $TASK_POLL    = 2;      # segundos entre consultas a /cluster/tasks
our $TASK_TIMEOUT = 21600;  # 6h por tarefa (move_disk de disco grande demora)

# Tipos de storage com suporte a rename de volume (feature "rename" do
# plugin). Block storage sem rename (iscsi, lvm, rbd, ...) recusa.
my %RENAME_OK = map { $_ => 1 } qw(
    dir zfspool lvmthin nfs cifs glusterfs cephfs fuse
);

my @STEPS = qw(reserve move_disks config firewall refs verify destroy);

# ------------------------------------------------------------- helpers

sub _vmid_ok { return defined $_[0] && $_[0] =~ /^\d+$/ && $_[0] >= 100 && $_[0] <= 9999999 }

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
        } elsif ($v =~ /^([A-Za-z0-9][A-Za-z0-9_.\-]*):(vm|base)-\d+-/) {
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
    return "ID $to fora do esquema configurado (faixas: " . join(', ', @labels) . ")";
}

sub journal_id {
    my ($class, $from, $to) = @_;
    return "renumber-$from-$to";
}

# ------------------------------------------------------------- precheck

sub precheck {
    my ($class, %o) = @_;
    my ($from, $to) = ($o{from}, $o{to});
    my @checks;
    my @warnings;
    my %info;

    if (!_vmid_ok($from) || !_vmid_ok($to)) {
        _check(\@checks, 'ids', 0, '--from e --to precisam ser inteiros 100..9999999');
        return { ok => 0, checks => \@checks, warnings => \@warnings, info => \%info };
    }
    _check(\@checks, 'ids-diferentes', ($from != $to ? 1 : 0),
        $from == $to ? 'ID novo é igual ao antigo' : 'ok');

    # 1. ID novo livre (GET /cluster/nextid --vmid dá erro se em uso).
    my ($next) = $class->_pvesh_opt(get => '/cluster/nextid', vmid => $to);
    _check(\@checks, 'id-novo-livre', ($next ? 1 : 0),
        $next ? "livre (nextid sugeriria $next)" : "ID $to já está em uso");

    # 2. Esquema de VMID.
    my $sw = $class->_scheme_warning($to);
    if ($sw) {
        push @warnings, $sw;
        _check(\@checks, 'esquema', ($o{force_scheme} ? 1 : 0),
            "$sw (use --force-scheme para forçar)", 1);
    } else {
        _check(\@checks, 'esquema', 1, 'dentro do esquema configurado (ou sem esquema)');
    }

    # Localizar a VM.
    my $node = $o{node} // ($class->_find_node($from) // '');
    $info{node} = $node;
    _check(\@checks, 'vm-existe', ($node ? 1 : 0),
        $node ? "VM $from no node $node" : ("VM $from não encontrada"
            . ($o{node} ? " no node $o{node}" : ' no cluster')));

    my $ok = (grep { !$_->{ok} } @checks) ? 0 : 1;
    return { ok => 0, checks => \@checks, warnings => \@warnings, info => \%info } if !$ok;

    # 3. Volumes órfãos vm-<novo>-*/base-<novo>-* em storages com images/rootdir.
    my ($nodes) = $class->_pvesh_opt(get => '/cluster/status');
    my @online = grep { ($_->{type} // '') eq 'node' && $_->{online} } @{$nodes || []};
    my %shared_seen;    # storage compartilhado: consulta 1x
    my $orphan_detail = '';
    for my $n (@online) {
        my ($st) = $class->_pvesh_opt(get => "/nodes/$n->{name}/storage");
        for my $s (@{$st || []}) {
            next unless ($s->{enabled} // 1);
            my @content = split(/,/, $s->{content} // '');
            next unless grep { $_ eq 'images' || $_ eq 'rootdir' } @content;
            my $sid = $s->{storage};
            next if ($s->{shared} ? 1 : 0) && $shared_seen{$sid}++;
            my ($content) = $class->_pvesh_opt(get => "/nodes/$n->{name}/storage/$sid/content", vmid => $to);
            if ($content && @{$content}) {
                $orphan_detail = "storage $sid já tem " . scalar(@{$content})
                    . " volume(s) do ID $to (" . join(', ', map { $_->{volid} // '?' } @{$content}) . ")";
                last;
            }
        }
        last if $orphan_detail;
    }
    _check(\@checks, 'sem-volumes-orfaos', ($orphan_detail ? 0 : 1),
        $orphan_detail || "nenhum volume vm-$to-* / base-$to-* em storage de images/rootdir");

    # 4. Estado da VM de origem.
    my $vmpath = "/nodes/$node/qemu/$from";
    my ($vmstat) = $class->_pvesh_opt(get => $vmpath);
    my ($conf) = $class->_pvesh_opt(get => "$vmpath/config");
    _check(\@checks, 'config-legivel', ($conf ? 1 : 0),
        $conf ? 'ok' : 'não consegui ler a configuração da VM');
    return { ok => 0, checks => \@checks, warnings => \@warnings, info => \%info } if !$conf;

    my $status = $vmstat->{status} // '?';
    _check(\@checks, 'desligada', ($status eq 'stopped' ? 1 : 0),
        "status: $status" . ($status eq 'stopped' ? '' : ' (precisa estar desligada)'));
    my $lock = $vmstat->{lock} // $conf->{lock};
    _check(\@checks, 'sem-lock', ($lock ? 0 : 1), $lock ? "lock: $lock" : 'sem lock');
    _check(\@checks, 'nao-template', ($conf->{template} ? 0 : 1),
        $conf->{template} ? 'é template' : 'não é template');

    my ($snaps) = $class->_pvesh_opt(get => "$vmpath/snapshot");
    my @extra_snaps = grep { ($_->{name} // '') ne 'current' } @{$snaps || []};
    _check(\@checks, 'sem-snapshots', (@extra_snaps ? 0 : 1),
        @extra_snaps ? 'snapshots: ' . join(', ', map { $_->{name} } @extra_snaps) : 'só current');

    my ($pending) = $class->_pvesh_opt(get => "$vmpath/pending");
    _check(\@checks, 'sem-pending', (@{$pending || []} ? 0 : 1),
        @{$pending || []} ? scalar(@{$pending}) . ' mudança(ões) pendente(s)' : 'sem alterações pendentes');

    # 5. HA e replicação.
    my ($ha) = $class->_pvesh_opt(get => '/cluster/ha/resources');
    my ($ha_entry) = grep { ($_->{sid} // '') eq "vmid:$from" } @{$ha || []};
    if ($ha_entry) {
        if ($o{handle_ha}) {
            push @warnings, 'VM está no HA: será removida e recriada com o novo ID (--handle-ha)';
            _check(\@checks, 'ha', 1, 'no HA — tratado com --handle-ha', 1);
        } else {
            _check(\@checks, 'ha', 0, 'VM está no HA (use --handle-ha)');
        }
    } else {
        _check(\@checks, 'ha', 1, 'fora do HA');
    }

    my ($repl) = $class->_pvesh_opt(get => '/cluster/replication');
    my @repl_jobs = grep { ($_->{guest} // '') eq $from } @{$repl || []};
    if (@repl_jobs) {
        if ($o{handle_replication}) {
            push @warnings, 'VM tem replicação (' . join(', ', map { $_->{id} } @repl_jobs)
                . '): será removida e recriada; a recriação faz sync COMPLETO';
            _check(\@checks, 'replicacao', 1, 'replicação tratada com --handle-replication', 1);
        } else {
            _check(\@checks, 'replicacao', 0, 'VM tem replicação (use --handle-replication)');
        }
    } else {
        _check(\@checks, 'replicacao', 1, 'sem replicação');
    }

    # 6. Classificação dos drives.
    my ($storages) = $class->_pvesh_opt(get => '/storage');
    my %storage_types = map { ($_->{storage} // '') => ($_->{type} // '') } @{$storages || []};
    my @drives = $class->_classify_drives($conf, \%storage_types);
    my $bad_storage = '';
    for my $d (@drives) {
        next unless $d->{kind} eq 'volume';
        my $t = $d->{storage_type};
        if (!defined $t || $t eq '') {
            $bad_storage = "storage '$d->{storage}' do drive $d->{key} não encontrado no cluster";
            last;
        }
        if (!$RENAME_OK{$t}) {
            $bad_storage = "drive $d->{key} no storage $d->{storage} (tipo $t) sem feature rename";
            last;
        }
    }
    _check(\@checks, 'drives', ($bad_storage ? 0 : 1),
        $bad_storage || join('; ', map { "$_->{key}=$_->{kind}" } @drives) || 'sem drives');
    $info{drives} = \@drives;

    $info{original_config} = $conf;
    $info{name} = $conf->{name};
    $info{ha} = $ha_entry ? $ha_entry : undef;
    $info{replication} = \@repl_jobs;

    my $ok_all = (grep { !$_->{ok} } @checks) ? 0 : 1;
    return { ok => $ok_all, checks => \@checks, warnings => \@warnings, info => \%info };
}

# --------------------------------------------------------- espera tarefa

sub wait_task {
    my ($class, $upid, %o) = @_;
    my $deadline = time + ($o{timeout} // $TASK_TIMEOUT);
    while (1) {
        my $tasks = eval { MMPve::Core::Runner->pvesh(get => '/cluster/tasks') };
        if ($tasks) {
            for my $t (@{$tasks || []}) {
                next unless ($t->{upid} // '') eq $upid;
                next unless ($t->{status} // '') eq 'stopped';
                my $es = $t->{exitstatus} // '';
                die "tarefa falhou: $upid → $es\n" unless $es eq 'OK';
                return 1;
            }
        }
        die "timeout esperando a tarefa $upid\n" if time >= $deadline;
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
        next unless defined $conf->{$k} && !ref $conf->{$k};
        $params{$k} = $conf->{$k};
    }
    MMPve::Core::Runner->pvesh(set => "/nodes/$node/qemu/$vmid/config", %params) if %params;
    if ($opt{protection}) {
        MMPve::Core::Runner->pvesh(set => "/nodes/$node/qemu/$vmid/config", protection => 1);
    }
    return 1;
}

sub _step_reserve {
    my ($class, $j, $meta) = @_;
    my $tmpname = ($meta->{name} // "vm") . '-renumber';
    MMPve::Core::Runner->pvesh(create => "/nodes/$meta->{node}/qemu",
        vmid => $meta->{to}, name => $tmpname);
    return "ID $meta->{to} reservado (nome temporário $tmpname)";
}

sub _step_move_disks {
    my ($class, $j, $meta) = @_;
    my $path = "/nodes/$meta->{node}/qemu/$meta->{from}";
    my $moved = 0;
    for my $d (@{$meta->{drives} || []}) {
        if ($d->{kind} eq 'cloudinit') {
            # remove da VM antiga; recriada na nova no passo config.
            MMPve::Core::Runner->pvesh(set => "$path/config", delete => $d->{key});
            $j->record('move_disks', cloudinit => { $d->{key} => $d->{value} });
            next;
        }
        next unless $d->{kind} eq 'volume';
        my $upid = MMPve::Core::Runner->pvesh(create => "$path/move_disk",
            disk => $d->{key}, 'target-vmid' => $meta->{to}, 'target-disk' => $d->{key});
        $class->wait_task($upid);
        $moved++;
    }
    return $moved ? "$moved disco(s) movido(s) (tarefa esperada por drive)" : 'nenhum disco de volume';
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
    MMPve::Core::Runner->pvesh(set => "/nodes/$meta->{node}/qemu/$meta->{to}/config", %params)
        if %params;

    # protection por último.
    if ($conf->{protection}) {
        MMPve::Core::Runner->pvesh(set => "/nodes/$meta->{node}/qemu/$meta->{to}/config",
            protection => 1);
    }
    return 'configuração copiada (MACs, smbios1 uuid e vmgenid preservados; protection por último)';
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
        write_file_atomic($new, $content, 0644);
        return 'firewall copiado';
    }
    return 'sem arquivo de firewall';
}

sub _step_refs {
    my ($class, $j, $meta) = @_;
    my ($from, $to, $node) = @{$meta}{qw(from to node)};
    my @done;

    # pool
    my ($pools) = $class->_pvesh_opt(get => '/pools');
    for my $p (@{$pools || []}) {
        my $pname = $p->{poolid} // next;
        my ($pd) = $class->_pvesh_opt(get => "/pools/$pname");
        my @members = map { $_->{vmid} } grep { ($_->{id} // '') =~ /^qemu\// }
            @{$pd->{members} || []};
        next unless grep { $_ == $from } @members;
        MMPve::Core::Runner->pvesh(set => "/pools/$pname", vms => $to);
        $j->record('refs', pool => $pname);
        push @done, "pool $pname";
        last;
    }

    # ACLs /vms/<antigo> → /vms/<novo>
    my ($acls) = $class->_pvesh_opt(get => '/access/acl');
    my @mine = grep { ($_->{path} // '') eq "/vms/$from" } @{$acls || []};
    my @acl_undo;
    for my $a (@mine) {
        my %args = (path => "/vms/$to", roles => $a->{roleid}, propagate => $a->{propagate} // 0);
        if (($a->{ugid_type} // '') eq 'user') { $args{users}  = $a->{ugid} }
        else                                   { $args{groups} = $a->{ugid} }
        MMPve::Core::Runner->pvesh(set => '/access/acl', %args);
        push @acl_undo, \%args;
    }
    $j->record('refs', acls => \@acl_undo) if @acl_undo;
    push @done, scalar(@acl_undo) . ' ACL(s)' if @acl_undo;

    # jobs de backup com VMID explícito
    my ($jobs) = $class->_pvesh_opt(get => '/cluster/backup');
    my @bk_undo;
    for my $jb (@{$jobs || []}) {
        my $v = $jb->{vmid} // '';
        next if $v eq 'all' || $v eq '' || ref $v;
        my @ids = split /\s*,\s*/, $v;
        next unless grep { $_ == $from } @ids;
        my $newlist = join ',', map { $_ == $from ? $to : $_ } @ids;
        MMPve::Core::Runner->pvesh(set => "/cluster/backup/$jb->{id}", vmid => $newlist);
        push @bk_undo, { id => $jb->{id}, vmid => $v };
    }
    $j->record('refs', backups => \@bk_undo) if @bk_undo;
    push @done, scalar(@bk_undo) . ' job(s) de backup' if @bk_undo;

    # HA
    if ($meta->{ha} && $meta->{handle_ha}) {
        my $h = $meta->{ha};
        MMPve::Core::Runner->pvesh(create => '/cluster/ha/resources', sid => "vmid:$to");
        my %extra;
        $extra{state} = $h->{state}     if defined $h->{state}  && $h->{state} ne 'started';
        $extra{group} = $h->{group}     if defined $h->{group} && length $h->{group};
        $extra{comment} = $h->{comment} if defined $h->{comment} && length $h->{comment};
        MMPve::Core::Runner->pvesh(set => "/cluster/ha/resources/vmid:$to", %extra) if %extra;
        $j->record('refs', ha => 1);
        push @done, 'recurso HA';
    }

    # replicação
    if ($meta->{handle_replication} && @{$meta->{replication} || []}) {
        for my $r (@{$meta->{replication}}) {
            my %args = (id => $r->{id}, target => $r->{target}, guest => $to);
            $args{schedule} = $r->{schedule} if defined $r->{schedule};
            MMPve::Core::Runner->pvesh(create => "/nodes/$node/replication", %args);
        }
        $j->record('refs', replication => 1);
        push @done, 'job(s) de replicação (primeiro sync será completo)';
    }

    return @done ? join('; ', @done) : 'nenhuma referência externa';
}

sub _step_verify {
    my ($class, $j, $meta) = @_;
    my ($conf) = $class->_pvesh_opt(get => "/nodes/$meta->{node}/qemu/$meta->{from}/config");
    my @left;
    for my $k (sort keys %{$conf || {}}) {
        next unless $k =~ /^(?:ide|sata|scsi|virtio)\d+$/
            || $k =~ /^unused\d+$/ || $k eq 'efidisk0' || $k eq 'tpmstate0';
        push @left, "$k=$conf->{$k}"
            if defined $conf->{$k} && $conf->{$k} =~ /^(vm|base)-\d+-/;
    }
    die "VM antiga ainda tem volumes: " . join(', ', @left) . "\n" if @left;
    return 'VM antiga sem volumes';
}

sub _step_destroy {
    my ($class, $j, $meta) = @_;
    MMPve::Core::Runner->pvesh(delete => "/nodes/$meta->{node}/qemu/$meta->{from}",
        purge => 1, 'destroy-unreferenced-disks' => 0);
    return "VM $meta->{from} apagada (purge; discos já movidos)";
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
    reserve     => 'reservar o ID novo (qemu create)',
    move_disks  => 'mover os discos (move_disk por drive, esperando a tarefa)',
    config      => 'copiar o resto da configuração (MACs/smbios1/vmgenid; protection por último)',
    firewall    => 'copiar /etc/pve/firewall/<antigo>.fw para <novo>.fw',
    refs        => 'pool, ACLs /vms/<id>, jobs de backup, HA e replicação',
    verify      => 'conferir que a VM antiga ficou sem volumes',
    destroy     => 'apagar a VM antiga (--purge 1 --destroy-unreferenced-disks 0)',
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
        ha => $pre->{info}{ha},
        replication => $pre->{info}{replication},
        handle_ha => $o{handle_ha} ? 1 : 0,
        handle_replication => $o{handle_replication} ? 1 : 0,
    );
    my $id = $class->journal_id($o{from}, $o{to});
    # reusa o journal só se houver algo para retomar (failed/running);
    # journal concluído = nova operação do zero.
    my $j = eval { MMPve::Journal->open($id) };
    if ($j && ($j->state // '') =~ /^(failed|running)$/) {
        my $m = $j->meta;
        $m->{$_} = $meta{$_} for keys %meta;    # meta fresca, steps preservados
    } else {
        $j = MMPve::Journal->create($id, %meta);
    }
    $j->steps([@STEPS]);
    $j->set_state('running');
    my %jmeta = %{$j->meta};
    return $class->_exec_steps($j, \%jmeta);
}

sub _exec_steps {
    my ($class, $j, $meta) = @_;
    my ($from, $to) = ($meta->{from}, $meta->{to});
    for my $s ($j->steps) {
        my $st = $j->step_info($s)->{status} // 'pending';
        next if $st eq 'done';
        $j->mark_running($s);                          # ANTES
        my $detail = eval { $STEP_IMPL{$s}->($class, $j, $meta) };
        if (my $err = $@) {
            chomp $err;
            $j->mark_failed($s, $err);
            log_line("renumber $from>$to FALHOU no passo $s: $err");
            die "$err\nPasso '$s' falhou.\nContinue com: mm-pve renumber --resume --from $from --to $to\n";
        }
        $j->mark_done($s);                             # DEPOIS
        print "renumber: passo $s ok — $detail\n";
    }
    $j->finish({
        from => $from, to => $to, node => $meta->{node},
        note => 'Histórico de backup PBS continua no grupo vm/' . $from
            . ' (só sai com prune job do PBS); não mexa nos backups antigos.',
    });
    return {
        ok => 1, from => $from, to => $to, node => $meta->{node}, steps => [@STEPS],
        summary => "VM $from > $to concluída. Lembrete: o histórico de backup PBS "
            . "continua no grupo vm/$from (só sai com prune job do PBS); "
            . "os backups antigos não devem ser mexidos.",
    };
}

sub resume {
    my ($class, %o) = @_;
    my $id = $o{id} // $class->journal_id($o{from}, $o{to});
    my $j = eval { MMPve::Journal->open($id) };
    die "journal $id não encontrado.\nUse: mm-pve renumber --from <antigo> --to <novo>\n" if $@ || !$j;
    my %meta = (%{$j->meta},
        (defined $o{handle_ha} ? (handle_ha => $o{handle_ha}) : ()),
        (defined $o{handle_replication} ? (handle_replication => $o{handle_replication}) : ()));
    die "journal sem from/to.\n" unless $meta{from} && $meta{to};
    my $next = $j->first_pending;
    die "nada pendente no journal $id (estado: " . $j->state . ").\n" unless $next;
    print "renumber: retomando do passo '$next'\n";
    $j->set_state('running');
    return $class->_exec_steps($j, \%meta);
}

# ------------------------------------------------------------- rollback

sub _undo_destroy {
    my ($class, $j, $meta) = @_;
    MMPve::Core::Runner->pvesh(create => "/nodes/$meta->{node}/qemu",
        vmid => $meta->{from}, name => ($meta->{name} // "vm$meta->{from}"));
    return 'VM antiga recriada (shell)';
}

sub _undo_verify { return 'nada a desfazer (verificação)' }

sub _undo_refs {
    my ($class, $j, $meta) = @_;
    my $info = $j->step_info('refs');
    if (my $pool = $info->{pool}) {
        MMPve::Core::Runner->pvesh(set => "/pools/$pool", vms => $meta->{to}, delete => 1);
    }
    for my $a (@{$info->{acls} || []}) {
        my %args = (path => "/vms/$meta->{to}", roles => $a->{roles});
        $args{users}  = $a->{users}  if $a->{users};
        $args{groups} = $a->{groups} if $a->{groups};
        MMPve::Core::Runner->pvesh(delete => '/access/acl', %args);
    }
    for my $b (@{$info->{backups} || []}) {
        MMPve::Core::Runner->pvesh(set => "/cluster/backup/$b->{id}", vmid => $b->{vmid});
    }
    if ($info->{ha}) {
        MMPve::Core::Runner->pvesh(delete => "/cluster/ha/resources/vmid:$meta->{to}");
    }
    if ($info->{replication}) {
        for my $r (@{$meta->{replication} || []}) {
            MMPve::Core::Runner->pvesh(delete => "/nodes/$meta->{node}/replication/$r->{id}");
        }
    }
    return 'referências revertidas';
}

sub _undo_firewall {
    my ($class, $j, $meta) = @_;
    my $content = $j->step_info('firewall')->{fw_content};
    if (defined $content) {
        write_file_atomic($class->_fw_path($meta->{from}), $content, 0644);
    }
    my $new = $class->_fw_path($meta->{to});
    unlink $new if -f $new;
    return 'firewall restaurado';
}

sub _undo_config { return 'config da VM nova morre com ela no desfazer do reserve' }

sub _undo_move_disks {
    my ($class, $j, $meta) = @_;
    my $path = "/nodes/$meta->{node}/qemu/$meta->{to}";
    my @vols = reverse grep { $_->{kind} eq 'volume' } @{$meta->{drives} || []};
    for my $d (@vols) {
        my $upid = MMPve::Core::Runner->pvesh(create => "$path/move_disk",
            disk => $d->{key}, 'target-vmid' => $meta->{from}, 'target-disk' => $d->{key});
        $class->wait_task($upid);
    }
    # devolve o resto da configuração original (MACs/smbios1/vmgenid/protection)
    $class->_vm_set_config($meta->{node}, $meta->{from}, $meta->{original_config},
        protection => $meta->{original_config}{protection} ? 1 : 0);
    # cloudinit de volta
    my $ci = $j->step_info('move_disks')->{cloudinit} || {};
    if (%$ci) {
        MMPve::Core::Runner->pvesh(set => "/nodes/$meta->{node}/qemu/$meta->{from}/config", %$ci);
    }
    return 'discos e configuração devolvidos à VM antiga';
}

sub _undo_reserve {
    my ($class, $j, $meta) = @_;
    my $r = eval {
        MMPve::Core::Runner->pvesh(delete => "/nodes/$meta->{node}/qemu/$meta->{to}",
            purge => 1, 'destroy-unreferenced-disks' => 0);
    };
    warn "não consegui apagar a VM $meta->{to}: $@\n" if $@;
    return "VM nova $meta->{to} apagada";
}

my %UNDO_IMPL = (
    reserve    => \&_undo_reserve,
    move_disks => \&_undo_move_disks,
    config     => \&_undo_config,
    firewall   => \&_undo_firewall,
    refs       => \&_undo_refs,
    verify     => \&_undo_verify,
    destroy    => \&_undo_destroy,
);

sub rollback {
    my ($class, %o) = @_;
    my $id = $o{id} // $class->journal_id($o{from}, $o{to});
    my $j = eval { MMPve::Journal->open($id) };
    die "journal $id não encontrado.\n" if $@ || !$j;
    my %meta = %{$j->meta};
    die "journal sem from/to.\n" unless $meta{from} && $meta{to};
    my @undo = $j->rollback_steps;
    die "nenhum passo concluído para desfazer (estado: " . $j->state . ").\n" unless @undo;
    for my $s (@undo) {
        print "renumber: desfazendo '$s'\n";
        my $detail = eval { $UNDO_IMPL{$s}->($class, $j, \%meta) };
        if (my $err = $@) {
            chomp $err;
            $j->set_state('rollback-failed');
            die "$err\nDesfazer de '$s' falhou.\nContinue com: mm-pve renumber --rollback --from $meta{from} --to $meta{to}\n";
        }
        $j->record($s, undone => 1);
    }
    $j->finish({ rolled_back => 1, from => $meta{from}, to => $meta{to} });
    return { ok => 1, undone => \@undo };
}

# ------------------------------------------------------------- módulo/CLI

sub validate_section { return () }    # vmid_scheme já validado pelo núcleo

sub apply  { return { ok => 1, changed => 0, message => 'renumber não tem estado por node; use mm-pve renumber --from X --to Y' } }
sub revert { return { ok => 1, changed => 0, message => 'renumber: nada a reverter' } }
sub check  {
    my ($c, $cfg) = @_;
    return {
        ok => 1,
        vmid_scheme => $cfg->{vmid_scheme} // [],
        note => 'renumber é operação sob demanda (precheck + journal)',
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
    ) or do { print STDERR "uso inválido (mm-pve renumber --help)\n"; return 2 };

    if ($help) {
        print <<'EOF';
mm-pve renumber — troca de VMID via move_disk

uso:
  mm-pve renumber --from <antigo> --to <novo> [opções]
  mm-pve renumber --resume   --from <antigo> --to <novo>   (ou --id <journal>)
  mm-pve renumber --rollback --from <antigo> --to <novo>   (ou --id <journal>)

opções:
  --node <n>               node da VM (padrão: localiza no cluster)
  --dry-run                mostra o plano (precheck + passos), não executa nada
  --force-scheme           continua mesmo com ID novo fora do vmid_scheme
  --handle-ha              remove e recria o recurso de HA com o novo ID
  --handle-replication     remove e recria replicação (sync completo) com o novo ID
  --json                   saída em JSON
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
            printf "%s %-22s %s\n", ($_->{ok} ? '✔' : '✘'), $_->{check}, $_->{detail}
                for @{$res->{checks}};
        }
        print "AVISO: $_\n" for @{$res->{warnings} || []};
    };

    if ($rollback) {
        my $res = eval { $class->rollback(id => $id, from => $from, to => $to) };
        if (my $err = $@) {
            chomp $err; print STDERR "ERRO: $err\n";
            print STDERR "Continue com: mm-pve renumber --rollback --from $from --to $to\n" if $from && $to;
            return 1;
        }
        print JSON::PP->new->canonical->pretty->utf8->encode($res), "\n" if $json;
        print "rollback concluído (passos: @{$res->{undone}})\n" unless $json;
        return 0;
    }

    if ($resume) {
        my $res = eval {
            $class->resume(id => $id, from => $from, to => $to,
                handle_ha => $hha, handle_replication => $hrep);
        };
        if (my $err = $@) {
            chomp $err; print STDERR "ERRO: $err\n";
            print STDERR "Continue com: mm-pve renumber --resume --from $from --to $to\n" if $from && $to;
            return 1;
        }
        print JSON::PP->new->canonical->pretty->utf8->encode($res), "\n" if $json;
        print $res->{summary}, "\n" unless $json;
        return 0;
    }

    unless (defined $from && defined $to) {
        print STDERR "uso: mm-pve renumber --from <antigo> --to <novo> [--dry-run|--resume|--rollback] [opções]\n";
        return 2;
    }

    my $pre = $class->precheck(%o);
    $dump->($pre);
    if (!$pre->{ok}) {
        print STDERR "ERRO: pré-checagem falhou; nada foi alterado.\n";
        print JSON::PP->new->canonical->pretty->utf8->encode({ ok => 0, phase => 'precheck', %$pre }), "\n" if $json;
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
        print JSON::PP->new->canonical->pretty->utf8->encode($res), "\n" if $json;
        print "PLANO (dry-run, nada executado):\n  $_\n" for @steps;
        return 0;
    }

    my $res = eval { $class->run(%o) };
    if (my $err = $@) {
        chomp $err; print STDERR "ERRO: $err\n";
        return 1;
    }
    if (!$res->{ok}) {
        print STDERR "ERRO: pré-checagem falhou; nada foi alterado.\n";
        print JSON::PP->new->canonical->pretty->utf8->encode({ ok => 0, %$res }), "\n" if $json;
        return 1;
    }
    print JSON::PP->new->canonical->pretty->utf8->encode($res), "\n" if $json;
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
