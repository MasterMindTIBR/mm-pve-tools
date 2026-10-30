package MMPve::Contract::Gateway;

use strict;
use warnings;
use feature 'state';
use JSON::PP qw(decode_json);
use File::Spec;
use MMPve::Core::Util qw(root_path read_file);

sub schema_path {
    return $ENV{MM_PVE_CONTRACT_DIR} . '/gw-restore.v1.schema.json'
        if defined $ENV{MM_PVE_CONTRACT_DIR};
    my $installed = root_path('/usr/share/mm-pve-tools/contract/gw-restore.v1.schema.json');
    return $installed if -f $installed;
    return File::Spec->rel2abs('contract/gw-restore.v1.schema.json');
}

sub schema {
    my ($class) = @_;
    state $path;
    state $schema;
    my $current = $class->schema_path;
    if (!defined($schema) || !defined($path) || $path ne $current) {
        $schema = decode_json(read_file($current));
        $path = $current;
    }
    return $schema;
}

sub _type_ok {
    my ($value, $type) = @_;
    return ref($value) eq 'HASH' if $type eq 'object';
    return ref($value) eq 'ARRAY' if $type eq 'array';
    return !ref($value) if $type eq 'string';
    return !ref($value) && defined($value) && $value =~ /^-?\d+$/ if $type eq 'integer';
    return ref($value) =~ /Boolean/ || (!ref($value) && ($value eq '0' || $value eq '1')) if $type eq 'boolean';
    return 1;
}

sub _resolve {
    my ($schema, $node) = @_;
    return $node unless $node->{'$ref'};
    my ($name) = $node->{'$ref'} =~ m{^#/definitions/([^/]+)$}
        or die "schema com ref inválida '$node->{'$ref'}'\n";
    my $definition = $schema->{definitions}{$name}
        or die "schema sem definição '$name'\n";
    return $definition;
}

sub _validate {
    my ($class, $schema, $node, $value, $where) = @_;
    $node = _resolve($schema, $node);
    if (defined $node->{type} && !_type_ok($value, $node->{type})) {
        die "$where: esperado $node->{type}\n";
    }
    if (exists $node->{const} && (!defined($value) || $value ne $node->{const})) {
        die "$where: esperado valor $node->{const}\n";
    }
    if (defined $node->{pattern} && (!defined($value) || $value !~ /$node->{pattern}/)) {
        die "$where: formato inválido\n";
    }
    if (defined $node->{minLength} && length($value) < $node->{minLength}) {
        die "$where: curto demais\n";
    }
    if (defined $node->{maxLength} && length($value) > $node->{maxLength}) {
        die "$where: longo demais\n";
    }
    if (defined $node->{minimum} && $value < $node->{minimum}) {
        die "$where: menor que $node->{minimum}\n";
    }
    if (defined $node->{maximum} && $value > $node->{maximum}) {
        die "$where: maior que $node->{maximum}\n";
    }
    if ($node->{enum} && !grep { defined($value) && $_ eq $value } @{ $node->{enum} }) {
        die "$where: valor inválido\n";
    }
    if ($node->{type} && $node->{type} eq 'object') {
        for my $key (@{ $node->{required} // [] }) {
            die "$where.$key: obrigatório\n" unless exists $value->{$key};
        }
        if (exists $node->{additionalProperties} && !$node->{additionalProperties}) {
            for my $key (keys %$value) {
                die "$where.$key: campo desconhecido\n" unless exists $node->{properties}{$key};
            }
        }
        for my $key (keys %{ $node->{properties} // {} }) {
            next unless exists $value->{$key};
            $class->_validate($schema, $node->{properties}{$key}, $value->{$key}, "$where.$key");
        }
    }
    if ($node->{type} && $node->{type} eq 'array' && $node->{items}) {
        for my $index (0 .. $#$value) {
            $class->_validate($schema, $node->{items}, $value->[$index], "$where\[$index\]");
        }
    }
    return $value;
}

sub validate {
    my ($class, $definition, $value) = @_;
    my $schema = $class->schema;
    my $node = $schema->{definitions}{$definition}
        or die "definição de contrato desconhecida '$definition'\n";
    return $class->_validate($schema, $node, $value, "contract.$definition");
}

1;
