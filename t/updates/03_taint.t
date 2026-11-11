#!/usr/bin/perl -T
# pvedaemon runs with -T: pruning and rewriting state files whose names came
# from readdir must not die with "Insecure dependency". Seen in the lab once
# more bulks than the retention limit had accumulated.
use strict;
use warnings;
use FindBin qw($Bin);
BEGIN { ($Bin) = $Bin =~ /\A(.*)\z/s; }
use lib "$Bin/../../lib", "$Bin/../../perl", "$Bin/../lib-stubs";
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use Test::More;

$ENV{PATH} = '/usr/bin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
my ($tmp) = tempdir('mm-pve-taint-XXXXXX', TMPDIR => 1, CLEANUP => 1) =~ /\A(.*)\z/s;
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;
require MMPve::Module::Updates;
my $dir = MMPve::Module::Updates::state_dir();
require File::Path;
File::Path::make_path($dir);
for my $i (1 .. 14) {
    my $id = sprintf('%08d-0000-4000-8000-%012d', $i, $i);
    open(my $fh, '>', "$dir/bulk-$id.json") or die $!;
    print {$fh} encode_json({ id => $id, state => 'running', created_epoch => $i, heartbeat_epoch => 1, nodes => ['n1'] });
    close($fh);
}
ok(eval { MMPve::Module::Updates::_prune_bulk(5); 1 }, 'bulk prune survives taint mode') or diag $@;
opendir(my $dh, $dir) or die $!;
my @left = grep { /^bulk-/ } readdir($dh);
closedir($dh);
is(scalar(@left), 5, 'prune kept the retention count');
ok(eval { MMPve::Core::Config->with_domain_lock('updates-bulk', sub { MMPve::Module::Updates::_bulk_files_locked() }); 1 },
    'stale bulks are rewritten as lost in taint mode') or diag $@;
done_testing;
