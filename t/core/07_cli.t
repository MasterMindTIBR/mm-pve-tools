#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);

my $repo = "$Bin/../..";
my $tmp = tempdir('mm-pve-cli-XXXXXX', TMPDIR => 1, CLEANUP => 1);

my @ENVV = (
    "MM_PVE_ROOT=$tmp",
    "MM_PVE_CONFIG_DIR=$tmp/etc/pve/mm-tools",
);

sub mm {
    my (@args) = @_;
    my $out = `env @ENVV perl -I$repo/lib -I$repo/perl $repo/bin/mm-pve @args 2>&1`;
    return ($?, $out);
}

subtest 'version' => sub {
    my ($rc, $out) = mm('version');
    is($rc, 0);
    like($out, qr/mm-pve-tools/);
};

subtest 'config get (ausente → default + digest ausente)' => sub {
    my ($rc, $out) = mm('--json', 'config', 'get');
    is($rc, 0);
    my $j = eval { decode_json($out) };
    ok($j, 'json válido') or diag $out;
    is($j->{absent}, 1, 'absent');
    is($j->{config}{revision}, 1, 'default');
};

subtest 'config set + get + set-module' => sub {
    my $cfg = "$tmp/novo.json";
    system('mkdir', '-p', $tmp);
    open(my $fh, '>', $cfg) or die $!;
    print $fh '{"modules":{"renumber":1,"restore":0,"branding":0}}';
    close $fh;
    my ($rc, $out) = mm('config', 'set', '--file', $cfg);
    is($rc, 0, 'set ok') or diag $out;
    like($out, qr/revision/, 'mencionou revision');

    ($rc, $out) = mm('--json', 'config', 'get');
    my $j = decode_json($out);
    my $digest = $j->{digest};
    ok($digest =~ /^sha256:/, 'digest presente');

    ($rc, $out) = mm('config', 'set-module', 'branding', '--enable');
    is($rc, 0) or diag $out;

    # digest velho agora recusa (concorrência)
    open($fh, '>', "$tmp/novo2.json");
    print $fh '{"modules":{"renumber":1}}';
    close $fh;
    ($rc, $out) = mm('config', 'set', '--file', $cfg, '--digest', $digest);
    isnt($rc, 0, 'digest antigo recusado');
    like($out, qr/DIGEST_MISMATCH/, 'mensagem clara');

    # módulo inválido
    ($rc, $out) = mm('config', 'set-module', 'nan', '--enable');
    isnt($rc, 0, 'módulo desconhecido recusado');
};

subtest 'apply + status' => sub {
    my ($rc, $out) = mm('apply', '--no-patches');
    is($rc, 0, 'apply ok') or diag $out;
    ($rc, $out) = mm('--json', 'status');
    is($rc, 0);
    my $j = decode_json($out);
    ok($j->{node}, 'node');
    like($j->{applied}{state}, qr/applied/, 'aplicado');
};

subtest 'patch check em root vazio: file_missing, exit 0' => sub {
    my ($rc, $out) = mm('patch', 'check');
    is($rc, 0);
    like($out, qr/file_missing/, 'alvos ausentes reportados');
};

done_testing();
