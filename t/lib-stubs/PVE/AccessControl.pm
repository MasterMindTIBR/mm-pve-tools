# Stub de compilação. A implementação real é usada nos testes t/api dentro do PVE.
package PVE::AccessControl;
use strict;
use warnings;
sub split_tokenid {
    my ($tokenid, $noerr) = @_;
    return ($1, $2) if defined($tokenid) && $tokenid =~ /\A(.+)!([^!]+)\z/;
    return;
}
1;
