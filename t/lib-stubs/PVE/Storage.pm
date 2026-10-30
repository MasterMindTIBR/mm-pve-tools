# Stub de compilação. Fonte upstream: pve-storage/src/PVE/Storage.pm:1.
package PVE::Storage;
use strict;
use warnings;

# volume_has_feature($cfg, $feature, $volid, $snap, $running, $opts) — ver
# pve-storage/src/PVE/Storage.pm:502. Sem PVE instalado não dá pra checar de
# verdade; testes controlam o retorno por chave "<feature>:<storageid>".
our %FEATURE_OVERRIDE;

sub config { return { ids => {} } }
sub check_volume_access { return 1 }

sub volume_has_feature {
    my ($cfg, $feature, $volid, $snap, $running, $opts) = @_;
    my ($storeid) = $volid =~ /^([^:]+):/;
    return 1 unless defined $storeid;
    my $key = "$feature:$storeid";
    return $FEATURE_OVERRIDE{$key} if exists $FEATURE_OVERRIDE{$key};
    return 1;    # default: assume suportado (sem PVE instalado pra checar de verdade)
}

1;
