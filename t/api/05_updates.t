#!/usr/bin/perl -T
use strict;
use warnings;
my $test_dir;
BEGIN {
    require FindBin;
    ($test_dir) = "$FindBin::Bin" =~ /\A(.*)\z/s;
}
use lib $test_dir;
use TestAPI;
use Test::More;

TestAPI::setup_inc();
my ($real, $why) = TestAPI::real_pve();
plan skip_all => "PVE real não disponível: $why" unless $real;

require PVE::API2::MMTools;
require PVE::API2::MMTools::Updates;

my $attrs = PVE::API2::MMTools::Updates->method_attributes;
my %method = map { $_->{name} => $_ } grep { !$_->{subclass} } @{$attrs};
is_deeply([sort keys %method], [qw(bulk log reboot refresh run status)], 'rotas completas do módulo updates');
for my $name (qw(status refresh run bulk log)) {
    my $perm = $method{$name}{permissions}{check};
    ok($perm && $perm->[0] eq 'perm' && $perm->[1] eq '/nodes/{node}', "$name exige Sys.Modify no node")
        or diag explain $method{$name}{permissions};
    ok(grep { $_ eq 'Sys.Modify' } @{$perm->[2]}, "$name lista Sys.Modify")
        if $perm;
}
# Achado do lab: sem protected o GET roda no pveproxy como www-data, que não
# enxerga /etc/pve/priv; o lock de domínio do status falhava com HTTP 500.
for my $name (sort keys %method) {
    ok($method{$name}{protected}, "$name roda no pvedaemon (protected)");
}
my $reboot_perm = $method{reboot}{permissions}{check};
ok(grep { $_ eq 'Sys.Modify' } @{$reboot_perm->[2]}, 'reboot exige Sys.Modify');
ok(grep { $_ eq 'Sys.PowerMgmt' } @{$reboot_perm->[2]}, 'reboot exige Sys.PowerMgmt');
ok(!$method{run}{parameters}{properties}{password}, 'run não recebe senha');
ok(!$method{run}{parameters}{properties}{token}, 'run não recebe token');
is(PVE::API2::MMTools::Updates::_requested_actor('alice@pam', 'root@pam'), 'alice@pam',
    'usuário comum não pode forjar requested_by');
is(PVE::API2::MMTools::Updates::_requested_actor('root@pam', 'orchestrator@pam'), 'orchestrator@pam',
    'root@pam pode informar requested_by interno');
ok($method{bulk}{parameters}{properties}{mode}{enum}, 'bulk valida modo');
is($method{bulk}{parameters}{properties}{mode}{enum}[1], 'parallel', 'bulk oferece parallel');

done_testing();
