#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);

my $repo = "$Bin/../..";
my $tmp  = tempdir('mm-pve-branding-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_ROOT}       = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";

require MMPve::Module::Branding;
MMPve::Module::Branding->import;    # nop (sem exports)
require MMPve::Core::Config;

my $M   = 'MMPve::Module::Branding';
my $dir = MMPve::Core::Config->branding_dir;
my $ASSET;
system("mkdir -p $dir");

sub wr {
    my ($path, $data) = @_;
    open(my $fh, '>', $path) or die $!;
    binmode($fh);
    print {$fh} $data;
    close($fh);
}

my $PNG = "\x89PNG\r\n\x1a\n" . pack('N', 13) . 'IHDR'
    . pack('NNCCCCC', 1, 1, 8, 6, 0, 0, 0) . pack('N', 0);
subtest 'somente PNG assinado' => sub {
    my $bad = 'conteúdo vetorial';
    eval { $M->store_asset(kind => 'logo', filename => 'x.txt', data => \$bad) };
    like($@, qr/apenas PNG/, 'extensão não PNG recusada');

    eval { $M->store_asset(kind => 'logo', filename => 'fake.png', data => \$bad) };
    like($@, qr/não é um PNG válido/, 'extensão PNG sem assinatura recusada');

    my $r = $M->store_asset(kind => 'logo', filename => 'qualquer.png', data => \$PNG);
    $ASSET = $r->{filename};
    like($ASSET, qr/^[0-9a-f]{64}\.png$/, 'nome content-addressed');
    ok(-f "$dir/$r->{filename}", 'PNG gravado');
};

subtest 'limites e extensões' => sub {
    my $big = "\x89PNG\r\n\x1a\n" . ('A' x (256 * 1024));
    eval { $M->store_asset(kind => 'logo', filename => 'big.png', data => \$big) };
    like($@, qr/excede o limite/, 'recusa > 256 KiB');

    eval { $M->store_asset(kind => 'logo', filename => 'x.jpg', data => \'xx') };
    like($@, qr/apenas PNG/, 'recusa extensão inválida');

    my $tr = $M->store_asset(kind => 'logo', filename => '../evil.png', data => \$PNG);
    ok($tr, 'basename do upload não escapa');
    ok(-f "$dir/$tr->{filename}", 'asset canônico dentro do branding_dir');
    ok(!-f "$tmp/evil.png", 'não escapou do branding_dir');
};

my $CFG = MMPve::Core::Config->default;
$CFG->{modules}{branding} = 1;

subtest 'validate_section' => sub {
    my @e = $M->validate_section({ modules => { branding => 1 }, branding => { logo => ('f' x 64) . '.png' } });
    ok((grep { /não existe/ } @e), 'pega logo inexistente');

    # hash errado
    my $c2 = { modules => { branding => 1 }, branding => { logo => $ASSET, assets_hash => 'sha256:' . ('0' x 64) } };
    @e = $M->validate_section($c2);
    ok((grep { /assets_hash não confere/ } @e), 'pega hash errado') or diag explain \@e;

    # hash certo passa
    my $h = $M->assets_hash({ branding => { logo => $ASSET } });
    @e = $M->validate_section({ modules => { branding => 1 }, branding => { logo => $ASSET, assets_hash => $h } });
    is(scalar @e, 0, 'hash certo ok') or diag explain \@e;
};

subtest 'apply/revert/check' => sub {
    # favicon png
    my $asset = $ASSET;
    $M->store_asset(kind => 'favicon', filename => 'fav.png', data => \$PNG);
    my $cfg = MMPve::Core::Config->default;
    $cfg->{branding} = {
        title => 'MasterMind', header_text => 'MM Cloud', login_text => 'Bem-vindo',
        logo => $asset, favicon => $asset,
    };
    $cfg->{branding}{assets_hash} = $M->assets_hash($cfg);
    my $r = $M->apply($cfg);
    ok($r->{ok}, 'apply ok');
    ok(-f "$tmp/usr/share/pve-manager/images/mm-branding/$asset", 'logo copiado');
    ok(-f "$tmp/usr/share/pve-manager/images/mm-branding/$asset", 'favicon copiado');
    ok(-f "$tmp/usr/share/pve-manager/js/mm-branding.json", 'json gravado');
    my $j = decode_json(MMPve::Core::Util::read_file("$tmp/usr/share/pve-manager/js/mm-branding.json"));
    is($j->{title}, 'MasterMind', 'título no json');
    like($j->{logo_url}, qr{^/pve2/images/mm-branding/[0-9a-f]{64}\.png\?v=[0-9a-f]{10}$}, 'URL com hash curto');
    like($j->{assets_hash}, qr/^sha256:[0-9a-f]{64}$/, 'hash no json');

    # idempotente
    my $r2 = $M->apply($cfg);
    is($r2->{changed}, 0, 'apply idempotente');

    my $chk = $M->check($cfg);
    ok($chk->{applied}, 'check: aplicado');
    ok($chk->{serves_asset}, 'check: node ainda serve asset');
    is($chk->{config_hash}, $j->{assets_hash}, 'hash do check = hash aplicado');

    my $rv = $M->revert;
    ok($rv->{changed}, 'revert mudou');
    ok(!-f "$tmp/usr/share/pve-manager/images/mm-branding/$asset", 'logo removido');
    ok(!-d "$tmp/usr/share/pve-manager/images/mm-branding", 'dir removido');
    ok(!-f "$tmp/usr/share/pve-manager/js/mm-branding.json", 'json removido');
    my $rv2 = $M->revert;
    is($rv2->{changed}, 0, 'revert idempotente');
    is($M->check($cfg)->{applied}, 0, 'check: não aplicado');
    ok(!$M->check($cfg)->{serves_asset}, 'check: node não serve asset após revert');
};

subtest 'apply morre com asset sumido' => sub {
    my $bad = MMPve::Core::Config->default;
    $bad->{branding}{logo} = ('0' x 64) . '.png';
    $bad->{branding}{assets_hash} = $M->assets_hash($bad);
    eval { $M->apply($bad) };
    like($@, qr/branding\.logo.*não existe/, 'erro com asset ausente');
};

done_testing();
