package TestAPI;

use strict;
use warnings;
my $repo_dir;
BEGIN {
    require FindBin;
    ($repo_dir) = "$FindBin::Bin/../.." =~ /\A(.*)\z/s;
}

sub setup_inc {
    unshift @INC, "$repo_dir/lib", "$repo_dir/perl";
}

sub real_pve {
    my @required = qw(PVE::RESTHandler PVE::RPCEnvironment PVE::JSONSchema);
    for my $module (@required) {
        (my $file = $module) =~ s{::}{/}g;
        $file .= '.pm';
        return (0, "$module ausente") unless eval { require $file; 1 };
        return (0, "$module veio de stub") if ($INC{$file} // '') =~ m{(?:^|[\\/])t/lib-stubs[\\/]};
    }
    return (1, 'PVE real carregado');
}

sub fixture {
    my ($name) = @_;
    my $path = "$repo_dir/t/fixtures/api/$name";
    open(my $fh, '<', $path) or die "abrir fixture $path: $!\n";
    local $/;
    my $raw = <$fh>;
    close($fh);
    return $raw;
}

1;
