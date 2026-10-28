package MMPve::Core::Modules;

# Registro dos módulos instalados. Ordem = ordem de apply.

use strict;
use warnings;

our $VERSION = '0.1.0';

my @REGISTRY = qw(
    MMPve::Module::Renumber
    MMPve::Module::Restore
    MMPve::Module::Branding
);

sub all {
    my ($class) = @_;
    my @ok;
    for my $m (@REGISTRY) {
        my $file = $m;
        $file =~ s{::}{/}g;
        $file .= '.pm';
        eval { require $file; 1 } or do {
            # módulo ausente = pacote parcialmente instalado; segue sem ele
            MMPve::Core::Util->can('log_line') and MMPve::Core::Util::log_line("módulo $m indisponível: $@");
            next;
        };
        push @ok, $m;
    }
    return @ok;
}

sub names {
    my ($class) = @_;
    return map { $_->name } $class->all;
}

1;
