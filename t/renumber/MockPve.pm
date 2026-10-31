package MockPve;

# Mock do pvesh para os testes do renumber (ver AGENTS.md: OVERRIDE do Runner).
# Estado em %MockPve::S; toda chamada mutante (create/set/delete) é registrada
# em @MockPve::OPS como { op, path, args } para conferir ordem e argumentos.

use strict;
use warnings;
use JSON::PP ();

our %S;
our @OPS;

sub reset {
    %S = (
        vmid        => 100,
        to          => 1100,
        used_ids    => {},                       # nextid recusa
        nextid_free => 1,
        orphan      => 0,                        # volumes vm-<to>-* no storage
        vm_status   => { status => 'stopped' },   # GET .../status/current
        vm_config   => {
            digest    => 'mock-0',
            name     => 'app01',
            memory   => 2048,
            cores    => 2,
            ostype   => 'l26',
            bios     => 'seabios',
            agent    => '1',
            tags     => 'producao',
            onboot   => 1,
            net0     => 'virtio=BC:24:11:AA:BB:CC,bridge=vmbr0',
            smbios1  => 'uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
            vmgenid  => '11111111-2222-3333-4444-555555555555',
            scsi0    => 'zfs1:vm-100-disk-0,size=20G',
            scsi1    => 'zfs1:vm-100-disk-1,size=10G',
            efidisk0 => 'zfs1:vm-100-disk-2,efitype=4m,pre-enrolled-keys=0',
            ide0     => 'local:iso/debian.iso,media=cdrom',
            ide2     => 'local:cloudinit',
            protection => 1,
        },
        new_vm_config => {},                     # GET/SET .../1100/config (VM nova)
        config_revision => 0,
        snapshots   => [{ name => 'current' }],
        pending      => [],                       # [{key,value,pending?,delete?}, ...]
        ha           => [],
        repl         => [],
        pools        => [{ poolid => 'infra' }],
        pool_members => [{ id => 'qemu/100', vmid => 100 }],
        acls         => [{ path => '/vms/100', ugid => 'jung@pam', type => 'user',
                           roleid => 'PVEVMAdmin', propagate => 1 }],
        backups      => [{ id => 'job-1', vmid => '100,200' },
                         { id => 'job-all', vmid => 'all' }],
        storage_types => [ { storage => 'zfs1', type => 'zfspool' },
                           { storage => 'shared-nfs', type => 'nfs' } ],
        node_storage => [ { storage => 'zfs1', content => 'images,rootdir', shared => 0, enabled => 1 },
                          { storage => 'shared-nfs', content => 'images', shared => 1, enabled => 1 },
                          { storage => 'iso-only', content => 'iso', enabled => 1 } ],
        fail_at          => '',                  # passo que deve falhar
        fail_after_moves => undef,                # falha a partir do N+1-ésimo move_disk (processo "morto" no meio)
        moves_done       => 0,
        old_destroyed => 0,
        new_created   => 0,
        task_status   => {},                     # upid => {status,exitstatus} ou {sequence=>[...],idx,exitstatus}
        api_fail      => {},                      # path => mensagem de erro (simula falha de API em qualquer GET/create/set/delete)
        external_digest_on_status => 0,           # altera digest após N GETs de status
    );
    @OPS = ();
}

sub _ok  { return { rc => 0, ok => 1, out => JSON::PP->new->encode($_[0]), err => '' } }
sub _err { return { rc => 1, ok => 0, out => '', err => $_[0] } }

sub _parse_args {
    my (@a) = @_;
    my %h;
    while (@a) {
        my $k = shift @a;
        $k =~ s/^--//;
        my $v = (@a && $a[0] !~ /^--/) ? shift @a : 1;
        $h{$k} = $v;
    }
    return %h;
}

sub _record {
    my ($op, $path, %args) = @_;
    push @OPS, { op => $op, path => $path, args => {%args} };
}

sub _touch_old_config {
    $S{config_revision}++;
    $S{vm_config}{digest} = 'mock-' . $S{config_revision};
}

# devolve o status "de agora" de uma tarefa mockada; se tiver 'sequence',
# avança um passo por chamada e fica no último valor depois de esgotar (pra
# testar: running→stopped em N chamadas, ou nunca chegar a 'stopped' —
# timeout limpo em wait_task).
sub _task_status_now {
    my ($t) = @_;
    return undef unless $t;
    if (my $seq = $t->{sequence}) {
        my $i = $t->{idx}++;
        return $i < @$seq ? $seq->[$i] : $seq->[-1];
    }
    return $t->{status};
}

sub handler {
    my ($argv) = @_;
    my ($method, $path, @rest) = @{$argv}[1 .. $#{$argv}];
    my %args = _parse_args(@rest);

    return _err($S{api_fail}{$path}) if $S{api_fail}{$path};

    # -------- GET
    if ($method eq 'get') {
        if ($path eq '/cluster/nextid') {
            return _err("ID '$args{vmid}' já em uso\n") if $S{used_ids}{$args{vmid}};
            return $S{nextid_free} ? _ok($S{to} + 1) : _err("ID '$args{vmid}' já em uso\n");
        }
        return _ok([{ vmid => $S{vmid}, type => 'qemu', node => 'n1' }])
            if $path eq '/cluster/resources';
        return _ok([
            { type => 'cluster', id => 'cluster' },
            { type => 'node', name => 'n1', id => 'node/n1', online => 1 },
            { type => 'node', name => 'n2', id => 'node/n2', online => 0 },
        ]) if $path eq '/cluster/status';
        return _ok($S{node_storage}) if $path eq '/nodes/n1/storage';
        return _ok($S{storage_types}) if $path eq '/storage';
        if ($path =~ m{^/nodes/n1/storage/([^/]+)/content$}) {
            return _ok($S{orphan} ? [{ volid => "$1:vm-$S{to}-disk-9" }] : []);
        }
        if ($path eq '/nodes/n1/qemu/100/status/current') {
            return _err("VM inexistente\n") if $S{old_destroyed};
            if ($S{external_digest_on_status} && --$S{external_digest_on_status} == 0) {
                $S{vm_config}{digest} = 'mock-external-change';
            }
            return _ok($S{vm_status});
        }
        if ($path eq '/nodes/n1/qemu/100/config')   { return _err("VM inexistente\n") if $S{old_destroyed}; return _ok($S{vm_config}) }
        if ($path eq '/nodes/n1/qemu/1100/config')  { return _err("VM inexistente\n") unless $S{new_created}; return _ok($S{new_vm_config}) }
        if ($path eq '/nodes/n1/qemu/100/snapshot') { return _ok($S{snapshots}) }
        if ($path eq '/nodes/n1/qemu/100/pending')  { return _ok($S{pending}) }
        return _ok($S{ha})  if $path eq '/cluster/ha/resources';
        return _ok($S{ha_rules} || []) if $path eq '/cluster/ha/rules';
        return _ok($S{repl}) if $path eq '/cluster/replication';
        return _ok($S{pools}) if $path eq '/pools';
        return _ok({ members => $S{pool_members} }) if $path eq '/pools/infra';
        return _ok($S{acls}) if $path eq '/access/acl';
        return _ok($S{backups}) if $path eq '/cluster/backup';
        if ($path =~ m{^/nodes/([^/]+)/tasks/(.+)/status$}) {
            my ($node, $upid) = ($1, $2);
            my $t = $S{task_status}{$upid};
            return _err("tarefa desconhecida: $upid\n") unless $t;
            my $status = _task_status_now($t);
            return _ok({ upid => $upid, node => $node, status => $status,
                         exitstatus => $t->{exitstatus} });
        }
        return _err("GET desconhecido: $path\n");
    }

    # -------- create
    if ($method eq 'create') {
        _record(create => $path, %args);
        if ($path eq '/nodes/n1/qemu') {
            return _err("create falhou (injetado)\n") if $S{fail_at} eq 'reserve';
            $S{new_created} = 1;
            $S{new_vm_config}{name} = $args{name};
            $S{new_vm_config}{description} = $args{description};
            return _ok(undef);
        }
        if ($path eq '/nodes/n1/qemu/100/move_disk') {
            return _err("move_disk falhou (injetado)\n") if $S{fail_at} eq 'move_disks';
            if (defined $S{fail_after_moves} && $S{moves_done} >= $S{fail_after_moves}) {
                return _err("move_disk falhou (injetado após $S{fail_after_moves} move(s), simulando processo morto)\n");
            }
            # efeito: drive sai da VM antiga e (de verdade) aparece na nova
            my $val = $S{vm_config}{ $args{disk} };
            delete $S{vm_config}{ $args{disk} };
            $S{new_vm_config}{ $args{'target-disk'} } = $val if defined $val;
            _touch_old_config();
            $S{moves_done}++;
            my $upid = "UPID:n1:QN:move:$args{disk}:$S{vmid}:$args{'target-vmid'}:";
            $S{task_status}{$upid} = {
                status => 'stopped',
                exitstatus => ($S{fail_at} eq 'task' ? 'command error' : 'OK'),
            };
            return _ok($upid);
        }
        if ($path eq '/nodes/n1/qemu/1100/move_disk') {    # rollback (nova → antiga)
            my $val = $S{new_vm_config}{ $args{disk} };
            delete $S{new_vm_config}{ $args{disk} };
            $S{vm_config}{ $args{'target-disk'} } = $val if defined $val;
            my $upid = "UPID:n1:QN:move-back:$args{disk}:::";
            $S{task_status}{$upid} = { status => 'stopped', exitstatus => 'OK' };
            return _ok($upid);
        }
        return _ok(undef);    # acl/ha/replication/pool/etc.
    }

    # -------- set
    if ($method eq 'set') {
        _record(set => $path, %args);
        if ($path eq '/nodes/n1/qemu/1100/config') {
            return _err("set config falhou (injetado)\n") if $S{fail_at} eq 'config';
            if (defined $args{delete}) { delete $S{new_vm_config}{ $args{delete} }; return _ok(undef) }
            $S{new_vm_config}{$_} = $args{$_} for keys %args;
            return _ok(undef);
        }
        if ($path eq '/nodes/n1/qemu/100/config') {
            if (defined $args{delete}) { delete $S{vm_config}{ $args{delete} }; _touch_old_config(); return _ok(undef) }
            $S{vm_config}{$_} = $args{$_} for keys %args;
            _touch_old_config();
            return _ok(undef);
        }
        if ($path eq '/cluster/backup/job-1' && $S{fail_at} eq 'refs') {
            return _err("backup set falhou (injetado)\n");
        }
        return _ok(undef);
    }

    # -------- delete
    if ($method eq 'delete') {
        _record(delete => $path, %args);
        if ($path eq '/nodes/n1/qemu/100') {
            return _err("destroy falhou (injetado)\n") if $S{fail_at} eq 'destroy';
            $S{old_destroyed} = 1;
            return _ok(undef);
        }
        return _ok(undef);
    }

    return _err("método desconhecido: $method $path\n");
}

# helpers de asserção: lista de ops (filtrável por op/path)
sub ops {
    my ($op, $path) = @_;
    return grep { (!$op || $_->{op} eq $op) && (!$path || $_->{path} eq $path) } @OPS;
}

1;
