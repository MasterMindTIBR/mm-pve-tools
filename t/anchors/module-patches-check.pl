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
require "$Bin/../lib/TestPatchFixture.pm";
MMPve::Core::Modules->all;

my $before = MMPve::Core::Patch->check(core => 0);
for my $id (sort keys %{$before}) {
    die "âncora inválida antes do apply: $id ($before->{$id}{status})\n"
        unless $before->{$id}{status} eq 'not_applied';
}
my $applied = MMPve::Core::Patch->apply(
    active_modules => { poollimits => 1 }, no_restart => 1, syntax_check => 'never');
die "apply de âncoras falhou\n" unless $applied->{ok};
my $after = MMPve::Core::Patch->check(core => 0);
for my $id (sort keys %{$after}) {
    die "âncora não aplicou: $id ($after->{$id}{status})\n"
        unless $after->{$id}{status} eq 'applied';
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
}
my $reverted = MMPve::Core::Patch->revert(no_restart => 1);
die "revert de âncoras falhou\n" unless $reverted->{ok};
print "ÂNCORA OK module=poollimits root=$root\n";
