package MMPve::Core::Modules;

# Registro dos módulos instalados. Ordem = ordem de apply.

use strict;
use warnings;
use MMPve::Core::Patch;

our $VERSION = '@MM_PVE_VERSION@';

my @REGISTRY = qw(
    MMPve::Module::Renumber
    MMPve::Module::Restore
    MMPve::Module::Branding
    MMPve::Module::Ui
    MMPve::Module::Updates
    MMPve::Module::Poollimits
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
            MMPve::Core::Util->can('log_line') and MMPve::Core::Util::log_line("module $m unavailable: $@");
            next;
        };
        my $targets = eval { $m->patch_targets };
        die "patch registration for module $m failed: $@\n" if $@;
        if (ref($targets) eq 'ARRAY' && @{$targets}) {
            MMPve::Core::Patch->register_module($m);
        }
        push @ok, $m;
    }
    return @ok;
}

sub names {
    my ($class) = @_;
    return map { $_->name } $class->all;
}

1;
