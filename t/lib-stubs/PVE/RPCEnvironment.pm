# Stub de compilação. Fonte upstream: pve-manager/PVE/RPCEnvironment.pm:1.
package PVE::RPCEnvironment;
use strict;
use warnings;
my $env;
sub get { return $env //= bless {}, shift }
sub get_user { return 'root@pam' }
sub fork_worker { my ($self, $wheel, $id, $user, $fn) = @_; return "UPID:stub:0000:$wheel:$id::" }
sub check_privileges { return 1 }
1;
