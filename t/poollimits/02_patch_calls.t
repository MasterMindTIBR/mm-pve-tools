#!/usr/bin/perl -T
use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Test::More;

my ($lib, $perl);
BEGIN {
    ($lib) = "$Bin/../../lib" =~ /\A(.*)\z/s;
    ($perl) = "$Bin/../../perl" =~ /\A(.*)\z/s;
}
use lib $lib, $perl;
use MMPve::Core::Modules;
use MMPve::Core::Patch;
use MMPve::Module::Poollimits;

BEGIN {
    package PVE::MMTools::PoolLimits;
    our @CALLS;
    sub _record { my ($name, @args) = @_; push @CALLS, [$name, @args]; return 1 }
    sub check_write_config { my $class = shift; return _record('check_write_config', @_); }
    sub check_start { my $class = shift; return _record('check_start', @_); }
    sub check_pool_entry { my $class = shift; return _record('check_pool_entry', @_); }
    sub check_qemu_create { my $class = shift; return _record('check_qemu_create', @_); }
    sub check_lxc_create { my $class = shift; return _record('check_lxc_create', @_); }
    sub check_clone { my $class = shift; return _record('check_clone', @_); }
    sub check_pool_update { my $class = shift; return _record('check_pool_update', @_); }
    $INC{'PVE/MMTools/PoolLimits.pm'} = __FILE__;
}

my $scratch = $ENV{MM_PVE_UPSTREAM_ROOT};
if (!defined($scratch) || !-d $scratch) {
    my @candidates = glob('/tmp/claude-1000/*/*/scratchpad/pve/x');
    ($scratch) = grep { -d $_ } @candidates;
}
plan skip_all => 'upstream PVE extraído não disponível' unless defined($scratch);

my %source = (
    'libpve-guest-common-perl' => {
        '/usr/share/perl5/PVE/AbstractConfig.pm' => "$scratch/libpve-guest-common-perl/usr/share/perl5/PVE/AbstractConfig.pm",
        '/usr/share/perl5/PVE/GuestHelpers.pm' => "$scratch/libpve-guest-common-perl/usr/share/perl5/PVE/GuestHelpers.pm",
    },
    'libpve-access-control' => {
        '/usr/share/perl5/PVE/AccessControl.pm' => "$scratch/libpve-access-control/usr/share/perl5/PVE/AccessControl.pm",
    },
    'qemu-server' => {
        '/usr/share/perl5/PVE/API2/Qemu.pm' => "$scratch/qemu-server/usr/share/perl5/PVE/API2/Qemu.pm",
    },
    'pve-container' => {
        '/usr/share/perl5/PVE/API2/LXC.pm' => "$scratch/pve-container/usr/share/perl5/PVE/API2/LXC.pm",
    },
    'pve-manager' => {
        '/usr/share/perl5/PVE/API2/Pool.pm' => "$scratch/pve-manager/usr/share/perl5/PVE/API2/Pool.pm",
    },
);

my $tmp = tempdir('mm-pve-patch-call-XXXXXX', TMPDIR => 1, CLEANUP => 1);
for my $target (@{MMPve::Module::Poollimits->patch_targets}) {
    my $src = $source{$target->{owner}}{$target->{path}};
    plan skip_all => "upstream ausente: $src" unless defined($src) && -f $src;
    my $path = "$tmp$target->{path}";
    (my $dir = $path) =~ s{/[^/]+$}{};
    make_path($dir);
    ok(copy($src, $path), "$target->{id}: copia upstream");
}

local $ENV{MM_PVE_ROOT} = $tmp;
MMPve::Core::Modules->all;
my $applied = MMPve::Core::Patch->apply(
    core => 0, active_modules => { poollimits => 1 },
    no_restart => 1, syntax_check => 'never',
);
ok($applied->{ok}, 'todos os alvos reais aplicados') or diag explain $applied;

my ($class, $vmid, $conf, $phase, $param, $archive, $storecfg, $pool, $newid,
    $oldconf, $storage_cfg, $src_conf, $snapname, $usercfg, $qemu_type, $lxc_type);
my %vars = (
    abstract_config_write => [check_write_config => [\$class, \$vmid, \$conf],
        sub { ($class, $vmid, $conf) = ('PVE::QemuConfig', 101, { vcpus => 2 }) }],
    guest_helpers_start => [check_start => [\$conf, \$vmid, \$phase],
        sub { ($conf, $vmid, $phase) = ({ vcpus => 2 }, 101, 'pre-start') }],
    access_control_pool => [check_pool_entry => [\$vmid, \$pool],
        sub { ($vmid, $pool) = (101, 'lab') }],
    qemu_create_pool => [check_qemu_create => [\$param, \$archive, \$storecfg, \$vmid, \$pool],
        sub { ($param, $archive, $storecfg, $vmid, $pool) = ({ vcpus => 2 }, { type => 'file' }, { ids => {} }, 101, 'lab') }],
    qemu_clone_pool => [check_clone => [\$newid, \$pool, \$oldconf, \$qemu_type],
        sub { ($newid, $pool, $oldconf, $qemu_type) = (102, 'lab', { vcpus => 2 }, 'qemu') }],
    lxc_create_pool => [check_lxc_create => [\$param, \$archive, \$storage_cfg, \$vmid, \$pool],
        sub { ($param, $archive, $storage_cfg, $vmid, $pool) = ({ cores => 2 }, 'backup.tar', { ids => {} }, 201, 'lab') }],
    lxc_clone_pool => [check_clone => [\$newid, \$pool, \$src_conf, \$lxc_type, \$snapname],
        sub { ($newid, $pool, $src_conf, $lxc_type, $snapname) = (202, 'lab', { cores => 2 }, 'lxc', 'snap0') }],
    pool_update => [check_pool_update => [\$param, \$usercfg],
        sub { ($param, $usercfg) = ({ poolid => 'lab', vms => '101' }, { pools => {} }) }],
);

for my $target (@{MMPve::Module::Poollimits->patch_targets}) {
    my $path = "$tmp$target->{path}";
    open(my $fh, '<', $path) or die "ler $path: $!";
    my @lines = <$fh>;
    close($fh);
    my ($line) = grep { index($_, $target->{line}) >= 0 } @lines;
    ok(defined($line), "$target->{id}: linha inserida é a linha real") or next;
    ($line) = $line =~ /\A([ \t]*\Q$target->{line}\E\n)\z/;
    ok(defined($line), "$target->{id}: linha real validada para perl -T") or next;
    my ($method, $expected, $init) = @{ $vars{$target->{id}} };
    $init->();
    @PVE::MMTools::PoolLimits::CALLS = ();
    my $ok = eval "no strict; $line";
    ok($ok && !$@, "$target->{id}: sintaxe exata executa") or diag $@;
    is(scalar(@PVE::MMTools::PoolLimits::CALLS), 1, "$target->{id}: uma chamada") or next;
    my $call = $PVE::MMTools::PoolLimits::CALLS[0];
    is($call->[0], $method, "$target->{id}: método correto");
    is(scalar(@{$call}) - 1, scalar(@{$expected}), "$target->{id}: quantidade de argumentos");
    for my $i (0 .. $#{$expected}) {
        is($call->[$i + 1], ${ $expected->[$i] }, "$target->{id}: argumento " . ($i + 1));
    }
}

done_testing();
