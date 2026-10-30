#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP;

use lib "$Bin/../../lib", "$Bin/../../perl";
use MMPve::Core::Config;

my $tmp = "$Bin/tmp-config";
system("rm -rf $tmp") == 0 or die;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_ROOT} = "$tmp";

subtest 'default valido' => sub {
    my @e = MMPve::Core::Config->validate(MMPve::Core::Config->default);
    is(scalar @e, 0, 'sem erros') or diag explain \@e;
};

subtest 'validacao aceita bom' => sub {
    my @e = MMPve::Core::Config->validate({
        revision => 1,
        modules  => { renumber => JSON::PP::true, restore => JSON::PP::false, branding => 0 },
        vmid_scheme => [
            { label => 'Produção', from => 1000, to => 1999 },
            { label => 'Lab',      from => 2000, to => 2999 },
        ],
        restore => {
            gateway_vmid => 9900,
            vlans => {
                120 => { gw_ip => '10.1.20.250', prefix => 28, note => '' },
                130 => { gw_ip => '10.1.30.250', prefix => 28 },
            },
            session_default_hours => 24,
            session_max_hours     => 72,
            max_sessions          => 10,
        },
        branding => { title => 'Cliente — Virtualização', logo => 'logo.svg' },
    });
    is(scalar @e, 0, 'sem erros') or diag explain \@e;
};

subtest 'validacao rejeita ruim' => sub {
    my @cases = (
        [ { revision => 0 },                                   qr/revision/ ],
        [ { modules => { renumber => 'sim' } },                qr/booleano/ ],
        [ { modules => { inexistente => 1 } },                 qr/desconhecido/ ],
        [ { chave_nova => 1 },                                 qr/desconhecida/ ],
        [ { branding => { logo => 'logo.gif' } },             qr/svg ou \.png/ ],
        [ { vmid_scheme => [ { label => 'A', from => 1000, to => 1999 },
                             { label => 'B', from => 1500, to => 2500 } ] }, qr/sobrepostas/ ],
        [ { vmid_scheme => [ { label => 'A', from => 2000, to => 1000 } ] }, qr/from/ ],
        [ { restore => { vlans => { 5000 => { gw_ip => '10.0.0.1', prefix => 24 } } } }, qr/1\.\.4094/ ],
        [ { restore => { vlans => { 100 => { gw_ip => '10.0.0.999', prefix => 24 } } } }, qr/IPv4/ ],
        [ { restore => { vlans => { 100 => { gw_ip => '10.0.0.1', prefix => 40 } } } },   qr/8\.\.32/ ],
        [ { restore => { session_default_hours => 100, session_max_hours => 50 } },       qr/default_hours/ ],
        [ { restore => { session_max_hours => 99999 } },                                  qr/168/ ],
        [ { restore => { vlans => { 100 => { gw_ip => '10.0.0.1', prefix => 24 },
                                      200 => { gw_ip => '10.0.0.1', prefix => 24 } } } }, qr/repetido/ ],
        [ { branding => { logo => '../../etc/passwd' } },     qr/nome de arquivo/ ],
        [ { branding => { assets_hash => 'md5:xx' } },        qr/sha256/ ],
        [ { branding => { title => 'x' x 101 } },             qr/100 caracteres/ ],
    );
    for my $c (@cases) {
        my ($data, $re) = @{$c};
        my @e = MMPve::Core::Config->validate($data);
        ok((grep { $_ =~ $re } @e), "rejeita: $re") or diag explain \@e;
    }
};

subtest 'save/load/digest/revision' => sub {
    my ($d1, $g1) = MMPve::Core::Config->save({ modules => { renumber => 1, restore => 0, branding => 0 } });
    like($g1, qr/^sha256:[0-9a-f]{64}$/, 'digest formato');
    my ($d2, $g2) = MMPve::Core::Config->save({ modules => { renumber => 0, restore => 0, branding => 0 } },
        digest => $g1);
    is($d2->{revision}, $d1->{revision} + 1, 'revision incrementa');

    # CAS: digest velho precisa recusar
    eval { MMPve::Core::Config->save({ modules => {} }, digest => $g1) };
    like($@, qr/DIGEST_MISMATCH/, 'concorrência barrada por digest');

    my ($d3, $g3, $absent) = MMPve::Core::Config->load;
    is($d3->{revision}, $d2->{revision}, 'load volta a última');
    is($absent, 0, 'arquivo existe');
    is($g3, $g2, 'digest bate');
};

subtest 'load ausente → default' => sub {
    $ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools-nao-existe";
    my ($d, $digest, $absent) = MMPve::Core::Config->load;
    is($d->{revision}, 1, 'default revision 1');
    ok($absent, 'flag absent');
    is($digest, undef, 'sem digest');
};

subtest 'JSON inválido rejeitado' => sub {
    $ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-badjson";
    require File::Path;
    File::Path::make_path($ENV{MM_PVE_CONFIG_DIR});
    open(my $fh, '>', "$ENV{MM_PVE_CONFIG_DIR}/config.json") or die $!;
    print $fh '{"revision": 1, oops}';
    close $fh;
    eval { MMPve::Core::Config->load };
    like($@, qr/inválido/, 'json quebrado → die');
};

system("rm -rf $tmp");
done_testing();
