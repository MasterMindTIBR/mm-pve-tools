package PVE::API2::MMTools::Updates;

# API do módulo de updates. Esta camada é executada no pvedaemon; o executor
# sai para uma unit transitória antes de tocar no APT.

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;

use MMPve::Module::Updates;

use base qw(PVE::RESTHandler);

sub _node { return $_[0]{node} }

sub _user {
    my $rpcenv = PVE::RPCEnvironment->get();
    my $user = $rpcenv->get_user();
    die "usuário autenticado ausente\n" unless defined($user) && length($user);
    if (index($user, '!') >= 0) {
        require PVE::AccessControl;
        my ($owner) = PVE::AccessControl::split_tokenid($user, 1);
        $user = $owner if defined($owner) && length($owner);
    }
    return $user;
}

sub _pending {
    my ($node) = @_;
    require PVE::API2::APT;
    return PVE::API2::APT->list_updates({ node => $node });
}

sub _requested_actor {
    my ($user, $requested) = @_;
    return (defined($requested) && length($requested)) ? $requested : $user if $user eq 'root@pam';
    return $user;
}

my $node_param = { node => get_standard_option('pve-node') };
my $node_perm = { check => ['perm', '/nodes/{node}', ['Sys.Modify']] };

__PACKAGE__->register_method({
    name => 'status', path => 'status', method => 'GET', proxyto => 'node',
    permissions => $node_perm,
    description => 'Status de pacotes e jobs de atualização do node.',
    parameters => { additionalProperties => 0, properties => $node_param },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $node = _node($param);
        my $status = MMPve::Module::Updates->status($node, pending_cb => \&_pending);
        if ($status->{kernel}{reboot_suggested}) {
            $status->{reboot_context} = MMPve::Module::Updates->reboot_context($node);
        }
        return $status;
    },
});

__PACKAGE__->register_method({
    name => 'refresh', path => 'refresh', method => 'POST', proxyto => 'node',
    permissions => $node_perm,
    description => 'Atualiza os índices APT do node.', protected => 1,
    parameters => { additionalProperties => 0, properties => $node_param },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get(); my $user = _user(); my $node = _node($param);
        return $rpcenv->fork_worker('mmrefresh', "updates-$node", $user, sub {
            MMPve::Module::Updates->refresh($node);
            print "apt-get update concluído\n";
        });
    },
});

__PACKAGE__->register_method({
    name => 'run', path => 'run', method => 'POST', proxyto => 'node',
    permissions => $node_perm,
    description => 'Agenda atualização do node fora do pvedaemon.', protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            %{$node_param},
            # Metadado interno não sensível; continua sem qualquer efeito de
            # autorização e aceita somente um principal PVE sem token.
            requested_by => { type => 'string', optional => 1, pattern => qr/^[A-Za-z0-9._-]{1,64}\@[A-Za-z0-9._-]{1,64}$/ },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get(); my $user = _user(); my $node = _node($param);
        my $actor = _requested_actor($user, $param->{requested_by});
        return $rpcenv->fork_worker('mmupdates', "updates-$node", $user, sub {
            my $job = MMPve::Module::Updates->request_run($node, actor => $actor);
            print "job $job agendado\n";
        });
    },
});

__PACKAGE__->register_method({
    name => 'bulk', path => 'bulk', method => 'POST', proxyto => 'node',
    permissions => $node_perm,
    description => 'Agenda atualização de vários nodes com preflight.', protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            %{$node_param},
            nodes => { type => 'string', pattern => qr/^[A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)*$/ },
            mode => { type => 'string', enum => [qw(sequential parallel)] },
            override_preflight => { type => 'boolean', optional => 1, default => 0 },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get(); my $user = _user();
        my @nodes = split /,/, $param->{nodes};
        for my $node (@nodes) {
            $rpcenv->check_full($user, "/nodes/$node", ['Sys.Modify'], 0, 0);
        }
        return MMPve::Module::Updates->run_bulk(\@nodes, mode => $param->{mode},
            actor => $user, override => $param->{override_preflight});
    },
});

__PACKAGE__->register_method({
    name => 'log', path => 'log', method => 'GET', proxyto => 'node',
    permissions => $node_perm,
    description => 'Lê uma página do log de um job gerado pelo sistema.',
    parameters => {
        additionalProperties => 0,
        properties => {
            %{$node_param},
            job => { type => 'string', pattern => qr/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/ },
            start => { type => 'integer', minimum => 0, optional => 1, default => 0 },
            limit => { type => 'integer', minimum => 1, maximum => 1000, optional => 1, default => 100 },
        },
    },
    returns => { type => 'object' },
    code => sub { my ($param) = @_; return MMPve::Module::Updates->log_page(_node($param), $param->{job}, %{$param}); },
});

__PACKAGE__->register_method({
    name => 'reboot', path => 'reboot', method => 'POST', proxyto => 'node',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify', 'Sys.PowerMgmt']] },
    description => 'Reinicia o node somente com kernel novo e confirmação tripla.', protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { %{$node_param}, confirm => { type => 'string', description => 'Nome exato do node.' } },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $node = _node($param);
        my $reboot_context = MMPve::Module::Updates->reboot_context($node);
        my $context = MMPve::Module::Updates->reboot_preflight($node,
            confirm => $param->{confirm}, pending_cb => \&_pending, online => 1,
            %{$reboot_context});
        require PVE::API2::Nodes;
        my ($info) = grep { !$_->{subclass} && ($_->{name} // '') eq 'node_cmd' }
            @{ PVE::API2::Nodes::Nodeinfo->method_attributes };
        die "endpoint nativo de reboot do PVE ausente\n" unless $info && ref($info->{code}) eq 'CODE';
        $info->{code}->({ node => $node, command => 'reboot' });
        return $context;
    },
});

1;
