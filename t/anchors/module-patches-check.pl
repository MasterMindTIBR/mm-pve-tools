#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use MMPve::Core::Patch;
use MMPve::Core::Modules;
use MMPve::Module::Poollimits;
use ModulePatchGuards;

my $root = shift @ARGV;
die "uso: $0 ROOT\n" unless defined($root) && !@ARGV;
$ENV{MM_PVE_ROOT} = $root;
my $set = $ENV{MM_PVE_ANCHOR_SET} // 'unknown';
require "$Bin/../lib/TestPatchFixture.pm";
MMPve::Core::Modules->all;

my $before = MMPve::Core::Patch->check(core => 0);
for my $id (sort keys %{$before}) {
    next if $before->{$id}{status} eq 'not_applied';
    my $error = $before->{$id}{error} // $before->{$id}{note} // '';
    warn "target $id: $before->{$id}{status} $error\n";
    die "ANCHOR SET=$set target=$id reason=invalid anchor before apply\n";
}
my $applied = MMPve::Core::Patch->apply(
    core => 0, active_modules => { poollimits => 1 }, no_restart => 1,
    syntax_check => ($ENV{MM_PVE_ANCHOR_SYNTAX} // 'never'));
unless ($applied->{ok}) {
    my @groups = ({ module => '__core__', targets => $applied->{targets} || {} });
    push @groups, map { { module => $_, targets => $applied->{modules}{$_}{targets} || {} } }
        sort keys %{ $applied->{modules} || {} };
    for my $group (@groups) {
        for my $id (sort keys %{ $group->{targets} }) {
            my $t = $group->{targets}{$id};
            next if ($t->{status} // '') eq 'applied';
            warn "target $id: " . ($t->{status} // '?') . ' ' . ($t->{error} // '') . "\n";
        }
    }
    die "ANCHOR SET=$set target=poollimits reason=anchor apply failed\n";
}
my $after = MMPve::Core::Patch->check(core => 0);
for my $id (sort keys %{$after}) {
    next if $after->{$id}{status} eq 'applied';
    my $error = $after->{$id}{error} // $after->{$id}{note} // '';
    warn "target $id: $after->{$id}{status} $error\n";
    die "ANCHOR SET=$set target=$id reason=anchor did not apply\n";
}
for my $target (@{MMPve::Module::Poollimits->patch_targets}) {
    my $path = "$root$target->{path}";
    open(my $fh, '<', $path) or die "ler $path: $!\n";
    my @lines = <$fh>;
    close($fh);
    my @inserted = grep { $lines[$_] eq $target->{line} . "\n" } 0 .. $#lines;
    die "inserção não única: $target->{id}\n" unless @inserted == 1;
    my @errors = ModulePatchGuards::check_target($target, \@lines, $inserted[0]);
    die "guard de posição/declaracao falhou: $target->{id}: " . join('; ', @errors) . "\n"
        if @errors;
    my @static_errors = MMPve::Core::Patch->static_check_target($target, \@lines, $inserted[0]);
    die "ANCHOR SET=$set target=$target->{id} reason=" . join('; ', @static_errors) . "\n"
        if @static_errors;
}
my $reverted = MMPve::Core::Patch->revert(core => 0, no_restart => 1,
    syntax_check => ($ENV{MM_PVE_ANCHOR_SYNTAX} // 'never'));
unless ($reverted->{ok}) {
    for my $id (sort keys %{ $reverted->{targets} || {} }) {
        my $t = $reverted->{targets}{$id};
        warn "target $id: " . ($t->{status} // '?') . ' ' . ($t->{error} // '') . "\n";
    }
    for my $m (sort keys %{ $reverted->{modules} || {} }) {
        my $g = $reverted->{modules}{$m};
        warn "module $m: ok=" . ($g->{ok} // '?') . ' ' . ($g->{error} // '') . "\n";
    }
    die "anchor revert failed\n";
}
print "ÂNCORA OK module=poollimits root=$root\n";
