package PVE::JSONSchema;
use strict;
use warnings;
use base 'Exporter';
our @EXPORT_OK = qw(get_standard_option register_standard_option);
my %std = (
    'pve-node' => { type => 'string', format => 'pve-node' },
);
sub register_standard_option { my ($name, $def) = @_; $std{$name} = $def }
sub get_standard_option { my ($name, %extra) = @_; die "standard option '$name' não conhecida no stub\n" unless $std{$name}; return { %{$std{$name}}, %extra } }
1;
