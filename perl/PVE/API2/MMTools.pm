package PVE::API2::MMTools;

# Endpoints MasterMind sob /nodes/{node}/mm-tools/...
# Registrado no PVE::API2::Nodes::Nodeinfo pelo patch de 1 linha (ver
# MMPve::Core::Patch). Este é o ÚNICO lugar autorizado a usar módulos
# internos do PVE (regra do plano/AGENTS.md).
#
# Rotas (núcleo):
#   GET  mm-tools                  índice (versão, módulos, revisão)
#   GET  mm-tools/config           estado desejado + digest
#   PUT  mm-tools/config           salva (digest obrigatório p/ CAS)
#   POST mm-tools/apply            aplica neste node (worker → Task Log)
#   GET  mm-tools/status           diagnóstico deste node
# Módulos (subclass): mm-tools/renumber, mm-tools/restore, mm-tools/branding

use strict;
use warnings;

use PVE::Exception qw(raise_param_exc);
use PVE::INOTIFY;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::SafeSyslog;

use MMPve::Core::Config;
use MMPve::Core::Apply;
use MMPve::Core::Status;
use MMPve::Core::Patch;

use base qw(PVE::RESTHandler);

my $node_guard = sub {
    my ($node) = @_;
    my $local = PVE::INOTIFY::nodename();
    return if $node eq $local || $node eq 'localhost';
    raise_param_exc({ node => "requisição para '$node' chegou no node '$local'" });
};

sub mm_version {
    return $MMPve::Core::Config::VERSION;
}

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    permissions => { user => 'all' },
    description => 'Índice do mm-pve-tools (MasterMind).',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'object',
        properties => {
            version => { type => 'string' },
            revision => { type => 'integer' },
            modules => { type => 'object' },
        },
    },
    code => sub {
        my ($param) = @_;
        $node_guard->($param->{node});
        my ($cfg, $digest, $absent) = MMPve::Core::Config->load;
        return {
            version => mm_version(),
            revision => $cfg->{revision},
            modules => $cfg->{modules},
            absent => $absent ? 1 : 0,
            digest => $digest,
        };
    },
});

__PACKAGE__->register_method({
    name => 'get_config',
    path => 'config',
    method => 'GET',
    permissions => { check => ['/', ['Sys.Audit']] },
    description => 'Lê o estado desejado dos módulos MasterMind (/etc/pve/mm-tools/config.json).',
    protected => 0,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'object',
        properties => {
            config => { type => 'object' },
            digest => { type => 'string' },
        },
    },
    code => sub {
        my ($param) = @_;
        $node_guard->($param->{node});
        my ($cfg, $digest, $absent) = MMPve::Core::Config->load;
        return { config => $cfg, digest => $digest // '', absent => $absent ? 1 : 0 };
    },
});

__PACKAGE__->register_method({
    name => 'set_config',
    path => 'config',
    method => 'PUT',
    permissions => { check => ['/', ['Sys.Modify']] },
    description => 'Salva o estado desejado (validação estrita; digest para não sobrescrever edição concorrente).',
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            digest => {
                type => 'string',
                description => 'sha256 do arquivo atual, lido no GET (CAS).',
                pattern => '^sha256:[0-9a-f]{64}$',
                optional => 1,
            },
            config => {
                type => 'object',
                description => 'config completo (substitui).',
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        $node_guard->($param->{node});
        my %save_opt;
        $save_opt{digest} = $param->{digest} if defined $param->{digest};
        my ($saved, $digest) = MMPve::Core::Config->save($param->{config}, %save_opt);
        return { revision => $saved->{revision}, digest => $digest };
    },
});

__PACKAGE__->register_method({
    name => 'apply',
    path => 'apply',
    method => 'POST',
    permissions => { check => ['/', ['Sys.Modify']] },
    description => 'Aplica patches + módulos neste node (tarefa em worker; acompanhe no Task Log).',
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            patches => {
                type => 'boolean',
                description => 'Aplicar também os patches do pve-manager (padrão: sim).',
                optional => 1,
                default => 1,
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        $node_guard->($param->{node});
        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        my $patches = $param->{patches} // 1;
        my $realcmd = sub {
            my $res = MMPve::Core::Apply->apply_all(
                $patches ? (patches => 1) : (patches => 0));
            for my $n (sort keys %{ $res->{modules} // {} }) {
                my $m = $res->{modules}{$n};
                printf "%-9s %-8s %s\n", $n,
                    ($m->{enabled} ? 'ligado' : 'desligado'),
                    ($m->{ok} ? 'ok' : 'ERRO: ' . ($m->{error} // '?'));
            }
            my $p = $res->{patches};
            if ($p) {
                printf "patch %-10s %s\n", $_, $p->{targets}{$_}{status}
                    for sort keys %{ $p->{targets} // {} };
            }
            print 'resultado: ', ($res->{ok} ? 'OK' : 'COM ERROS'), "\n";
            die "apply concluído com erros\n" unless $res->{ok};
        };
        return $rpcenv->fork_worker('mmapply', "node:$param->{node}", $authuser, $realcmd);
    },
});

__PACKAGE__->register_method({
    name => 'status',
    path => 'status',
    method => 'GET',
    permissions => { check => ['/', ['Sys.Audit']] },
    description => 'Diagnóstico do node: versões, patches, revisão aplicada, ntfs3g.',
    protected => 0,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        $node_guard->($param->{node});
        return MMPve::Core::Status->collect(skip_ntfs3g => 0);
    },
});

# ---------------------------------------------------------------- módulos

use PVE::API2::MMTools::Renumber;
__PACKAGE__->register_method({
    subclass => "PVE::API2::MMTools::Renumber",
    path => 'renumber',
});

use PVE::API2::MMTools::Restore;
__PACKAGE__->register_method({
    subclass => "PVE::API2::MMTools::Restore",
    path => 'restore',
});

use PVE::API2::MMTools::Branding;
__PACKAGE__->register_method({
    subclass => "PVE::API2::MMTools::Branding",
    path => 'branding',
});

1;
