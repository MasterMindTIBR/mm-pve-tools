# Stub de compilação. Fonte upstream: pve-common/src/PVE/Exception.pm:1.
package PVE::Exception;
use strict;
use warnings;
use base 'Exporter';
our @EXPORT_OK = qw(raise raise_param_exc raise_perm_exc);
sub new { my ($c, %a) = @_; return bless { %a }, $c }
sub raise { my ($e, %a) = @_; die ref($e) ? $e : $e->new(msg => $e, %a), "\n" }
sub raise_param_exc { my ($p) = @_; my $m = ref($p) ? (join ': ', %$p) : $p; die "param error: $m\n" }
sub raise_perm_exc { die "permission denied\n" }
1;
