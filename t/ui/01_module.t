#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);

use lib "$Bin/../../lib", "$Bin/../../perl";
use MMPve::Core::Config;
use MMPve::Module::Ui;

my $tmp = tempdir('mm-pve-ui-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;
my $M = 'MMPve::Module::Ui';

subtest 'defaults retrocompatíveis e schema estrito' => sub {
    my $def = MMPve::Core::Config->default;
    is($def->{modules}{ui}, 0, 'ui nasce desligado');
    is_deeply($def->{ui}{console}, { qemu => 'default', lxc => 'default' }, 'defaults por tipo');
    is(scalar MMPve::Core::Config->validate($def), 0, 'default válido');
    my @bad = MMPve::Core::Config->validate({ ui => {
        console => { qemu => 'spice', lxc => 'default' }, hide_subscription_popup => 0,
    } });
    ok(grep(/default, html5, xtermjs, vv/, @bad), 'viewer desconhecido recusado');
    @bad = MMPve::Core::Config->validate({ ui => {
        console => { qemu => 'default', lxc => 'default' }, hide_subscription_popup => 'yes',
    } });
    ok(grep(/booleano/, @bad), 'popup não booleano recusado');
};

subtest 'apply/revert e revisão estática' => sub {
    my $cfg = MMPve::Core::Config->default;
    $cfg->{modules}{ui} = 1;
    $cfg->{ui} = {
        console => { qemu => 'vv', lxc => 'xtermjs' },
        hide_subscription_popup => 1,
    };
    my $r = $M->apply($cfg);
    ok($r->{ok} && $r->{changed}, 'apply grava json');
    my $raw = MMPve::Core::Util::read_file($M->static_path);
    my $j = decode_json($raw);
    is($j->{revision}, 1, 'revision no json');
    is($j->{console}{qemu}, 'vv', 'qemu no json');
    ok($j->{hide_subscription_popup}, 'flag no json');
    is($M->apply($cfg)->{changed}, 0, 'apply idempotente');
    ok($M->revert->{changed}, 'revert remove json');
    ok(!-e $M->static_path, 'json removido');
    is($M->revert->{changed}, 0, 'revert idempotente');
};

subtest 'preferência por usuário usa lock próprio e fallback' => sub {
    my $cfg = MMPve::Core::Config->default;
    $cfg->{ui}{console} = { qemu => 'vv', lxc => 'html5' };
    my $empty = $M->get_user_preference('alice@pam');
    is_deeply($empty, {}, 'usuário sem override começa vazio');
    my $saved = $M->save_user_preference('alice@pam', { qemu => 'xtermjs', lxc => 'cluster' });
    is($saved->{qemu}, 'xtermjs', 'qemu salvo');
    ok(!exists $saved->{lxc}, 'lxc default não é persistido');
    is($M->effective($cfg, $saved, 'qemu'), 'xtermjs', 'usuário vence cluster');
    is($M->effective($cfg, $saved, 'lxc'), 'html5', 'lxc cai no cluster');
    is($M->effective($cfg, { qemu => 'default' }, 'qemu'), 'default', 'default do usuário vence cluster');
    $saved = $M->save_user_preference('alice@pam', { qemu => 'cluster' });
    ok(!exists $saved->{qemu}, 'cluster remove o override do usuário');
    is($M->effective($cfg, $saved, 'qemu'), 'vv', 'cluster faz fallback para o cluster');
    eval { $M->save_user_preference('alice@pam', { qemu => 'spice' }) };
    like($@, qr/default, html5, xtermjs, vv/, 'viewer inválido recusado');
    eval { $M->get_user_preference("bad\nuser") };
    like($@, qr/inválido/, 'principal com controle recusado');
};

done_testing();
