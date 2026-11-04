#!/usr/bin/env perl
# Valida imports PVE::* contra a lista emitida por um host PVE real.
# O fixture não existe no clone comum; o laboratório o gera antes de rodar.
use strict;
use warnings;
use File::Find qw(find);
use Test::More;

my $fixture = 't/fixtures/pve-perl-modules.txt';
plan skip_all => 'fixture de módulos PVE só é gerado no laboratório' unless -f $fixture;

open(my $fh, '<', $fixture) or die "abrir $fixture: $!\n";
my %available;
while (my $line = <$fh>) {
    $line =~ s/^\s+|\s+$//g;
    next unless $line =~ /^(PVE(?:::[A-Za-z_][A-Za-z0-9_]*)+)$/;
    $available{$1} = 1;
}
close($fh);

my %used;
find({
    no_chdir => 1,
    wanted => sub {
        return unless /\.pm\z/;
        open(my $source, '<', $_) or die "abrir $_: $!\n";
        while (my $line = <$source>) {
            $used{$1} = 1 if $line =~ /^\s*use\s+(PVE(?:::[A-Za-z_][A-Za-z0-9_]*)+)\b/;
        }
        close($source);
    },
}, qw(lib perl));

for my $module (sort keys %used) {
    ok($available{$module}, "$module existe no host PVE validado");
}

done_testing();
