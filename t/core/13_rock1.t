#!/usr/bin/perl
use strict;
use warnings;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../../lib", "$Bin/../../perl";
use MMPve::Core::Apply;
use MMPve::Core::Config;
use MMPve::Core::Patch;
use MMPve::Core::Util qw(write_file_atomic);
require PVE::MMTools::PoolLimits;

require "$Bin/../lib/TestPatchFixture.pm";

sub fixture_root {
    my $root = tempdir('mm-pve-rock1-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my %files = (
        '/usr/share/perl5/PVE/MMTestGuestHelpers.pm' => "package PVE::GuestHelpers;\nsub exec_hookscript {\n    return;\n}\n1;\n",
        '/usr/share/perl5/PVE/MMTestAccessControl.pm' => "package PVE::AccessControl;\nsub add_vm_to_pool {\n    return;\n}\n1;\n",
        '/usr/share/perl5/PVE/MMTestAbstractConfig.pm' => "package PVE::AbstractConfig;\nsub write_config {\n    return;\n}\n1;\n",
        '/usr/share/perl5/PVE/MMTestStorage.pm' => "package PVE::Storage;\nsub vdisk_alloc {\n    return;\n}\n1;\n",
        '/usr/share/perl5/PVE/API2/MMTestPool.pm' => "package PVE::API2::Pool;\nsub register_method {\n    return;\n}\n1;\n",
    );
    for my $relative (keys %files) {
        my $path = "$root$relative";
        $path =~ s{/[^/]+\z}{};
        make_path($path);
    }
    for my $relative (keys %files) {
        my $path = "$root$relative";
        open(my $fh, '>', $path) or die "open $path: $!";
        print {$fh} $files{$relative};
        close($fh) or die "close $path: $!";
    }
    return $root;
}

subtest 'generated hook uses original arguments, not local variable names' => sub {
    {
        package MMPve::Module::Rock1FakeOwner;
        use strict;
        use warnings;
        sub name { 'rock1fakeowner' }
        sub patch_targets {
            return [{
                id => 'fake_owner_hook', owner => 'fake-owner',
                path => '/usr/share/perl5/Fake/Owner.pm',
                anchor => qr/^\s*my\s+\(\$cfg\)\s*=\s*\@_;/,
                scope_anchor => qr/^\s*sub\s+run\b/,
                expected_function => 'sub run',
                line => '    eval { require PVE::MMTools::PoolLimits; 1 } && PVE::MMTools::PoolLimits->check_storage_resize(@_);',
                daemons => ['pvedaemon'], processes => ['pvedaemon'],
            }];
        }
    }
    my $root = tempdir('mm-pve-fake-owner-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $path = "$root/usr/share/perl5/Fake";
    make_path($path);
    write_file_atomic("$path/Owner.pm", "package Fake::Owner;\nuse strict;\nuse warnings;\nsub run {\n    my (\$cfg) = \@_;\n}\n1;\n", 0644);
    local $ENV{MM_PVE_ROOT} = $root;
    MMPve::Core::Patch->register_module('MMPve::Module::Rock1FakeOwner');
    my $result = MMPve::Core::Patch->apply(core => 0,
        active_modules => { rock1fakeowner => 1 }, no_restart => 1,
        syntax_check => 'always');
    ok($result->{ok}, 'fake owner applies and compiles') or diag explain $result;
    like($result->{modules}{'MMPve::Module::Rock1FakeOwner'}{targets}{fake_owner_hook}{status} // '',
        qr/applied|version_current/, 'fake owner target applied');
    MMPve::Core::Patch->unregister_module('MMPve::Module::Rock1FakeOwner');
};

subtest 'static declaration check catches an undeclared local variable' => sub {
    my $target = {
        id => 'fake_snapname',
        line => '    check($snapname);',
        scope_anchor => qr/^\s*sub\s+run\b/,
    };
    my @without = (
        "package Fake;\n", "sub run {\n", "    my (\$cfg) = \@_;\n", "    return;\n", "}\n",
    );
    my @errors = MMPve::Core::Patch->static_check_target($target, \@without, 3);
    like(join('; ', @errors), qr/undeclared variable \$snapname/, 'undeclared snapname is rejected');

    my @with = (
        "package Fake;\n", "sub run {\n", "    my (\$cfg) = \@_;\n",
        "    my \$snapname;\n", "    return;\n", "}\n",
    );
    is_deeply([MMPve::Core::Patch->static_check_target($target, \@with, 4)], [],
        'declared snapname passes the static check');
};

subtest 'positional hooks fail closed when required arguments are missing' => sub {
    my @calls = (
        [write_config => sub { PVE::MMTools::PoolLimits->check_write_config('PVE::QemuConfig', 101) }],
        [exec_hookscript => sub { PVE::MMTools::PoolLimits->check_start({}, 101) }],
        [add_vm_to_pool => sub { PVE::MMTools::PoolLimits->check_pool_entry(101) }],
        [vdisk_alloc => sub { PVE::MMTools::PoolLimits->check_storage_alloc({}, 'local', 101, 'raw', 'vm-101-disk') }],
        [vdisk_clone => sub { PVE::MMTools::PoolLimits->check_storage_clone({}, 'local:vm-101-disk') }],
        [volume_resize => sub { PVE::MMTools::PoolLimits->check_storage_resize({}, 'local:vm-101-disk') }],
        [volume_import => sub { PVE::MMTools::PoolLimits->check_storage_import({}, {}, 'local:vm-101-disk') }],
    );
    for my $case (@calls) {
        my ($name, $call) = @{$case};
        ok(!eval { $call->(); 1 }, "$name missing required argument fails closed");
        like($@, qr/arguments are missing or malformed/, "$name failure identifies malformed hook arguments");
    }
};

subtest 'upstream calls with optional arguments empty are not malformed' => sub {
    # Seen in the lab: qemu-server resizes a stopped guest with
    # running = check_running() = undef, and vdisk_alloc may get no format.
    my @calls = (
        [volume_resize => sub { PVE::MMTools::PoolLimits->check_storage_resize({}, 'local:vm-101-disk-0', 1073741824, undef) }],
        [vdisk_alloc => sub { PVE::MMTools::PoolLimits->check_storage_alloc({}, 'local', 101, undef, undef, 1024) }],
    );
    for my $case (@calls) {
        my ($name, $call) = @{$case};
        eval { $call->() };
        unlike($@ // '', qr/arguments are missing or malformed/, "$name with empty optional arguments is accepted");
    }
};

subtest 'group failure records all targets and retries after one source changes' => sub {
    my $root = fixture_root();
    local $ENV{MM_PVE_ROOT} = $root;
    no warnings 'redefine';
    local *MMPve::Core::Patch::_owner_versions = sub {
        my ($class, $ids, $all) = @_;
        my %versions = map { $all->{$_}{owner} => 'test-owner-1' } @{$ids};
        return \%versions;
    };
    local *MMPve::Core::Patch::_perl_c = sub {
        return { ok => 0, rc => 1, err => 'fake staged compile failure' };
    };
    MMPve::Core::Patch->register_module('MMPve::Module::TestPatchFixture');
    my $first = MMPve::Core::Patch->apply(core => 0,
        active_modules => { testpatchfixture => 1 }, no_restart => 1,
        syntax_check => 'always');
    ok(!$first->{ok}, 'first group apply fails');
    my $state = MMPve::Core::Patch::_patch_state();
    my @ids = map { $_->{id} } @{MMPve::Module::TestPatchFixture->patch_targets};
    ok((grep { ref($state->{$_}{failure}) eq 'HASH' } @ids) == @ids,
        'every target has a group failure record');
    is_deeply([sort keys %{$state->{$ids[0]}{failure}{targets}}], [sort @ids],
        'failure record includes every target hash and owner version');

    my $blocked = MMPve::Core::Patch->apply(core => 0,
        active_modules => { testpatchfixture => 1 }, no_restart => 1,
        syntax_check => 'never');
    ok(!$blocked->{ok}, 'same source remains blocked');
    is($blocked->{modules}{'MMPve::Module::TestPatchFixture'}{targets}{$ids[0]}{status},
        'previous_failure', 'blocked target is previous_failure');

    my $changed_path = "$root" . MMPve::Module::TestPatchFixture->patch_targets->[0]{path};
    open(my $fh, '>>', $changed_path) or die "open $changed_path: $!";
    print {$fh} "# owner package changed\n";
    close($fh) or die "close $changed_path: $!";
    no warnings 'redefine';
    local *MMPve::Core::Patch::_perl_c = sub { return { ok => 1, rc => 0 } };
    my $retried = MMPve::Core::Patch->apply(core => 0,
        active_modules => { testpatchfixture => 1 }, no_restart => 1,
        syntax_check => 'always');
    ok($retried->{ok}, 'one changed source hash unblocks the whole group') or diag explain $retried;
};

subtest 'status distinguishes error, partial and fully applied' => sub {
    my $root = tempdir('mm-pve-status-rock1-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    local $ENV{MM_PVE_ROOT} = $root;
    local $ENV{MM_PVE_CONFIG_DIR} = "$root/etc/pve/mm-tools";
    make_path("$root/var/lib/mm-pve-tools");
    my ($cfg, $digest) = MMPve::Core::Config->load;
    my $revision = $cfg->{revision};
    write_file_atomic(MMPve::Core::Apply->state_path, '{"ok":false,"revision":' . $revision
        . ',"modules":{},"patches":{"ok":false}}' . "\n", 0644);
    no warnings 'redefine';
    local *MMPve::Core::Patch::check = sub {
        return { failed_target => { status => 'previous_failure', module => '__core__',
            error => 'compile failed', failed_target => 'failed_target' } };
    };
    my $error = MMPve::Core::Apply->status;
    is($error->{state}, 'error', 'last failed apply is error');
    ok((grep { $_ eq 'failed_target' } @{$error->{failed_targets}}), 'error lists failing target');

    $cfg->{modules}{poollimits} = 1;
    my ($saved, $new_digest) = MMPve::Core::Config->save($cfg, digest => $digest);
    write_file_atomic(MMPve::Core::Apply->state_path, '{"ok":true,"revision":' . $saved->{revision}
        . ',"modules":{},"patches":{"ok":true}}' . "\n", 0644);
    local *MMPve::Core::Patch::check = sub {
        return { pool_target => { status => 'not_applied', module => 'MMPve::Module::Poollimits' } };
    };
    my $partial = MMPve::Core::Apply->status;
    is($partial->{state}, 'partial', 'enabled module target not applied is partial');
    ok((grep { $_ eq 'pool_target' } @{$partial->{failed_targets}}), 'partial lists target');

    local *MMPve::Core::Patch::check = sub {
        return { pool_target => { status => 'applied', module => 'MMPve::Module::Poollimits' } };
    };
    my $applied = MMPve::Core::Apply->status;
    is($applied->{state}, 'applied', 'all enabled targets applied is applied');
};

subtest 'patch check has no warning for a persisted target without regexp' => sub {
    my $root = tempdir('mm-pve-anchor-warning-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    local $ENV{MM_PVE_ROOT} = $root;
    my $path = "$root/usr/share/perl5/PVE/Ghost.pm";
    make_path("$root/usr/share/perl5/PVE");
    write_file_atomic($path, "package PVE::Ghost;\n1;\n", 0644);
    MMPve::Core::Patch->_save_patch_state({ ghost => {
        previous_failure => 1, source_hash => 'old', error => 'old failure',
        target => { id => 'ghost', module => 'MMPve::Module::Ghost', owner => 'ghost-owner',
            path => '/usr/share/perl5/PVE/Ghost.pm', line => '# ghost', marker => '# ghost',
            anchor_text => '(?^:^\\s*my)', daemons => ['pvedaemon'], processes => ['pvedaemon'] },
    }});
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $checked = MMPve::Core::Patch->check;
    is($checked->{ghost}{status}, 'anchor_missing', 'missing persisted regexp is handled');
    is_deeply(\@warnings, [], 'patch check emits no uninitialized regexp warning');
};

done_testing();
