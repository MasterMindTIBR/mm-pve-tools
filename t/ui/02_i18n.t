use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $repo = "$Bin/../..";
# The guard is a node script; make lint (which has node) always runs it.
# The Debian package build has no node, so skip there instead of failing.
plan skip_all => 'node not available' unless grep { -x "$_/node" } split /:/, ($ENV{PATH} // '');
my $output = `cd "$repo" && scripts/check-ui-i18n.sh 2>&1`;
is($? >> 8, 0, 'GUI i18n catalog/source guard passes') or diag $output;
like($output, qr/UI i18n catalogs OK: \d+ keys/, 'guard reports catalog key count') if $? >> 8 == 0;

done_testing;
