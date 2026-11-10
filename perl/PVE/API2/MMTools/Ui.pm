package PVE::API2::MMTools::Ui;

# Preferência da interface do usuário autenticado. A rota não aceita user/id:
# o principal vem exclusivamente do RPCEnvironment do PVE.

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::AccessControl;
use PVE::RESTHandler;
use PVE::RPCEnvironment;

use MMPve::Core::Config;
use MMPve::Module::Ui;

use base qw(PVE::RESTHandler);

my @VIEWERS = qw(cluster default html5 xtermjs vv);

sub _user {
    my $rpcenv = PVE::RPCEnvironment->get();
    my $user = $rpcenv->get_user();
    die "usuário autenticado ausente\n" unless defined $user && length $user;
    if (index($user, '!') >= 0) {
        my ($owner) = PVE::AccessControl::split_tokenid($user, 1);
        $user = $owner if defined $owner && length $owner;
    }
    return $user;
}

sub _response {
    my ($user, $cfg, $pref) = @_;
    my $ui = $cfg->{ui} || {};
    my $console = $ui->{console} || {};
    return {
        preference => {
            qemu => $pref->{qemu} // 'cluster',
            lxc  => $pref->{lxc}  // 'cluster',
        },
        effective => {
            qemu => MMPve::Module::Ui->effective($cfg, $pref, 'qemu'),
            lxc  => MMPve::Module::Ui->effective($cfg, $pref, 'lxc'),
        },
        cluster => {
            qemu => $console->{qemu} // 'default',
            lxc  => $console->{lxc}  // 'default',
            hide_subscription_popup => $ui->{hide_subscription_popup} ? 1 : 0,
        },
        user => $user,
    };
}

__PACKAGE__->register_method({
    name => 'preference', path => '', method => 'GET', proxyto => 'node',
    permissions => { user => 'all' },
    description => 'Lê apenas a preferência de console do usuário autenticado.',
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object' },
    code => sub {
        my $user = _user();
        my ($cfg) = MMPve::Core::Config->load;
        my $pref = MMPve::Module::Ui->get_user_preference($user);
        return _response($user, $cfg, $pref);
    },
});

__PACKAGE__->register_method({
    name => 'set_preference', path => 'preference', method => 'PUT', proxyto => 'node',
    permissions => { user => 'all' },
    description => 'Grava somente a preferência do usuário autenticado.',
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            qemu => { type => 'string', optional => 1, enum => \@VIEWERS },
            lxc  => { type => 'string', optional => 1, enum => \@VIEWERS },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $user = _user();
        my ($cfg) = MMPve::Core::Config->load;
        my %input = map { $_ => $param->{$_} } grep { exists $param->{$_} } qw(qemu lxc);
        my $pref = MMPve::Module::Ui->save_user_preference($user, \%input);
        return _response($user, $cfg, $pref);
    },
});

1;
