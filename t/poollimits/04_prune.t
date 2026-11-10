#!/usr/bin/perl -T
# Pool ou storage apagado no PVE deixava entrada órfã em poollimits.pools e a
# validação de existência na gravação travava a gravação de limites de
# qualquer outro pool (achado ao escrever o e2e do Rock 7).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

my ($lib);
BEGIN { ($lib) = "$Bin/../../lib" =~ /\A(.*)\z/s; }
use lib $lib;
use MMPve::Core::Config;
use MMPve::Module::Poollimits;

my ($tmp) = tempdir('mm-pve-poollimits-prune-XXXXXX', TMPDIR => 1, CLEANUP => 1) =~ /\A(.*)\z/s;
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;
$ENV{PATH} = '/usr/bin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $off = { enabled => 0 };
my $cfg = MMPve::Core::Config->default;
$cfg->{poollimits}{pools} = {
    alive => { mode => 'allocated', cpu => { enabled => 1, max => 4 }, memory_mib => $off,
        disk_total_gib => $off, disk_storage => { enabled => 1, limits => { local => 5, gone => 3 } } },
    onlygone => { mode => 'allocated', cpu => $off, memory_mib => $off, disk_total_gib => $off,
        disk_storage => { enabled => 1, limits => { gone => 2 } } },
    deleted => { mode => 'allocated', cpu => { enabled => 1, max => 2 }, memory_mib => $off,
        disk_total_gib => $off, disk_storage => $off },
};
MMPve::Core::Config->save($cfg);

my $catalog = { pools => { alive => 1, onlygone => 1, fresh => 1 }, storages => { local => 1 } };
no warnings 'redefine';
local *MMPve::Module::Poollimits::_catalog = sub { return $catalog };
use warnings 'redefine';

my $new = { mode => 'running', cpu => { enabled => 1, max => 8 }, memory_mib => $off,
    disk_total_gib => $off, disk_storage => $off };
ok(eval { MMPve::Module::Poollimits->_save_pool('fresh', $new); 1 }, 'gravar outro pool não trava na órfã') or diag $@;
my ($after) = MMPve::Core::Config->load;
my $pools = $after->{poollimits}{pools};
is_deeply([sort keys %{$pools}], [qw(alive fresh onlygone)], 'pool apagado saiu da config');
is_deeply($pools->{alive}{disk_storage}, { enabled => 1, limits => { local => 5 } }, 'storage apagado saiu dos limites');
is_deeply($pools->{onlygone}{disk_storage}, { enabled => 0 }, 'sem storage restante o limite por storage desliga');
is($pools->{alive}{cpu}{max}, 4, 'resto do pool vivo preservado');
is($pools->{fresh}{mode}, 'running', 'pool gravado ficou');

ok(!eval { MMPve::Module::Poollimits->_save_pool('ghost', $new); 1 }, 'gravar pool inexistente continua recusado');
like($@, qr/poollimits\.pools\.ghost não existe/, 'com a mensagem de pool inexistente');
my $bad = { %{$new}, disk_storage => { enabled => 1, limits => { gone => 1 } } };
ok(!eval { MMPve::Module::Poollimits->_save_pool('fresh', $bad); 1 }, 'storage inexistente no pool gravado continua recusado');
like($@, qr/storage 'gone' não existe/, 'com a mensagem de storage inexistente');

is_deeply(MMPve::Module::Poollimits->prune_missing({ pools => {} }, undef, 'x'), [], 'sem catálogo não mexe');

done_testing();
