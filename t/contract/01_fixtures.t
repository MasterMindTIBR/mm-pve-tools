#!/usr/bin/env perl
# Fixtures compartilhadas contrato/fixtures/*.json: o nome do arquivo
# (sem extensão) é a definição do schema. O MESMO arquivo é validado aqui
# (Perl, lado node) e em t/gateway/test_gw_restore.py (Python, lado
# gateway) contra o MESMO contract/gw-restore.v1.schema.json. Renomear um
# campo de um lado sem atualizar o schema/fixture quebra os dois testes.
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use Test::More;
use JSON::PP qw(decode_json);
use MMPve::Contract::Gateway;

my $dir = "$Bin/../../contract/fixtures";
opendir(my $dh, $dir) or die "abrir $dir: $!\n";
my @files = sort grep { /\.json$/ } readdir($dh);
closedir($dh);

ok(scalar(@files) >= 6, 'fixtures dos seis contratos presentes');

for my $file (@files) {
    my ($definition) = $file =~ /^(.+)\.json$/;
    open(my $fh, '<:encoding(UTF-8)', "$dir/$file") or die "abrir $file: $!\n";
    local $/;
    my $raw = <$fh>;
    close($fh);
    my $value = decode_json($raw);
    my $ok = eval { MMPve::Contract::Gateway->validate($definition, $value); 1 };
    ok($ok, "fixture $file valida contra contract.$definition") or diag($@);
}

done_testing();
