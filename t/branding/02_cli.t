#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);

my $repo = "$Bin/../..";
my $tmp  = tempdir('mm-pve-branding-cli-XXXXXX', TMPDIR => 1, CLEANUP => 1);

my @ENVV = (
    "MM_PVE_ROOT=$tmp",
    "MM_PVE_CONFIG_DIR=$tmp/etc/pve/mm-tools",
);
my $ASSET;

sub mm {
    my (@args) = @_;
    my $cmd = join(' ', 'env', @ENVV, 'perl', "-I$repo/lib", "-I$repo/perl",
        "$repo/bin/mm-pve", map { "'" . $_ . "'" } @args);
    my $out = qx{$cmd 2>&1};
    return ($? >> 8, $out);
}

sub wr {
    my ($path, $data) = @_;
    open(my $fh, '>', $path) or die $!;
    binmode($fh);
    print {$fh} $data;
    close($fh);
}

my $png = "\x89PNG\r\n\x1a\n" . pack('N', 13) . 'IHDR'
    . pack('NNCCCCC', 1, 1, 8, 6, 0, 0, 0) . pack('N', 0);
wr("$tmp/logo.png", $png);
wr("$tmp/evil.png", "not a png");
wr("$tmp/fav.png", $png);

subtest 'set com arquivos em tmp' => sub {
    my ($rc, $out) = mm('branding', 'set', '--logo', "$tmp/logo.png",
        '--favicon', "$tmp/fav.png", '--title', 'MasterMind Cloud',
        '--header-text', 'MM', '--login-text', 'Bem-vindo');
    is($rc, 0, 'exit 0') or diag $out;
    my $cfg = decode_json(do { local (@ARGV, $/) = "$tmp/etc/pve/mm-tools/config.json"; <> });
    $ASSET = $cfg->{branding}{logo};
    like($ASSET, qr/^[0-9a-f]{64}\.png$/, 'config referencia hash');
    ok(-f "$tmp/etc/pve/mm-tools/branding/$ASSET", 'asset no branding_dir');
    ok(-f "$tmp/usr/share/pve-manager/images/mm-branding/$ASSET", 'asset aplicado');
    ok(-f "$tmp/usr/share/pve-manager/js/mm-branding.json", 'json aplicado');

    ($rc, $out) = mm('--json', 'config', 'get');
    my $j = decode_json($out);
    is($j->{config}{branding}{title}, 'MasterMind Cloud', 'título salvo no config');
    like($j->{config}{branding}{assets_hash}, qr/^sha256:/, 'assets_hash salvo');
    is($j->{config}{modules}{branding}, 0, 'módulo continua desligado (set não liga)');
};

subtest 'set recusa PNG inválido' => sub {
    my ($rc, $out) = mm('branding', 'set', '--logo', "$tmp/evil.png");
    isnt($rc, 0, 'exit != 0');
    like($out, qr/não é um PNG válido/, 'mensagem sobre assinatura PNG');
    ok(!-f "$tmp/etc/pve/mm-tools/branding/evil.png", 'não gravou o PNG inválido');
};

subtest 'set idempotente / clear' => sub {
    my ($rc, $out) = mm('branding', 'set', '--title', 'Outro');
    is($rc, 0, 'set só texto ok') or diag $out;

    my ($rc2, $out2) = mm('branding', 'clear');
    is($rc2, 0, 'clear ok') or diag $out2;
    ok(!-f "$tmp/usr/share/pve-manager/js/mm-branding.json", 'json removido');
    ok(!-d "$tmp/usr/share/pve-manager/images/mm-branding", 'imagens removidas');
    ok(-f "$tmp/etc/pve/mm-tools/branding/$ASSET", 'blob jovem preservado pelo grace period');

    my ($rc3, $out3) = mm('--json', 'config', 'get');
    my $j = decode_json($out3);
    is($j->{config}{branding}{logo}, '', 'config limpo');

    # clear de novo (idempotente)
    my ($rc4, undef) = mm('branding', 'clear');
    is($rc4, 0, 'clear idempotente');
};

subtest 'assets_hash desatualizado nunca derruba load nem o clear' => sub {
    # liga o módulo e aponta p/ um logo com hash propositalmente errado,
    # simulando um upload que terminou parcialmente / drift entre nodes
    my ($rc0, $out0) = mm('config', 'set-module', 'branding', '--enable');
    is($rc0, 0, 'branding ligado') or diag $out0;
    my ($rc1, $out1) = mm('branding', 'set', '--logo', "$tmp/logo.png");
    is($rc1, 0, 'logo setado') or diag $out1;

    my $cfgpath = "$tmp/etc/pve/mm-tools/config.json";
    my $raw = do { local (@ARGV, $/) = ($cfgpath); <> };
    my $cfg = decode_json($raw);
    $cfg->{branding}{assets_hash} = 'sha256:' . ('0' x 64);    # hash errado
    open(my $fh, '>', $cfgpath) or die $!;
    print {$fh} JSON::PP->new->canonical->pretty->encode($cfg);
    close($fh);

    # GET config (passa por Config->load) não pode morrer por causa disso
    my ($rc2, $out2) = mm('--json', 'config', 'get');
    is($rc2, 0, 'config get sobrevive ao assets_hash inconsistente') or diag $out2;

    # clear precisa funcionar mesmo com o config nesse estado
    my ($rc3, $out3) = mm('branding', 'clear');
    is($rc3, 0, 'clear funciona com assets_hash inconsistente') or diag $out3;
};

subtest 'uso' => sub {
    my ($rc, $out) = mm('branding');
    isnt($rc, 0);
    like($out, qr/uso: mm-pve branding/, 'mensagem de uso');
};

done_testing();
