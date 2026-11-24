#!/usr/bin/perl
# Upgrade from a release whose inserted line had another text (explicit
# arguments) to one that uses @_: apply must leave exactly one current call,
# check must not call the old/duplicated state "applied", and revert must
# remove every version. Seen in the lab: Storage.pm kept both calls after the
# package upgrade, the vdisk_alloc hook ran twice and an add disk inside the
# pool limit was refused.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../lib", "$Bin/../../perl";
use Test::More;

require MMPve::Core::Modules;
require MMPve::Core::Patch;
MMPve::Core::Modules->all;
my ($target) = grep { $_->{id} eq 'storage_vdisk_alloc' } values %{ MMPve::Core::Patch->targets };
ok($target, 'storage_vdisk_alloc target is registered') or BAIL_OUT('no target');

my $current = "$target->{line}\n";
my $old = "    eval { require PVE::MMTools::PoolLimits; 1 } && PVE::MMTools::PoolLimits->check_storage_alloc(\$cfg, \$storeid, \$vmid, \$fmt, \$name, \$size);\n";
my $head = "package PVE::Storage;\n\nsub vdisk_alloc {\n    my (\$cfg, \$storeid, \$vmid, \$fmt, \$name, \$size) = \@_;\n";
my $tail = "\n    die \"no storage ID specified\\n\" if !\$storeid;\n    \$vmid = parse_vmid(\$vmid);\n    return 1;\n}\n1;\n";
my $old_only = $head . "\n    die \"no storage ID specified\\n\" if !\$storeid;\n    \$vmid = parse_vmid(\$vmid);\n" . $old . "    return 1;\n}\n1;\n";
my $both = $head . $current . "\n    die \"no storage ID specified\\n\" if !\$storeid;\n    \$vmid = parse_vmid(\$vmid);\n" . $old . "    return 1;\n}\n1;\n";
my $clean = $head . $current . $tail;

for my $case ([old_only => $old_only], [both => $both], [clean => $clean]) {
    my ($name, $raw) = @{$case};
    my $res = MMPve::Core::Patch->_generic_desired($target, $raw);
    ok($res->{ok}, "$name: desired content computed");
    my @calls = grep { /PoolLimits->check_storage_alloc\(/ } split(/^/, $res->{content});
    is(scalar(@calls), 1, "$name: exactly one call after apply");
    is($calls[0], $current, "$name: the call is the current line");
    is($res->{content}, $clean, "$name: the call sits right after the argument unpacking");
}

for my $case ([old_only => $old_only], [both => $both]) {
    my ($name, $raw) = @{$case};
    my $rev = MMPve::Core::Patch->_revert_content($target, $raw);
    unlike($rev->{content}, qr/PoolLimits->check_storage_alloc/, "$name: revert removes every version");
}
done_testing;
