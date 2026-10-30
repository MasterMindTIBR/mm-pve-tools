#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

use lib "$Bin/../../lib";
use MMPve::Core::Status;

my $tmp = tempdir('mm-pve-status-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_ROOT} = "$tmp";
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";

subtest 'collect com runner falso' => sub {
    no warnings 'once';
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($argv) = @_;
        if ($argv->[0] eq 'dpkg-query')   { return { rc => 0, out => "test-version-1\n" } }
        if ($argv->[0] eq 'pvesh')        { return { rc => 0, out => '{"version":"9.2.24"}' } }
        if ($argv->[0] eq 'pve-file-restore-ntfs3g-check') {
            return {
                rc => 0,
                out => '{"ok":true,"file_restore":{"version":"4.2.8-1+ntfs3g1","patched":true},'
                    . '"restore_image":{"version":"1.0.0+ntfs3g2","ntfs3g":true,"dedup_plugin":true},'
                    . '"initramfs_cache_fresh":true}',
            };
        }
        return { rc => 1, out => '', err => 'comando não simulado' };
    };
    my $s = MMPve::Core::Status->collect;
    is($s->{package_version}, 'test-version-1', 'versão do pacote');
    is($s->{pve_version}, '9.2.24', 'versão do PVE');
    ok($s->{node}, 'node presente');
    ok($s->{ntfs3g}{ok}, 'ntfs3g ok (contrato do meta-pacote)');
    ok($s->{ntfs3g}{file_restore}{patched}, 'file_restore patched');
    ok($s->{ntfs3g}{initramfs_cache_fresh}, 'initramfs fresco');
    ok($s->{applied}{state}, 'estado de apply presente');
    for my $m (qw(renumber restore branding)) {
        ok(exists $s->{modules}{$m}, "check do módulo $m");
    }
};

subtest 'ntfs3g-check falho degrada sem explodir' => sub {
    no warnings 'once';
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($argv) = @_;
        return { rc => 0, out => 'x' } if $argv->[0] eq 'dpkg-query';
        return { rc => 0, out => '{}' } if $argv->[0] eq 'pvesh';
        return { rc => 1, out => '', err => 'boom' };
    };
    my $s = MMPve::Core::Status->collect;
    ok(!$s->{ntfs3g}{ok}, 'ntfs3g not ok');
    like($s->{ntfs3g}{error}, qr/boom|rc=1/, 'erro registrado');
};

done_testing();
