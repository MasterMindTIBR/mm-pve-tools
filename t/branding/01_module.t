#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP qw(decode_json);

my $repo = "$Bin/../..";
my $tmp  = "$Bin/tmp-mod";
system("rm -rf $tmp") == 0 or die;
$ENV{MM_PVE_ROOT}       = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";

require MMPve::Module::Branding;
MMPve::Module::Branding->import;    # nop (sem exports)
require MMPve::Core::Config;

my $M   = 'MMPve::Module::Branding';
my $dir = MMPve::Core::Config->branding_dir;
system("mkdir -p $dir");

sub wr {
    my ($path, $data) = @_;
    open(my $fh, '>', $path) or die $!;
    binmode($fh);
    print {$fh} $data;
    close($fh);
}

my $CLEAN_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="#00f"/></svg>';
my $PNG = "\x89PNG\r\n\x1a\n" . ("\x00" x 32);

subtest 'sanitização SVG' => sub {
    my @dirty = (
        ['script',    "<svg>$CLEAN_SVG<script>alert(1)</script></svg>"],
        ['onclick',   qq{<svg><rect onclick="x()"/></svg>}],
        ['jshref',    qq{<svg><a href="javascript:alert(1)"><rect/></a></svg>}],
        ['entidade',  "&lt;script&gt;alert(1)&lt;/script&gt;<svg><rect/></svg>"],
        ['entidade-dupla', "&amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;<svg/>"],
        ['entidade-num', "&#x3C;script&#x3E;alert(1)&#x3C;/script&#x3E;<svg/>"],
    );
    for my $d (@dirty) {
        my ($name, $svg) = @$d;
        my $r = eval { $M->store_asset(kind => 'logo', filename => "x-$name.svg", data => \$svg) };
        ok($@, "recusado: $name") or diag 'aceitou!';
        like($@, qr/recusado/, "mensagem clara: $name");
        is(-f "$dir/x-$name.svg", undef, "não gravou ($name)");
    }
    my $r = $M->store_asset(kind => 'logo', filename => 'clean.svg', data => \$CLEAN_SVG);
    ok($r->{sha256} =~ /^sha256:/, 'SVG limpo aceito');
    ok(-f "$dir/clean.svg", 'gravou');
};

subtest 'limites e extensões' => sub {
    my $big = 'A' x (200 * 1024 + 1);
    eval { $M->store_asset(kind => 'logo', filename => 'big.png', data => \$big) };
    like($@, qr/excede o limite/, 'recusa > 200KB');

    eval { $M->store_asset(kind => 'logo', filename => 'x.jpg', data => \'xx') };
    like($@, qr/só \.svg ou \.png/, 'recusa extensão inválida');

    my $tr = $M->store_asset(kind => 'logo', filename => '../evil.svg', data => \$CLEAN_SVG);
    ok($tr, 'traversal neutralizado pelo basename');
    ok(-f "$dir/evil.svg", 'gravado dentro do branding_dir');
    ok(!-f "$tmp/evil.svg", 'não escapou do branding_dir');
};

my $CFG = MMPve::Core::Config->default;
$CFG->{modules}{branding} = 1;

subtest 'validate_section' => sub {
    my @e = $M->validate_section({ modules => { branding => 1 }, branding => { logo => 'nao-existe.svg' } });
    ok((grep { /não existe/ } @e), 'pega logo inexistente');

    # hash errado
    my $c2 = { modules => { branding => 1 }, branding => { logo => 'clean.svg', assets_hash => 'sha256:' . ('0' x 64) } };
    @e = $M->validate_section($c2);
    ok((grep { /assets_hash não confere/ } @e), 'pega hash errado') or diag explain \@e;

    # hash certo passa
    my $h = $M->assets_hash;
    @e = $M->validate_section({ modules => { branding => 1 }, branding => { logo => 'clean.svg', assets_hash => $h } });
    is(scalar @e, 0, 'hash certo ok') or diag explain \@e;
};

subtest 'apply/revert/check' => sub {
    # favicon png
    $M->store_asset(kind => 'favicon', filename => 'fav.png', data => \$PNG);
    my $cfg = MMPve::Core::Config->default;
    $cfg->{branding} = {
        title => 'MasterMind', header_text => 'MM Cloud', login_text => 'Bem-vindo',
        logo => 'clean.svg', favicon => 'fav.png', assets_hash => $M->assets_hash,
    };
    my $r = $M->apply($cfg);
    ok($r->{ok}, 'apply ok');
    ok(-f "$tmp/usr/share/pve-manager/images/mm-branding/clean.svg", 'logo copiado');
    ok(-f "$tmp/usr/share/pve-manager/images/mm-branding/fav.png", 'favicon copiado');
    ok(-f "$tmp/usr/share/pve-manager/js/mm-branding.json", 'json gravado');
    my $j = decode_json(MMPve::Core::Util::read_file("$tmp/usr/share/pve-manager/js/mm-branding.json"));
    is($j->{title}, 'MasterMind', 'título no json');
    like($j->{logo_url}, qr{^/pve2/images/mm-branding/clean\.svg\?v=[0-9a-f]{10}$}, 'URL com hash curto');
    like($j->{assets_hash}, qr/^sha256:[0-9a-f]{64}$/, 'hash no json');

    # idempotente
    my $r2 = $M->apply($cfg);
    is($r2->{changed}, 0, 'apply idempotente');

    my $chk = $M->check($cfg);
    ok($chk->{applied}, 'check: aplicado');
    is($chk->{config_hash}, $j->{assets_hash}, 'hash do check = hash aplicado');

    my $rv = $M->revert;
    ok($rv->{changed}, 'revert mudou');
    ok(!-f "$tmp/usr/share/pve-manager/images/mm-branding/clean.svg", 'logo removido');
    ok(!-d "$tmp/usr/share/pve-manager/images/mm-branding", 'dir removido');
    ok(!-f "$tmp/usr/share/pve-manager/js/mm-branding.json", 'json removido');
    my $rv2 = $M->revert;
    is($rv2->{changed}, 0, 'revert idempotente');
    is($M->check($cfg)->{applied}, 0, 'check: não aplicado');
};

subtest 'apply morre com asset sumido' => sub {
    my $bad = MMPve::Core::Config->default;
    $bad->{branding}{logo} = 'sumiu.svg';
    $bad->{branding}{assets_hash} = $M->assets_hash;
    eval { $M->apply($bad) };
    like($@, qr/mm-pve branding set --logo sumiu\.svg/, 'erro com comando para continuar');
};

system("rm -rf $tmp");
done_testing();
