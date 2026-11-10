package MMPve::Module::TestPatchFixture;

use strict;
use warnings;

sub name { return 'testpatchfixture' }

sub patch_targets {
    return [
        {
            id => 'guest_helpers',
            owner => 'libpve-guest-common-perl',
            path => '/usr/share/perl5/PVE/MMTestGuestHelpers.pm',
            anchor => qr/^\s*sub\s+exec_hookscript\b/,
            scope_anchor => qr/^\s*sub\s+exec_hookscript\b/,
            expected_function => 'sub exec_hookscript',
            line => '# mm-pve-test guest_helpers',
            daemons => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm)],
            processes => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm qm pct pvesh)],
        },
        {
            id => 'access_control',
            owner => 'libpve-access-control',
            path => '/usr/share/perl5/PVE/MMTestAccessControl.pm',
            anchor => qr/^\s*sub\s+add_vm_to_pool\b/,
            scope_anchor => qr/^\s*sub\s+add_vm_to_pool\b/,
            expected_function => 'sub add_vm_to_pool',
            line => '# mm-pve-test access_control',
            daemons => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm pveum pvesh qm pct pvesm)],
        },
        {
            id => 'abstract_config',
            owner => 'libpve-guest-common-perl',
            path => '/usr/share/perl5/PVE/MMTestAbstractConfig.pm',
            anchor => qr/^\s*sub\s+write_config\b/,
            scope_anchor => qr/^\s*sub\s+write_config\b/,
            expected_function => 'sub write_config',
            line => '# mm-pve-test abstract_config',
            daemons => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm qm pct pvesh pvesm)],
        },
        {
            id => 'storage',
            owner => 'libpve-storage-perl',
            path => '/usr/share/perl5/PVE/MMTestStorage.pm',
            anchor => qr/^\s*sub\s+vdisk_alloc\b/,
            scope_anchor => qr/^\s*sub\s+vdisk_alloc\b/,
            expected_function => 'sub vdisk_alloc',
            line => '# mm-pve-test storage',
            daemons => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm)],
            processes => [qw(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm qm pct pvesm pvesh)],
        },
        {
            id => 'pool',
            owner => 'pve-manager',
            path => '/usr/share/perl5/PVE/API2/MMTestPool.pm',
            anchor => qr/^\s*sub\s+register_method\b/,
            scope_anchor => qr/^\s*sub\s+register_method\b/,
            expected_function => 'sub register_method',
            line => '# mm-pve-test pool',
            daemons => [qw(pvedaemon pveproxy)],
            processes => [qw(pvedaemon pveproxy pvesh)],
        },
    ];
}

1;
