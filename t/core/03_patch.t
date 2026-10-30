#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);

use lib "$Bin/../../lib";
use MMPve::Core::Patch;

my $tmp = tempdir('mm-pve-patch-XXXXXX', TMPDIR => 1, CLEANUP => 1);

sub fresh_root {
    my ($name) = @_;
    my $root = "$tmp/$name";
    make_path("$root/usr/share/pve-manager");
    make_path("$root/usr/share/perl5/PVE/API2");
    copy("$Bin/../fixtures/pve-manager/index.html.tpl", "$root/usr/share/pve-manager/index.html.tpl");
    copy("$Bin/../fixtures/pve-manager/Nodes.pm",       "$root/usr/share/perl5/PVE/API2/Nodes.pm");
    return $root;
}

sub lines_of { my ($f) = @_; open(my $h, '<', $f) or die $!; my @l = <$h>; close $h; return @l }

$ENV{MM_PVE_ROOT} = fresh_root('apply');

subtest 'check inicial: not_applied' => sub {
    my $c = MMPve::Core::Patch->check;
    is($c->{index_tpl}{status}, 'not_applied', 'tpl não aplicado');
    is($c->{nodes_pm}{status},  'not_applied', 'Nodes.pm não aplicado');
};

subtest 'apply aplica as duas linhas' => sub {
    my $r = MMPve::Core::Patch->apply(no_restart => 1);
    ok($r->{ok}, 'ok') or diag explain $r;
    ok($r->{changed}, 'mudou algo');
    is($r->{targets}{index_tpl}{status}, 'applied', 'tpl applied');
    is($r->{targets}{nodes_pm}{status},  'applied', 'Nodes.pm applied');

    my @tpl = lines_of("$ENV{MM_PVE_ROOT}/usr/share/pve-manager/index.html.tpl");
    my ($ins) = grep { /mm-pve-tools/ && /mm-tools\.js/ } @tpl;
    ok($ins, 'linha script inserida');
    my ($prev) = grep { /pvemanagerlib\.js/ } @tpl;
    my $i_ins = first_index(\@tpl, qr/mm-pve-tools/);
    my $i_prev = first_index(\@tpl, qr/pvemanagerlib\.js/);
    is($i_ins, $i_prev + 1, 'inserida logo depois da âncora');

    my @pm = lines_of("$ENV{MM_PVE_ROOT}/usr/share/perl5/PVE/API2/Nodes.pm");
    ok((grep { /^use PVE::API2::MMTools; # mm-pve-tools$/ } @pm), 'use inserido');
    ok((grep { /register_method\(\{ subclass => "PVE::API2::MMTools", path => 'mm-tools' \}\); # mm-pve-tools/ } @pm),
        'register_method inserido');
    # use fica depois do último "use PVE::API2::" ORIGINAL (sem o nosso)
    my @uses = grep { $pm[$_] =~ /^\s*use\s+PVE::API2::\w+(?:::\w+)*;/ && $pm[$_] !~ /MMTools/ } 0 .. $#pm;
    my $last_use = pop @uses;
    my ($i_mm) = grep { $pm[$_] =~ /^use PVE::API2::MMTools;/ } 0 .. $#pm;
    is($i_mm, $last_use + 1, 'use vem logo após o último use PVE::API2');
};

subtest 'apply é idempotente' => sub {
    my $r = MMPve::Core::Patch->apply(no_restart => 1);
    ok($r->{ok}, 'ok');
    ok(!$r->{changed}, 'nada mudou na 2ª vez');
};

subtest 'check aplicado' => sub {
    my $c = MMPve::Core::Patch->check;
    is($c->{index_tpl}{status}, 'applied');
    is($c->{nodes_pm}{status},  'applied');
};

subtest 'revert volta ao original' => sub {
    my $before = "$tmp/before";
    $ENV{MM_PVE_ROOT} = fresh_root('pristine');
    system("cp -r $ENV{MM_PVE_ROOT} $before");
    MMPve::Core::Patch->apply(no_restart => 1);
    my $r = MMPve::Core::Patch->revert(no_restart => 1);
    ok($r->{changed}, 'revert mudou');
    # compara apenas os dois alvos (backup dir é criado fora deles)
    system("cmp -s $before/usr/share/pve-manager/index.html.tpl $ENV{MM_PVE_ROOT}/usr/share/pve-manager/index.html.tpl");
    is($?, 0, 'index.html.tpl idêntico ao original');
    system("cmp -s $before/usr/share/perl5/PVE/API2/Nodes.pm $ENV{MM_PVE_ROOT}/usr/share/perl5/PVE/API2/Nodes.pm");
    is($?, 0, 'Nodes.pm idêntico ao original');
    system("rm -rf $before");
};

subtest 'âncora quebrada → nada muda, status anchor_missing' => sub {
    $ENV{MM_PVE_ROOT} = fresh_root('broken');
    # quebra âncora do tpl
    my $tpl = "$ENV{MM_PVE_ROOT}/usr/share/pve-manager/index.html.tpl";
    system("sed -i '/pvemanagerlib.js/d' $tpl");
    # quebra âncora do Nodes.pm (remove subclass Replication)
    my $pm = "$ENV{MM_PVE_ROOT}/usr/share/perl5/PVE/API2/Nodes.pm";
    system("sed -i '/subclass => \"PVE::API2::Replication\"/d' $pm");

    my $r = MMPve::Core::Patch->apply(no_restart => 1);
    is($r->{targets}{index_tpl}{status}, 'anchor_missing', 'tpl anchor_missing');
    is($r->{targets}{nodes_pm}{status},  'anchor_missing', 'pm anchor_missing');
    ok(!$r->{changed}, 'nada mudou');
    my $c = MMPve::Core::Patch->check;
    is($c->{index_tpl}{status}, 'anchor_missing');
    is($c->{nodes_pm}{status},  'anchor_missing');
};

sub first_index {
    my ($l, $re) = @_;
    for my $i (0 .. $#{$l}) { return $i if $l->[$i] =~ $re }
    return -1;
}

done_testing();
