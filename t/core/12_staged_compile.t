#!/usr/bin/perl
# O stage de um módulo é validado como o próprio módulo (require com hook no
# @INC), não como arquivo solto. Achado do lab: PVE/Storage.pm tem um ciclo de
# use (DirPlugin -> GuestImport::OVF -> PVE::Storage) e o "perl -c" do stage
# falhava até sem patch, revertendo o poollimits inteiro em todo node real.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

use lib "$Bin/../../lib";
use MMPve::Core::Patch;
use MMPve::Core::Runner;
use MMPve::Core::Util qw(write_file_atomic read_file);

my $lib = tempdir('mm-pve-staged-XXXXXX', TMPDIR => 1, CLEANUP => 1);
mkdir "$lib/Foo";
# Mesmo formato do Storage.pm: o módulo registra o plugin no corpo, e o plugin
# usa (via helper) o próprio módulo antes de definir o método.
write_file_atomic("$lib/Foo.pm", "package Foo;\nuse strict;\nuse Foo::Plugin;\nFoo::Plugin->register();\nsub vdisk_alloc { my (\$cfg) = \@_; return 1 }\n1;\n", 0644);
write_file_atomic("$lib/Foo/Plugin.pm", "package Foo::Plugin;\nuse strict;\nuse Foo::Helper;\nsub register { return 1 }\n1;\n", 0644);
write_file_atomic("$lib/Foo/Helper.pm", "package Foo::Helper;\nuse strict;\nuse Foo;\n1;\n", 0644);

my $stage = "$lib/Foo.pm.mm-stage-test";
my $patched = read_file("$lib/Foo.pm");
$patched =~ s/(my \(\$cfg\) = \@_;)/$1 my \$mm_hook = 1;/ or die 'patch de teste não aplicou';
write_file_atomic($stage, $patched, 0644);
my $target = { id => 'foo', path => '/usr/share/perl5/Foo.pm' };

local $ENV{PERL5LIB} = $lib;
my $loose = MMPve::Core::Runner->run(['perl', '-c', $stage], timeout => 60);
ok(!$loose->{ok}, 'perl -c do arquivo solto quebra no ciclo de use (o bug)');
like($loose->{err} // '', qr/register/, 'mesma falha do lab: método register ainda não existe');

my $res = MMPve::Core::Patch->_perl_c($stage, $target);
ok($res->{ok}, 'stage validado como módulo resolve o ciclo') or diag explain $res;

write_file_atomic($stage, "package Foo;\nuse strict;\nsub broken { \$undeclared = 1 }\n1;\n", 0644);
my $bad = MMPve::Core::Patch->_perl_c($stage, $target);
ok(!$bad->{ok}, 'erro real no stage continua falhando');
like($bad->{err} // '', qr/Global symbol "\$undeclared"/, 'com a mensagem do perl');

my $plain = MMPve::Core::Patch->_perl_c("$lib/Foo/Helper.pm", { path => '/etc/outro/Helper.pm' });
ok(defined($plain->{rc}), 'fora de /usr/share/perl5 continua usando perl -c');

subtest 'clear_failures esquece só as falhas' => sub {
    my $root = tempdir('mm-pve-clear-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    local $ENV{MM_PVE_ROOT} = $root;
    MMPve::Core::Patch->_save_patch_state({
        a => { previous_failure => 1, error => 'x' },
        b => { applied => 1 },
        c => { previous_failure => 1, error => 'y' },
    });
    is_deeply(MMPve::Core::Patch->clear_failures->{cleared}, [qw(a c)], 'limpa a e c');
    is_deeply([ sort keys %{ MMPve::Core::Patch::_patch_state() } ], ['b'], 'aplicado fica');
    is_deeply(MMPve::Core::Patch->clear_failures->{cleared}, [], 'segunda vez não há nada');
};

done_testing();
