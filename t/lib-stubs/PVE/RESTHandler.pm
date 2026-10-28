# Stub mínimo de lint/CI (sem PVE instalado). Comportamento real: pve-manager.
# register_method aceita lista de pares (estilo PVE) OU hashref único (subclass).
package PVE::RESTHandler;
use strict;
use warnings;
sub register_method { return 1 }
sub method_class { die "stub" }
1;
