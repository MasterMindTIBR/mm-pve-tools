#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use lib "$Bin";
use TestAPI;
use Test::More;

TestAPI::setup_inc();
my ($real, $why) = TestAPI::real_pve();
plan skip_all => "PVE real não disponível: $why" unless $real;

require MMPve::Core::Config;
require MMPve::Module::Ui;
require PVE::API2::MMTools::Ui;

my $tmp = tempdir('mm-api-ui-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;

my $cfg = MMPve::Core::Config->default;
$cfg->{modules}{ui} = 1;
$cfg->{ui} = {
    console => { qemu => 'vv', lxc => 'xtermjs' },
    hide_subscription_popup => 1,
};
MMPve::Core::Config->save($cfg);

ok(PVE::API2::MMTools::Ui->can('method_attributes'), 'classe API UI é RESTHandler real');
my $attrs = PVE::API2::MMTools::Ui->method_attributes;
my @attrs = @{$attrs};
my ($get) = grep { $_->{name} eq 'preference' } @attrs;
my ($put) = grep { $_->{name} eq 'set_preference' } @attrs;
ok($get && $put, 'GET e PUT de preferência registrados');
is($get->{permissions}{user}, 'all', 'GET aceita qualquer usuário autenticado');
is($put->{permissions}{user}, 'all', 'PUT aceita qualquer usuário autenticado');
ok(!$put->{parameters}{properties}{user}, 'PUT não recebe user do cliente');
ok($put->{parameters}{properties}{qemu}{enum}, 'PUT limita viewer QEMU pelo schema real');
ok(grep { $_ eq 'cluster' } @{$put->{parameters}{properties}{qemu}{enum}},
    'PUT aceita cluster para remover o override');

my $saved = MMPve::Module::Ui->save_user_preference('owner@pam', { qemu => 'html5' });
my $effective = MMPve::Module::Ui->effective($cfg, $saved, 'qemu');
is($effective, 'html5', 'preferência do principal vence cluster');
is(MMPve::Module::Ui->effective($cfg, $saved, 'lxc'), 'xtermjs', 'tipo sem override cai no cluster');
my $raw = MMPve::Core::Util::read_file(MMPve::Module::Ui->users_path);
unlike($raw, qr/!ci|(?:password|secret|token|api[_-]?key)/i,
    'arquivo não recebe credencial nem token');

{
    package TestAPIUiRPC;
    sub new { bless {}, shift }
    sub get_user { return 'owner@pve!tok' }
}

MMPve::Module::Ui->save_user_preference('owner@pve', { qemu => 'html5' });
{
    no warnings qw(once redefine);
    local *PVE::RPCEnvironment::get = sub { return TestAPIUiRPC->new }; 
    my $read = $get->{code}->({ node => 'localhost' });
    is($read->{user}, 'owner@pve', 'token principal é normalizado para o dono no GET');
    is($read->{preference}{qemu}, 'html5', 'GET lê a preferência do dono do token');

    my $write = $put->{code}->({ node => 'localhost', qemu => 'xtermjs' });
    is($write->{user}, 'owner@pve', 'token principal é normalizado para o dono no PUT');
    is($write->{preference}{qemu}, 'xtermjs', 'PUT grava a preferência do dono do token');
    is(MMPve::Module::Ui->get_user_preference('owner@pve')->{qemu}, 'xtermjs',
        'arquivo de preferências usa owner@pve');
    ok(!-e MMPve::Module::Ui->users_path ||
        MMPve::Core::Util::read_file(MMPve::Module::Ui->users_path) !~ /owner\@pve!tok/,
        'arquivo não cria chave com o token');

    my $reset = $put->{code}->({ node => 'localhost', qemu => 'cluster' });
    is($reset->{preference}{qemu}, 'cluster', 'cluster remove o override no PUT real');
    ok(!exists MMPve::Module::Ui->get_user_preference('owner@pve')->{qemu},
        'cluster faz o usuário seguir o cluster');
}

done_testing();
