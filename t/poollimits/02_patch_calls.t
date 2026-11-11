#!/usr/bin/perl -T
use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Test::More;

my ($lib, $perl, $testlib);
BEGIN {
    ($lib) = "$Bin/../../lib" =~ /\A(.*)\z/s;
    ($perl) = "$Bin/../../perl" =~ /\A(.*)\z/s;
    ($testlib) = "$Bin/../lib" =~ /\A(.*)\z/s;
}
use lib $lib, $perl, $testlib;
use MMPve::Core::Modules;
use MMPve::Core::Patch;
use MMPve::Module::Poollimits;
use ModulePatchGuards;

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
    sub check_storage_alloc { my $class = shift; return _record('check_storage_alloc', @_); }
    sub check_storage_clone { my $class = shift; return _record('check_storage_clone', @_); }
    sub check_storage_resize { my $class = shift; return _record('check_storage_resize', @_); }
    sub check_storage_import { my $class = shift; return _record('check_storage_import', @_); }
    $INC{'PVE/MMTools/PoolLimits.pm'} = __FILE__;
}

my $scratch = $ENV{MM_PVE_UPSTREAM_ROOT};
plan skip_all => 'upstream ausente; make check-anchors executa este teste com fontes PVE'
    unless defined($scratch) && -d $scratch;

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
    'libpve-storage-perl' => {
        '/usr/share/perl5/PVE/Storage.pm' => "$scratch/libpve-storage-perl/usr/share/perl5/PVE/Storage.pm",
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

sub read_lines {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "ler $path: $!";
    my @lines = <$fh>;
    close($fh);
    return \@lines;
}

sub inserted_index {
    my ($target, $lines) = @_;
    my @found = grep { $lines->[$_] eq $target->{line} . "\n" } 0 .. $#{$lines};
    return $found[0] if @found == 1;
    return undef;
}

subtest 'guard rejeita a definição antiga sem escopo de vdisk_clone' => sub {
    my ($target) = grep { $_->{id} eq 'storage_vdisk_clone' }
        @{MMPve::Module::Poollimits->patch_targets};
    my $path = $source{$target->{owner}}{$target->{path}};
    my $lines = read_lines($path);
    my %wrong = %{$target};
    delete $wrong{scope_anchor};
    my $anchor = MMPve::Core::Patch->_anchor_index(\%wrong, $lines);
    ok(defined($anchor), 'a definição antiga ainda encontraria uma ocorrência');
    splice @{$lines}, $anchor + 1, 0, $target->{line} . "\n" if defined($anchor);
    my @errors = ModulePatchGuards::check_target(\%wrong, $lines, $anchor + 1);
    ok(@errors, 'guard falha na definição antiga e não deixa o teste ficar verde')
        or diag join('; ', @errors);
};

local $ENV{MM_PVE_ROOT} = $tmp;
MMPve::Core::Modules->all;
my $applied = MMPve::Core::Patch->apply(
    core => 0, active_modules => { poollimits => 1 },
    no_restart => 1, syntax_check => 'never',
);
ok($applied->{ok}, 'todos os alvos reais aplicados') or diag explain $applied;

my ($class, $vmid, $conf, $phase, $param, $archive, $storecfg, $pool, $newid,
    $oldconf, $storage_cfg, $src_conf, $snapname, $usercfg, $qemu_type, $lxc_type,
    $cfg, $storeid, $fmt, $name, $size, $volid, $snap, $fh, $format,
    $snapshot, $base_snapshot, $with_snapshots, $allow_rename, $running);
my %vars = (
    abstract_config_write => [check_write_config => [\$class, \$vmid, \$conf],
        sub { ($class, $vmid, $conf) = ('PVE::QemuConfig', 101, { vcpus => 2 }) },
        'my ($class, $vmid, $conf) = @_;'],
    guest_helpers_start => [check_start => [\$conf, \$vmid, \$phase],
        sub { ($conf, $vmid, $phase) = ({ vcpus => 2 }, 101, 'pre-start') },
        'my ($conf, $vmid, $phase) = @_;'],
    access_control_pool => [check_pool_entry => [\$vmid, \$pool],
        sub { ($vmid, $pool) = (101, 'lab') },
        'my ($vmid, $pool) = @_;'],
    qemu_create_pool => [check_qemu_create => [\$param, \$archive, \$storecfg, \$vmid, \$pool],
        sub { ($param, $archive, $storecfg, $vmid, $pool) = ({ vcpus => 2 }, { type => 'file' }, { ids => {} }, 101, 'lab') },
        'my ($param, $archive, $storecfg, $vmid, $pool) = @_;'],
    qemu_clone_pool => [check_clone => [\$newid, \$pool, \$oldconf, \$qemu_type],
        sub { ($newid, $pool, $oldconf, $qemu_type) = (102, 'lab', { vcpus => 2 }, 'qemu') },
        'my ($newid, $pool, $oldconf, $qemu_type) = @_;'],
    lxc_create_pool => [check_lxc_create => [\$param, \$archive, \$storage_cfg, \$vmid, \$pool],
        sub { ($param, $archive, $storage_cfg, $vmid, $pool) = ({ cores => 2 }, 'backup.tar', { ids => {} }, 201, 'lab') },
        'my ($param, $archive, $storage_cfg, $vmid, $pool) = @_;'],
    lxc_clone_pool => [check_clone => [\$newid, \$pool, \$src_conf, \$lxc_type, \$snapname],
        sub { ($newid, $pool, $src_conf, $lxc_type, $snapname) = (202, 'lab', { cores => 2 }, 'lxc', 'snap0') },
        'my ($newid, $pool, $src_conf, $lxc_type, $snapname) = @_;'],
    pool_update => [check_pool_update => [\$param, \$usercfg],
        sub { ($param, $usercfg) = ({ poolid => 'lab', vms => '101' }, { pools => {} }) },
        'my ($param, $usercfg) = @_;'],
    storage_vdisk_alloc => [check_storage_alloc => [\$cfg, \$storeid, \$vmid, \$fmt, \$name, \$size],
        sub { ($cfg, $storeid, $vmid, $fmt, $name, $size) = ({ ids => {} }, 'local', 101, 'raw', 'vm-101-disk-0', 1024) },
        'my ($cfg, $storeid, $vmid, $fmt, $name, $size) = @_;'],
    storage_vdisk_clone => [check_storage_clone => [\$cfg, \$volid, \$vmid, \$snap],
        sub { ($cfg, $volid, $vmid, $snap) = ({ ids => {} }, 'local:vm-101-disk-0', 101, undef) },
        'my ($cfg, $volid, $vmid, $snap) = @_;'],
    storage_volume_resize => [check_storage_resize => [\$cfg, \$volid, \$size, \$running, \$snapname],
        sub { ($cfg, $volid, $size, $running, $snapname) = ({ ids => {} }, 'local:vm-101-disk-0', 2147483648, 0, undef) },
        'my ($cfg, $volid, $size, $running, $snapname) = @_;'],
    storage_volume_import => [check_storage_import => [\$cfg, \$fh, \$volid, \$format, \$snapshot, \$base_snapshot, \$with_snapshots, \$allow_rename],
        sub { ($cfg, $fh, $volid, $format, $snapshot, $base_snapshot, $with_snapshots, $allow_rename) = ({ ids => {} }, {}, 'local:vm-101-disk-0', 'raw', undef, undef, 0, 0) },
        'my ($cfg, $fh, $volid, $format, $snapshot, $base_snapshot, $with_snapshots, $allow_rename) = @_;'],
);

for my $target (@{MMPve::Module::Poollimits->patch_targets}) {
    my $path = "$tmp$target->{path}";
    my $lines = read_lines($path);
    my @lines = @{$lines};
    my $inserted = inserted_index($target, $lines);
    ok(defined($inserted), "$target->{id}: inserção única encontrada") or next;
    my @guard_errors = ModulePatchGuards::check_target($target, $lines, $inserted);
    ok(!@guard_errors, "$target->{id}: função, escopo e declarações corretos")
        or diag join('; ', @guard_errors);
    my ($line) = grep { index($_, $target->{line}) >= 0 } @lines;
    ok(defined($line), "$target->{id}: linha inserida é a linha real") or next;
    ($line) = $line =~ /\A([ \t]*\Q$target->{line}\E\n)\z/;
    ok(defined($line), "$target->{id}: linha real validada para perl -T") or next;
    my ($method, $expected, $init, $unpack) = @{ $vars{$target->{id}} };
    $init->();
    @PVE::MMTools::PoolLimits::CALLS = ();
    my @args = map { ${$_} } @{$expected};
    my $runner = eval "sub { no strict; $unpack\n$line }";
    ok($runner && !$@, "$target->{id}: linha compila com a assinatura upstream") or diag $@;
    my $ok = eval { $runner->(@args); 1 };
    ok($ok && !$@, "$target->{id}: chamada com os argumentos originais executa") or diag $@;
    is(scalar(@PVE::MMTools::PoolLimits::CALLS), 1, "$target->{id}: uma chamada") or next;
    my $call = $PVE::MMTools::PoolLimits::CALLS[0];
    is($call->[0], $method, "$target->{id}: método correto");
    is(scalar(@{$call}) - 1, scalar(@{$expected}), "$target->{id}: quantidade de argumentos");
    for my $i (0 .. $#{$expected}) {
        is($call->[$i + 1], ${ $expected->[$i] }, "$target->{id}: argumento " . ($i + 1));
    }
}

done_testing();
