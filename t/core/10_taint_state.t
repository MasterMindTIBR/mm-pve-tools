#!/usr/bin/perl -T
# pvedaemon e pveproxy rodam com perl -T: dado lido de arquivo (config,
# journal) e nome vindo de readdir são contaminados. O código que roda dentro
# do worker da API não pode morrer ao montar caminho com eles.
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(tainted);
use File::Temp qw(tempdir);

my $lib;
BEGIN {
    require FindBin;
    ($lib) = "$FindBin::Bin/../../lib" =~ /\A(.*)\z/s;
}
use lib $lib;
use MMPve::Core::Util qw(read_file write_file_atomic root_path);
use MMPve::Core::Config;
use MMPve::Journal;
use MMPve::Module::Branding;
use MMPve::Module::Restore;

$ENV{PATH} = '/usr/bin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my ($tmp) = tempdir('mm-taint-XXXXXX', TMPDIR => 1, CLEANUP => 1) =~ /\A(.*)\z/s;
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
mkdir $_ for map { "$tmp$_" } qw(/etc /etc/pve /etc/pve/mm-tools /etc/pve/mm-tools/journal
    /etc/pve/mm-tools/branding /etc/pve/firewall /run /run/mm-pve-tools /run/mm-pve-tools/results);

subtest 'read_file devolve dado utilizável sob -T' => sub {
    write_file_atomic("$tmp/dado.json", qq({"from":"9510"}\n));
    my $data = read_file("$tmp/dado.json");
    ok(!tainted($data), 'conteúdo lido não está contaminado');
};

subtest 'journal relido monta caminho de firewall gravável' => sub {
    MMPve::Journal->create('renumber-9510-9520', from => 9510, to => 9520);
    my $j = MMPve::Journal->open('renumber-9510-9520');
    my $path = root_path('/etc/pve/firewall/' . $j->meta->{from} . '.fw');
    ok(eval { write_file_atomic($path, "[OPTIONS]\n", 0644); 1 }, 'grava firewall com vmid do journal')
        or diag($@);
    ok(unlink($path), 'apaga firewall com vmid do journal') or diag($!);
};

subtest 'GC de branding apaga asset órfão antigo' => sub {
    my $name = ('a' x 64) . '.png';
    my $file = MMPve::Core::Config->branding_dir . "/$name";
    write_file_atomic($file, 'png');
    utime(time - 3600, time - 3600, $file);
    my $deleted = eval { MMPve::Module::Branding->_gc_assets_locked({ branding => {} }) };
    is($@, '', 'GC não morre com nome vindo de readdir');
    is_deeply($deleted, [$name], 'asset órfão removido');
    ok(!-e $file, 'arquivo saiu do disco');
};

subtest 'GC de resultados de restore apaga resultado vencido' => sub {
    my $file = MMPve::Module::Restore->results_dir . '/' . ('b' x 64) . '.json';
    write_file_atomic($file, '{}');
    utime(time - 7200, time - 7200, $file);
    my $removed = eval { MMPve::Module::Restore->gc_results(ttl => 60) };
    is($@, '', 'GC não morre com nome vindo de readdir');
    is($removed, 1, 'resultado vencido removido');
};

done_testing();
