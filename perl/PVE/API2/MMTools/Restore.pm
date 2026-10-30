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

use PVE::Exception qw(raise raise_perm_exc);
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
    description => 'Índice do módulo restore.',
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
    die "volid sem VM de origem\n" unless defined $owner;
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
    description => 'Publica uma pasta de backup PBS via VM gateway (tarefa em worker; '
        . 'resultado com senha buscado uma única vez em results/{result_key}).',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            backup => {
                type => 'string',
                description => 'volid do backup (<storage>:backup/vm/<id>/<ts>).',
                pattern => '^[A-Za-z0-9][A-Za-z0-9_.-]*:backup/vm/\\d+/[0-9][0-9T:.\\-Z]*$',
            },
            path_b64 => {
                type => 'string',
                description => 'Caminho do File Restore em base64 '
                    . '(decodifica /drive-scsi1.img.fidx/part/2/Dados).',
                pattern => '^[A-Za-z0-9+/]+={0,2}$',
                maxLength => 4096,
            },
            vmid => {
                type => 'integer',
                description => 'VM destino (padrão: a dona do backup).',
                minimum => 100,
                maximum => 9999999,
                optional => 1,
            },
            hours => {
                type => 'integer',
                description => 'Duração da sessão em horas (padrão/limite: config restore).',
                minimum => 1,
                optional => 1,
            },
            ticket => {
                type => 'string',
                description => 'Chamado GLPI (GLPI-<número>), para auditoria.',
                pattern => '^GLPI-\\d+$',
                optional => 1,
            },
            vm_ip => {
                type => 'string',
                format => 'ipv4',
                description => 'IP da VM destino (obrigatório se sem guest agent).',
                optional => 1,
            },
            resume => {
                type => 'boolean',
                description => 'Retomar a publicação interrompida do mesmo backup/caminho.',
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

        my %p = map { $_ => $param->{$_} } grep { defined $param->{$_} }
            qw(backup path_b64 vmid hours ticket vm_ip);
        $p{user} = $authuser;
        $p{resume} = 1 if $param->{resume};

        my $realcmd = sub {
            my ($upid) = @_;
            my $res = MMPve::Module::Restore->publish(%p,
                result_key => MMPve::Module::Restore->result_key_for_upid($upid));
            print "publicação criada (VM $res->{vmid}, VLAN $res->{vlan}, "
                . "expira $res->{expires_at})\n";
            print "busque o acesso (UNC/usuário/senha) na GUI — a senha não "
                . "aparece no Task Log\n";
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
    description => 'Resultado da publicação (UNC/usuário/senha). Leitura ÚNICA: '
        . 'só o dono da tarefa e o arquivo é apagado após a leitura.',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            result_key => {
                description => 'Chave opaca SHA-256 da UPID da tarefa de publish.',
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
            raise "resultado ainda está em execução\n", code => 503
                if $err =~ /RESULT_UNFINISHED/;
            raise "resultado não encontrado ou expirado\n", code => 404
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
    description => 'Sessões de restore ativas no gateway (gw-restore list).',
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
    description => 'Revoga uma sessão de restore (worker; remove a tag restore-ativo na última).',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            id => {
                description => 'ID da sessão (veja sessions).',
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
        die "sessão $id não encontrada\n" unless $session;
        my $vmid = $session->{target_vmid} // $session->{vmid};
        die "sessão $id sem VM destino\n" unless defined $vmid;
        $rpcenv->check($authuser, "/vms/$vmid", ['VM.Audit']);
        if (($session->{source_vmid} // $vmid) != $vmid) {
            $rpcenv->check($authuser, "/vms/$vmid", ['VM.Backup']);
        }
        my $realcmd = sub {
            MMPve::Module::Restore->revoke($id);
            print "sessão $id revogada\n";
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
    description => 'Selfcheck do gateway por item (✔/✘).',
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
