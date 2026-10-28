#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP qw(decode_json);

my $repo = "$Bin/../..";
my $tmp  = "$Bin/tmp-cli";
system("rm -rf $tmp") == 0 or die;
system("mkdir -p $tmp") == 0 or die;

my @ENVV = (
    "MM_PVE_ROOT=$tmp",
    "MM_PVE_CONFIG_DIR=$tmp/etc/pve/mm-tools",
);

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

my $SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><circle r="9" fill="#0a0"/></svg>';
wr("$tmp/logo.svg", $SVG);
wr("$tmp/evil.svg", "<svg><script>x()</script></svg>");
wr("$tmp/fav.png", "\x89PNG\r\n\x1a\n" . ("\x00" x 16));

subtest 'set com arquivos em tmp' => sub {
    my ($rc, $out) = mm('branding', 'set', '--logo', "$tmp/logo.svg",
        '--favicon', "$tmp/fav.png", '--title', 'MasterMind Cloud',
        '--header-text', 'MM', '--login-text', 'Bem-vindo');
    is($rc, 0, 'exit 0') or diag $out;
    ok(-f "$tmp/etc/pve/mm-tools/branding/logo.svg", 'asset no branding_dir');
    ok(-f "$tmp/usr/share/pve-manager/images/mm-branding/logo.svg", 'asset aplicado');
    ok(-f "$tmp/usr/share/pve-manager/js/mm-branding.json", 'json aplicado');

    ($rc, $out) = mm('--json', 'config', 'get');
    my $j = decode_json($out);
    is($j->{config}{branding}{title}, 'MasterMind Cloud', 'título salvo no config');
    like($j->{config}{branding}{assets_hash}, qr/^sha256:/, 'assets_hash salvo');
    is($j->{config}{modules}{branding}, 0, 'módulo continua desligado (set não liga)');
};

subtest 'set recusa SVG sujo' => sub {
    my ($rc, $out) = mm('branding', 'set', '--logo', "$tmp/evil.svg");
    isnt($rc, 0, 'exit != 0');
    like($out, qr/recusado.*script|script.*recusado|contém <script>/, 'mensagem sobre script');
    ok(!-f "$tmp/etc/pve/mm-tools/branding/evil.svg", 'não gravou o SVG sujo');
};

subtest 'set idempotente / clear' => sub {
    my ($rc, $out) = mm('branding', 'set', '--title', 'Outro');
    is($rc, 0, 'set só texto ok') or diag $out;

    my ($rc2, $out2) = mm('branding', 'clear');
    is($rc2, 0, 'clear ok') or diag $out2;
    ok(!-f "$tmp/usr/share/pve-manager/js/mm-branding.json", 'json removido');
    ok(!-d "$tmp/usr/share/pve-manager/images/mm-branding", 'imagens removidas');
    ok(!-f "$tmp/etc/pve/mm-tools/branding/logo.svg", 'assets do pmxcfs removidos');

    my ($rc3, $out3) = mm('--json', 'config', 'get');
    my $j = decode_json($out3);
    is($j->{config}{branding}{logo}, '', 'config limpo');

    # clear de novo (idempotente)
    my ($rc4, undef) = mm('branding', 'clear');
    is($rc4, 0, 'clear idempotente');
};

subtest 'uso' => sub {
    my ($rc, $out) = mm('branding');
    isnt($rc, 0);
    like($out, qr/uso: mm-pve branding/, 'mensagem de uso');
};

system("rm -rf $tmp");
done_testing();
