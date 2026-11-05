#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use MMPve::Core::Patch;

my $root = shift @ARGV;
die "uso: $0 ROOT\n" unless defined($root) && !@ARGV;
$ENV{MM_PVE_ROOT} = $root;
require "$Bin/../lib/TestPatchFixture.pm";
MMPve::Core::Patch->register_module('MMPve::Module::TestPatchFixture');

my $before = MMPve::Core::Patch->check(core => 0);
for my $id (sort keys %{$before}) {
    die "âncora inválida antes do apply: $id ($before->{$id}{status})\n"
        unless $before->{$id}{status} eq 'not_applied';
}
my $applied = MMPve::Core::Patch->apply(core => 0,
    active_modules => { testpatchfixture => 1 }, no_restart => 1, syntax_check => 'never');
die "apply de âncoras falhou\n" unless $applied->{ok};
my $after = MMPve::Core::Patch->check(core => 0);
for my $id (sort keys %{$after}) {
    die "âncora não aplicou: $id ($after->{$id}{status})\n"
        unless $after->{$id}{status} eq 'applied';
}
my $reverted = MMPve::Core::Patch->revert(core => 0, no_restart => 1);
die "revert de âncoras falhou\n" unless $reverted->{ok};
print "ÂNCORA OK owner=libpve-guest-common-perl(AbstractConfig,GuestHelpers),libpve-access-control,libpve-storage-perl,pve-manager/PVE/API2/Pool.pm root=$root\n";
