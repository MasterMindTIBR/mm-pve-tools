#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib', 'perl';
use MMPve::Core::Config;
use MMPve::Module::Branding;

my $tmp = tempdir('mm-pve-branding-off-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;

my $cfg = MMPve::Core::Config->default;
$cfg->{modules}{branding} = 0;
MMPve::Core::Config->save($cfg);

my $M = 'MMPve::Module::Branding';
my $json = "$tmp/usr/share/pve-manager/js/mm-branding.json";
my $check = $M->check($cfg);
is($check->{enabled}, 0, 'branding desligado');
is($check->{applied}, 0, 'sem JSON o estado desligado ainda não foi aplicado');
is($check->{serves_asset}, 0, 'branding desligado não serve asset');

make_path("$tmp/usr/share/pve-manager/js");
open(my $fh, '>', $json) or die "open $json: $!";
print {$fh} "{}\n";
close($fh) or die "close $json: $!";
is($M->check($cfg)->{applied}, 0, 'JSON residual torna o estado desligado pendente');

$M->revert;
ok(-e $json, 'revert escreve JSON estático');
is(decode_json(MMPve::Core::Util::read_file($json))->{enabled}, 0,
    'JSON estático marca branding desligado');
is($M->check($cfg)->{applied}, 1, 'revert volta ao estado desligado aplicado');

done_testing();
