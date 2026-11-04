package TestAPI;

use strict;
use warnings;
use FindBin qw($Bin);

sub setup_inc {
    unshift @INC, "$Bin/../../lib", "$Bin/../../perl";
}

sub real_pve {
    my @required = qw(PVE::RESTHandler PVE::RPCEnvironment PVE::JSONSchema);
    for my $module (@required) {
        (my $file = $module) =~ s{::}{/}g;
        $file .= '.pm';
        return (0, "$module ausente") unless eval { require $file; 1 };
        return (0, "$module veio de stub") if ($INC{$file} // '') =~ m{/t/lib-stubs/};
    }
    return (1, 'PVE real carregado');
}

sub fixture {
    my ($name) = @_;
    my $path = "$Bin/../fixtures/api/$name";
    open(my $fh, '<', $path) or die "abrir fixture $path: $!\n";
    local $/;
    my $raw = <$fh>;
    close($fh);
    return $raw;
}

1;
