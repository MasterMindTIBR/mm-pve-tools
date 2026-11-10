package PVE::API2::MMTools::Poollimits;

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use PVE::RESTHandler;

use MMPve::Core::Config;
use MMPve::Module::Poollimits;
use PVE::MMTools::PoolLimits;

use base qw(PVE::RESTHandler);

my $poolid = { type => 'string', format => 'pve-poolid' };
my $resource = {
    type => 'object', additionalProperties => 0,
    properties => {
        enabled => { type => 'boolean' },
        max => { type => 'integer', minimum => 1, optional => 1 },
    },
};

sub _limits_properties {
    return {
        mode => { type => 'string', enum => [qw(allocated running)], optional => 1 },
        cpu => $resource,
        memory_mib => $resource,
        disk_total_gib => $resource,
        disk_storage => {
            type => 'object', additionalProperties => 0,
            properties => {
                enabled => { type => 'boolean' },
                limits => { type => 'object', optional => 1, additionalProperties => 1 },
            },
        },
        digest => { type => 'string', pattern => qr/^sha256:[0-9a-f]{64}$/, optional => 1 },
    };
}

__PACKAGE__->register_method({
    name => 'index', path => '', method => 'GET', proxyto => 'node',
    protected => 1,
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    description => 'Uso e limites de todos os pools.',
    parameters => { additionalProperties => 0, properties => { node => get_standard_option('pve-node') } },
    returns => { type => 'object' },
    code => sub { return PVE::MMTools::PoolLimits->all_status },
});

__PACKAGE__->register_method({
    name => 'read_pool', path => '{poolid}', method => 'GET', proxyto => 'node',
    protected => 1,
    permissions => { check => ['perm', '/pool/{poolid}', ['Pool.Audit']] },
    description => 'Uso e limites de um pool.',
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node'), poolid => $poolid },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $data = PVE::MMTools::PoolLimits->pool_status($param->{poolid});
        my $rpcenv = PVE::RPCEnvironment->get();
        my $user = $rpcenv->get_user();
        $data->{can_edit} = eval { $rpcenv->check($user, '/', ['Sys.Modify'], 1) } ? 1 : 0;
        return $data;
    },
});

__PACKAGE__->register_method({
    name => 'update_limits', path => '{poolid}', method => 'PUT', proxyto => 'node',
    protected => 1,
    permissions => { check => ['perm', '/', ['Sys.Modify']] },
    description => 'Grava os limites de CPU, RAM e disco de um pool.',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'), poolid => $poolid,
            %{ _limits_properties() },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my ($cfg, $digest) = MMPve::Core::Config->load;
        my $old = $cfg->{poollimits}{pools}{ $param->{poolid} } || {
            mode => 'allocated', cpu => { enabled => 0 }, memory_mib => { enabled => 0 },
            disk_total_gib => { enabled => 0 }, disk_storage => { enabled => 0 },
        };
        my $value = { %{$old} };
        for my $key (qw(mode cpu memory_mib disk_total_gib disk_storage)) {
            $value->{$key} = $param->{$key} if exists $param->{$key};
        }
        my $p = ref($cfg->{poollimits}) eq 'HASH' ? { %{ $cfg->{poollimits} } } : { pools => {} };
        $p->{pools} = { %{ $p->{pools} || {} }, $param->{poolid} => $value };
        my %opt = (resources => PVE::MMTools::PoolLimits->resource_catalog);
        MMPve::Module::Poollimits->prune_missing($p, $opt{resources}, $param->{poolid});
        $opt{digest} = $param->{digest} if defined($param->{digest});
        my ($saved, $new_digest) = MMPve::Core::Config->save_section('poollimits', $p, %opt);
        return { revision => $saved->{revision}, digest => $new_digest,
            poolid => $param->{poolid}, limits => $saved->{poollimits}{pools}{ $param->{poolid} } };
    },
});

1;
