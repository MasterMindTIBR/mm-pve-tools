#!/usr/bin/perl -T
# pvedaemon e pveproxy rodam com perl -T: um argumento vindo da requisição ou
# da config não pode impedir o Runner de executar o comando.
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(tainted);

my $lib;
BEGIN {
    require FindBin;
    ($lib) = "$FindBin::Bin/../../lib" =~ /\A(.*)\z/s;
}
use lib $lib;
use MMPve::Core::Runner;

$ENV{PATH} = '/usr/bin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

# dado lido de arquivo é contaminado sob -T
open my $fh, '<', __FILE__ or die "não li o próprio teste: $!";
my $line = <$fh>;
close $fh;
my $arg = substr($line, 0, 0) . 'mm-taint';
ok(tainted($arg), 'argumento de teste está contaminado');

my $r = MMPve::Core::Runner->run(['printf', '%s', $arg]);
is($r->{rc}, 0, 'comando executa com argumento contaminado')
    or diag($r->{error} // $r->{err});
is($r->{out}, 'mm-taint', 'argumento chega literal');

done_testing();
