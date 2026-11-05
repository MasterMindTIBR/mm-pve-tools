#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use MMPve::Core::Patch;
use MMPve::Core::Modules;

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
my $reverted = MMPve::Core::Patch->revert(no_restart => 1);
die "revert de âncoras falhou\n" unless $reverted->{ok};
print "ÂNCORA OK module=poollimits root=$root\n";
