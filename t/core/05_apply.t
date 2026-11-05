#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json encode_json);

use lib "$Bin/../../lib", "$Bin/../../perl";
use MMPve::Core::Apply;
use MMPve::Core::Patch;
use MMPve::Core::Util qw(write_file_atomic);

my $tmp = tempdir('mm-pve-apply-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_ROOT} = "$tmp";
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";

subtest 'apply sem config → default, tudo ok, estado gravado' => sub {
    my $r = MMPve::Core::Apply->apply_all(patches => 0);
    ok($r->{ok}, 'ok') or diag explain $r;
    is($r->{revision}, 1, 'revision default');
    ok(-f "$tmp/var/lib/mm-pve-tools/applied.json", 'applied.json gravado');
    for my $m (qw(renumber restore branding)) {
        ok(exists $r->{modules}{$m}, "módulo $m processado");
        ok($r->{modules}{$m}{ok}, "$m ok");
    }
    # default: renumber ligado, restore/branding desligados
    is($r->{modules}{renumber}{enabled}, 1, 'renumber ligado');
    is($r->{modules}{restore}{enabled},  0, 'restore desligado');
};

subtest 'status reflete aplicado' => sub {
    my $s = MMPve::Core::Apply->status;
    is($s->{state}, 'applied', 'aplicado');
    is($s->{applied_revision}, $s->{config_revision}, 'revisões iguais');
};

subtest 'revision nova → pending' => sub {
    my ($cfg, $digest) = MMPve::Core::Config->load;
    $cfg->{modules}{renumber} = 1;
    MMPve::Core::Config->save($cfg, digest => $digest);
    my $s = MMPve::Core::Apply->status;
    is($s->{state}, 'pending', 'pendente após mudança');
    MMPve::Core::Apply->apply_all(patches => 0);
    is(MMPve::Core::Apply->status->{state}, 'applied', 'aplica e volta');
};

subtest 'módulo com falha → erro com mensagem' => sub {
    no warnings 'once', 'redefine';
    local *MMPve::Module::Renumber::apply = sub { die "falha simulada\n" };
    my $r = MMPve::Core::Apply->apply_all(patches => 0);
    ok(!$r->{ok}, 'apply com erro');
    like($r->{modules}{renumber}{error}, qr/falha simulada/, 'mensagem propagada');
    is(MMPve::Core::Apply->status->{state}, 'error', 'status erro');
};

subtest 'módulo desligado roda revert' => sub {
    no warnings 'once', 'redefine';
    my $revertiu = 0;
    local *MMPve::Module::Branding::revert = sub { $revertiu++; { ok => 1 } };
    MMPve::Core::Apply->apply_all(patches => 0);
    ok($revertiu, 'revert chamado p/ branding desligado');
};

subtest 'versão instalada diferente exige reload mesmo sem patch novo' => sub {
    write_file_atomic(MMPve::Core::Apply->state_path, encode_json({
        package_version => 'versao-anterior', revision => 1, modules => {},
    }) . "\n");
    my $reloads = 0;
    no warnings 'redefine';
    local $MMPve::Core::Apply::VERSION = 'versao-atual';
    local *MMPve::Core::Patch::apply = sub { return { ok => 1, changed => 0 } };
    local *MMPve::Core::Patch::reload_services = sub { $reloads++; return { ok => 1 } };
    my $r = MMPve::Core::Apply->apply_all(patches => 1);
    ok($r->{reload_required}, 'version_changed exige reload');
    is($reloads, 1, 'reload executado uma vez');
};

done_testing();
