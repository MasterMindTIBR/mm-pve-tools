#!/usr/bin/env perl
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use lib "$Bin";
use TestAPI;
use Test::More;

TestAPI::setup_inc();
my ($real, $why) = TestAPI::real_pve();
plan skip_all => "PVE real não disponível: $why" unless $real;

require MMPve::Core::Config;
require MMPve::Core::Status;
require MMPve::Module::Restore;

my $tmp = tempdir('mm-api-config-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;

my %sections = (
    modules => { renumber => 1, restore => 1, branding => 0 },
    vmid_scheme => [{ label => 'Lab', from => 1000, to => 1999 }],
    restore => {
        gateway_vmid => 9000, vlans => { 120 => { gw_ip => '10.20.120.250', prefix => 24 } },
        session_default_hours => 24, session_max_hours => 168, max_sessions => 10,
    },
    branding => { title => 'MasterMind', header_text => '', login_text => '', logo => '', favicon => '', assets_hash => '' },
);
my $digest;
for my $section (qw(modules vmid_scheme restore branding)) {
    my ($saved, $new_digest) = MMPve::Core::Config->save_section($section, $sections{$section});
    ok($new_digest && $new_digest ne ($digest // ''), "primeira gravação de $section sem digest");
    $digest = $new_digest;
}
my ($cfg, $actual) = MMPve::Core::Config->load;
is_deeply($cfg->{$_}, $sections{$_}, "seção $_ preservada") for keys %sections;
is($cfg->{revision}, 5, 'servidor calculou revision para cada seção');

eval { MMPve::Core::Config->save_section('branding', { title => 'stale' }, digest => 'sha256:' . ('0' x 64)) };
like($@, qr/DIGEST_MISMATCH/, 'digest velho chega como DIGEST_MISMATCH');

{
    require PVE::Cluster;
    local $ENV{MM_PVE_DISABLE_CFS_LOCK};
    no warnings 'redefine';
    local *PVE::Cluster::cfs_lock_domain = sub { $@ = "cfs-lock test\n"; return undef };
    eval { MMPve::Core::Config->save_section('branding', $sections{branding}) };
    like($@, qr/cfs-lock test/, 'erro de cfs_lock_domain não é engolido');
}

my $seen;
{
    no warnings 'redefine';
    local *MMPve::Module::Restore::check = sub {
        my ($class, $got) = @_;
        $seen = $got;
        return { ok => 1 };
    };
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($argv) = @_;
        return { rc => 0, out => 'test-version\n' } if $argv->[0] eq 'dpkg-query';
        return { rc => 0, out => '{"version":"9.2.24"}' } if $argv->[0] eq 'pvesh';
        return { rc => 1, out => '', err => 'skip' };
    };
    MMPve::Core::Status->collect(skip_ntfs3g => 1);
}
is($seen->{branding}{title}, 'MasterMind', 'Status passa o config real ao check do módulo');

done_testing();
