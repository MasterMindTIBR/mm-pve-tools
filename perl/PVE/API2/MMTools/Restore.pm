package PVE::API2::MMTools::Restore;

# Endpoints do módulo restore sob /nodes/{node}/mm-tools/restore/...
#
#   POST publish        cria publicação (worker 'mmrestore'; a SENHA não vai
#                       ao Task Log — só ao resultado opaco one-shot)
#   GET  results/{result_key} leitura ÚNICA do resultado (só o dono da tarefa;
#                       o arquivo 0600 é apagado na leitura)
#   GET  sessions       sessões ativas (gw-restore list)
#   POST revoke         revoga sessão (worker)
#   GET  test-gateway   selfcheck do gw-restore por item ✔/✘
#
# Permissões (plano): check_volume_access 'backup' no volid; VM.Audit na VM
# destino; VM.Backup se o destino não for a dona do backup.

use strict;
use warnings;

use PVE::Exception qw(raise raise_param_exc raise_perm_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Storage;

use MMPve::Module::Restore;

use base qw(PVE::RESTHandler);



__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    description => 'Restore module index.',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        return {
            name => 'restore',
            endpoints => ['publish', 'result', 'sessions', 'revoke', 'test-gateway'],
            implemented => 1,
        };
    },
});

my $publish_perms = sub {
    my ($param, $rpcenv) = @_;
    my $authuser = $rpcenv->get_user();

    # mesma regra do File Restore nativo: acesso 'backup' ao volid
    my $cfg = PVE::Storage::config();
    PVE::Storage::check_volume_access($rpcenv, $authuser, $cfg, undef, $param->{backup}, 'backup');

    my ($owner) = $param->{backup} =~ m{:backup/vm/(\d+)/};
    die "backup volume has no source VM\n" unless defined $owner;
    my $dest = $param->{vmid} // $owner + 0;
    $rpcenv->check($authuser, "/vms/$dest", ['VM.Audit']);
    $rpcenv->check($authuser, "/vms/$dest", ['VM.Backup']) if $dest != $owner;
};

__PACKAGE__->register_method({
    name => 'publish',
    path => 'publish',
    method => 'POST',
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    protected => 1,
    description => 'Publish a PBS backup folder through the gateway VM (worker task; '
        . 'the password result is fetched once from results/{result_key}).',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            backup => {
                type => 'string',
                description => 'Backup volume ID (<storage>:backup/vm/<id>/<ts>).',
                pattern => '^[A-Za-z0-9][A-Za-z0-9_.-]*:backup/vm/\\d+/[0-9][0-9T:.\\-Z]*$',
            },
            path_b64 => {
                type => 'string',
                description => 'File Restore path in base64 '
                    . '(decodes /drive-scsi1.img.fidx/part/2/Documents).',
                pattern => '^[A-Za-z0-9+/]+={0,2}$',
                maxLength => 4096,
            },
            vmid => {
                type => 'integer',
                description => 'Destination VM (default: the backup owner).',
                minimum => 100,
                maximum => 9999999,
                optional => 1,
            },
            hours => {
                type => 'integer',
                description => 'Session duration in hours (default/limit: restore config).',
                minimum => 1,
                optional => 1,
            },
            ticket => {
                type => 'string',
                description => 'GLPI ticket (GLPI-<number>) for audit.',
                pattern => '^GLPI-\\d+$',
                optional => 1,
            },
            vm_ip => {
                type => 'string',
                format => 'ipv4',
                description => 'Destination VM IP (required without a guest agent).',
                optional => 1,
            },
            resume => {
                type => 'boolean',
                description => 'Resume an interrupted publish for the same backup/path.',
                optional => 1,
                default => 0,
            },
        },
    },
    returns => {
        type => 'object',
        properties => {
            upid => { type => 'string' },
            result_key => { type => 'string', pattern => '^[A-Fa-f0-9]{64}$' },
        },
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment->get();
        $publish_perms->($param, $rpcenv);
        my $authuser = $rpcenv->get_user();
        # caminho inválido volta na resposta, antes de abrir a tarefa
        eval {
            MMPve::Module::Restore->require_folder(
                MMPve::Module::Restore->translate_path($param->{path_b64}));
        };
        raise_param_exc({ path_b64 => "$@" }) if $@;

        my %p = map { $_ => $param->{$_} } grep { defined $param->{$_} }
            qw(backup path_b64 vmid hours ticket vm_ip);
        $p{user} = $authuser;
        $p{resume} = 1 if $param->{resume};

        my $realcmd = sub {
            my ($upid) = @_;
            my $res = MMPve::Module::Restore->publish(%p,
                result_key => MMPve::Module::Restore->result_key_for_upid($upid));
            print "publish created (VM $res->{vmid}, VLAN $res->{vlan}, "
                . "expira $res->{expires_at})\n";
            print "retrieve access (UNC/user/password) in the GUI; the password "
                . "does not appear in the Task Log\n";
            return $res;
        };
        my $task_vmid = $param->{vmid} // 'owner';
        my $upid = $rpcenv->fork_worker('mmrestore', "restore-$task_vmid", $authuser, $realcmd);
        my $result_key = MMPve::Module::Restore->result_key_for_upid($upid);
        MMPve::Module::Restore->register_pending_result($result_key, $upid, $authuser);
        return { upid => $upid, result_key => $result_key };
    },
});

__PACKAGE__->register_method({
    name => 'result',
    path => 'results/{result_key}',
    method => 'GET',
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Audit', 'Sys.Modify'], any => 1] },
    protected => 1,                      # lê /run (root)
    description => 'Publish result (UNC/user/password). Read ONCE: only the task '
        . 'owner may read it and the file is deleted after reading.',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            result_key => {
                description => 'Opaque SHA-256 key for the publish task UPID.',
                type => 'string',
                pattern => '^[A-Fa-f0-9]{64}$',
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        my $sys_modify = eval { $rpcenv->check($authuser, '/', ['Sys.Modify'], 1) } || 0;
        my $data = eval {
            MMPve::Module::Restore->fetch_result(
                $param->{result_key}, $authuser, sys_modify => $sys_modify);
        };
        if ($@) {
            my $err = $@;
            raise_perm_exc() if $err =~ /RESULT_FORBIDDEN/;
            raise "result is still running\n", code => 503
                if $err =~ /RESULT_UNFINISHED/;
            raise "result not found or expired\n", code => 404
                if $err =~ /RESULT_NOT_FOUND/;
            die $err;
        }
        return $data;
    },
});

__PACKAGE__->register_method({
    name => 'sessions',
    path => 'sessions',
    method => 'GET',
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    protected => 1,
    description => 'Active restore sessions on the gateway (gw-restore list).',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => { type => 'array' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get();
        my @sessions = MMPve::Module::Restore->sessions;
        my $authuser = $rpcenv->get_user();
        return [ grep {
            my $vmid = $_->{target_vmid};
            $vmid = $_->{vmid} unless defined $vmid;
            defined($vmid) && eval { $rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit'], 1) };
        } @sessions ];
    },
});

__PACKAGE__->register_method({
    name => 'revoke',
    path => 'revoke',
    method => 'POST',
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    protected => 1,
    description => 'Revoke a restore session (worker; remove the restore-active tag on the last one).',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            id => {
                description => 'Session ID (see sessions).',
                type => 'string',
                pattern => '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        my $id = $param->{id};
        my ($session) = grep { ($_->{id} // '') eq $id } MMPve::Module::Restore->sessions;
        die "session $id not found\n" unless $session;
        my $vmid = $session->{target_vmid} // $session->{vmid};
        die "session $id has no destination VM\n" unless defined $vmid;
        $rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit']);
        if (($session->{source_vmid} // $vmid) != $vmid) {
            $rpcenv->check($authuser, "/vms/$vmid", ['VM.Backup']);
        }
        my $realcmd = sub {
            MMPve::Module::Restore->revoke($id);
            print "session $id revoked\n";
        };
        return $rpcenv->fork_worker('mmrestore', "restore-revoke-$id", $authuser, $realcmd);
    },
});

__PACKAGE__->register_method({
    name => 'test_gateway',
    path => 'test-gateway',
    method => 'GET',
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    protected => 1,
    description => 'Gateway self-check by item (pass/fail).',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        return MMPve::Module::Restore->test_gateway;
    },
});

1;
