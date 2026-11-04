# Para "perl -c" de arquivos do PVE fora de um node (job de âncoras do CI):
# um módulo que não existe em nenhum diretório do @INC vira um pacote vazio,
# com import que não faz nada, para o compilador chegar até o fim do arquivo.
# Fica no fim do @INC, então módulos reais e os stubs de t/lib-stubs vencem.
# Constantes importadas e usadas sem parênteses (ex.: HTTP_OK) precisam do
# módulo real instalado.
package MMAutoStub;
use strict;
use warnings;

push @INC, sub {
    my (undef, $file) = @_;
    return unless $file =~ m{\A([A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*)\.pm\z};
    (my $package = $1) =~ s{/}{::}g;
    my $source = "package $package; sub import {} sub unimport {} 1;\n";
    open(my $fh, '<', \$source) or die "MMAutoStub: $package: $!\n";
    return $fh;
};

1;
