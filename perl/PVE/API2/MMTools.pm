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

use JSON::PP qw(decode_json);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::SafeSyslog;

use MMPve::Core::Config;
use MMPve::Core::Apply;
use MMPve::Core::Status;
use MMPve::Core::Patch;
use MMPve::Core::Runner;
use MMPve::Core::Util qw(random_uuid);

use base qw(PVE::RESTHandler);



sub mm_version {
    return $MMPve::Core::Config::VERSION;
}

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
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
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    description => 'Lê o estado desejado dos módulos MasterMind (/etc/pve/mm-tools/config.json).',
    protected => 1,
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

        my ($cfg, $digest, $absent) = MMPve::Core::Config->load;
        return { config => $cfg, digest => $digest // '', absent => $absent ? 1 : 0 };
    },
});

__PACKAGE__->register_method({
    name => 'set_config_section',
    path => 'config/{section}',
    method => 'PUT',
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Modify']] },
    description => 'Salva uma seção do estado desejado; digest CAS é opcional na primeira gravação.',
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            section => {
                type => 'string',
                pattern => '^(modules|vmid_scheme|restore|branding)$',
            },
            digest => {
                type => 'string',
                optional => 1,
                description => 'sha256 do arquivo atual, lido no GET (CAS).',
                pattern => '^sha256:[0-9a-f]{64}$',
            },
            value => {
                type => 'string',
                description => 'JSON serializado somente da seção alterada.',
                maxLength => 1024 * 1024,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $value = eval { decode_json($param->{value}) };
        die "value precisa conter JSON válido: $@\n" if $@;
        my ($saved, $digest) = MMPve::Core::Config->save_section(
            $param->{section}, $value, digest => $param->{digest});
        return {
            revision => $saved->{revision},
            digest => $digest,
            section => $param->{section},
            value => $saved->{ $param->{section} },
        };
    },
});

__PACKAGE__->register_method({
    name => 'apply',
    path => 'apply',
    method => 'POST',
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Modify']] },
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
        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        my $node = $param->{node};
        my $realcmd = sub {
            my ($upid) = @_;
            my $res = MMPve::Core::Runner->run([
                '/usr/sbin/mm-pve', '--json', 'apply', '--no-reload',
            ], timeout => 240);
            die "mm-pve apply falhou (rc=$res->{rc}): "
                . ($res->{err} || $res->{error} || 'sem diagnóstico') . "\n"
                unless $res->{ok};
            my $data = eval { decode_json($res->{out}) };
            die "mm-pve apply não retornou JSON válido: $@\n" if $@ || ref($data) ne 'HASH';
            die "mm-pve apply reportou falha (rc=0): "
                . ($data->{error} || 'resultado ok=false') . "\n"
                unless $data->{ok};

            if ($data->{reload_required}) {
                my $unit = 'mm-pve-reload-' . substr(random_uuid(), 0, 12);
                my $reload = MMPve::Core::Runner->run([
                    'systemd-run', '--no-block', '--collect', "--unit=$unit",
                    'systemctl', 'reload', 'pveproxy.service', 'pvedaemon.service',
                ], timeout => 30);
                die "não consegui agendar reload pós-apply (unit $unit): "
                    . ($reload->{err} || $reload->{error} || "rc=$reload->{rc}") . "\n"
                    unless $reload->{ok};
                print "apply concluído; reload agendado na unit $unit\n";
            } else {
                print "apply concluído; reload não necessário\n";
            }
        };
        return $rpcenv->fork_worker('mmapply', "apply-$node", $authuser, $realcmd);
    },
});

__PACKAGE__->register_method({
    name => 'status',
    path => 'status',
    method => 'GET',
    proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    description => 'Diagnóstico do node: versões, patches, revisão aplicada, ntfs3g.',
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        my ($cfg) = MMPve::Core::Config->load;
        return MMPve::Core::Status->collect(skip_ntfs3g => 0, config => $cfg,
            authuser => $authuser);
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
