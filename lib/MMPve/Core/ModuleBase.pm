package MMPve::Core::ModuleBase;

# Contrato de módulo (ver AGENTS.md):
#   name, validate_section($sec), apply($cfg), revert(), check($cfg), cli(\@argv)

use strict;
use warnings;
use MMPve::Core::Runner;

our $VERSION = '@MM_PVE_VERSION@';

sub name {
    my ($class) = @_;
    my $n = $class;
    $n =~ s/^MMPve::Module:://;
    return lc($n);
}

sub validate_section {
    my ($class, $section) = @_;
    return ();    # sem erros por padrão
}

sub apply {
    my ($class, $cfg) = @_;
    return { ok => 1, changed => 0, message => 'apply não implementado' };
}

sub revert {
    my ($class) = @_;
    return { ok => 1, changed => 0, message => 'revert não implementado' };
}

sub check {
    my ($class, $cfg) = @_;
    return { ok => 1, note => 'check não implementado' };
}

sub cli {
    my ($class, $argv) = @_;
    print STDERR "mm-pve " . $class->name . ": subcomando não implementado\n";
    return 2;
}

1;
