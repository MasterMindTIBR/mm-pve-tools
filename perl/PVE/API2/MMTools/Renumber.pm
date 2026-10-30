package PVE::API2::MMTools::Renumber;

# Endpoints do módulo renumber sob /nodes/{node}/mm-tools/renumber/...
#   GET  precheck — pré-checagens somente-leitura (lista {check,ok,detail})
#   POST run      — executa a troca em worker (fork_worker 'mmrenumber')

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;

use MMPve::Module::Renumber;

use base qw(PVE::RESTHandler);

my $vmid_desc = {
    type => 'integer',
    minimum => 100,
    maximum => 9999999,
    description => 'VMID.',
};

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    proxyto => 'node',
    permissions => { check => ['/', ['Sys.Audit']] },
    description => 'Índice do módulo renumber.',
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
            name => 'renumber',
            endpoints => ['precheck', 'run'],
            implemented => 1,
        };
    },
});

__PACKAGE__->register_method({
    name => 'precheck',
    path => 'precheck',
    method => 'GET',
    proxyto => 'node',
    permissions => { check => ['/', ['Sys.Audit']] },
    protected => 1,
    description => 'Pré-checagens da troca de VMID (somente leitura).',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            from => { %$vmid_desc, description => 'VMID antigo.' },
            to   => { %$vmid_desc, description => 'VMID novo.' },
            force_scheme => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => 'Aceitar ID novo fora do vmid_scheme.',
            },
            handle_ha => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => 'Remover e recriar o recurso de HA.',
            },
            handle_replication => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => 'Remover e recriar replicação (sync completo).',
            },
        },
    },
    returns => {
        type => 'object',
        properties => {
            ok => { type => 'boolean' },
            checks => {
                type => 'array',
                items => {
                    type => 'object',
                    properties => {
                        check => { type => 'string' },
                        ok => { type => 'boolean' },
                        detail => { type => 'string' },
                    },
                },
            },
            warnings => { type => 'array', items => { type => 'string' } },
            node => { type => 'string', optional => 1 },
        },
    },
    code => sub {
        my ($param) = @_;
        my $pre = MMPve::Module::Renumber->precheck(
            from => $param->{from},
            to => $param->{to},
            force_scheme => $param->{force_scheme} // 0,
            handle_ha => $param->{handle_ha} // 0,
            handle_replication => $param->{handle_replication} // 0,
        );
        return {
            ok => $pre->{ok} ? 1 : 0,
            checks => $pre->{checks},
            warnings => $pre->{warnings},
            node => $pre->{info}{node},
        };
    },
});

__PACKAGE__->register_method({
    name => 'run',
    path => 'run',
    method => 'POST',
    proxyto => 'node',
    permissions => { check => ['/', ['Sys.Modify']] },
    protected => 1,
    description => 'Executa a troca de VMID (tarefa em worker; acompanhe no Task Log).',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            from => { %$vmid_desc, description => 'VMID antigo.' },
            to   => { %$vmid_desc, description => 'VMID novo.' },
            force_scheme => {
                type => 'boolean', optional => 1, default => 0,
                description => 'Aceitar ID novo fora do vmid_scheme.',
            },
            handle_ha => {
                type => 'boolean', optional => 1, default => 0,
                description => 'Remover e recriar o recurso de HA.',
            },
            handle_replication => {
                type => 'boolean', optional => 1, default => 0,
                description => 'Remover e recriar replicação (sync completo).',
            },
            resume => {
                type => 'boolean', optional => 1, default => 0,
                description => 'Continuar do primeiro passo não concluído (journal).',
            },
            rollback => {
                type => 'boolean', optional => 1, default => 0,
                description => 'Desfazer os passos concluídos (ordem inversa).',
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();

        my %o = (
            from => $param->{from},
            to => $param->{to},
            force_scheme => $param->{force_scheme} // 0,
            handle_ha => $param->{handle_ha} // 0,
            handle_replication => $param->{handle_replication} // 0,
        );
        my $resume = $param->{resume} // 0;
        my $rollback = $param->{rollback} // 0;

        my $realcmd = sub {
            my $res;
            if ($rollback) {
                $res = MMPve::Module::Renumber->rollback(%o);
                printf "rollback: %s\n", join(', ', @{$res->{undone}});
                return;
            }
            if ($resume) {
                $res = MMPve::Module::Renumber->resume(%o,
                    handle_ha => $o{handle_ha}, handle_replication => $o{handle_replication});
            } else {
                $res = MMPve::Module::Renumber->run(%o);
                if (!$res->{ok}) {
                    printf "%s %s\n", ($_->{ok} ? 'OK ' : 'FALHA'), "$_->{check}: $_->{detail}"
                        for @{$res->{checks} || []};
                    die "pré-checagem falhou; nada foi alterado\n";
                }
            }
            print $res->{summary}, "\n" if $res->{summary};
        };
        return $rpcenv->fork_worker('mmrenumber', "vmid-$param->{from}-$param->{to}", $authuser, $realcmd);
    },
});

1;
