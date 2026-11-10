package ModulePatchGuards;

use strict;
use warnings;

sub _scope_bounds {
    my ($target, $lines) = @_;
    return (undef, undef, 'scope_anchor ausente') unless exists $target->{scope_anchor};
    my @scope = grep { $lines->[$_] =~ $target->{scope_anchor} } 0 .. $#{$lines};
    return (undef, undef, 'scope_anchor não é único') unless @scope == 1;
    my $start = $scope[0];
    my $end;
    if ($lines->[$start] =~ /^\s*sub\s+[A-Za-z_][A-Za-z0-9_]*\b/) {
        for my $i ($start + 1 .. $#{$lines}) {
            if ($lines->[$i] =~ /^}\s*(?:#.*)?$/) {
                $end = $i;
                last;
            }
        }
        return (undef, undef, 'fecho de sub plain ausente') unless defined $end;
    } else {
        for my $i ($start + 1 .. $#{$lines}) {
            if ($lines->[$i] =~ /^\s*__PACKAGE__->register_method\s*\(/) {
                $end = $i - 1;
                last;
            }
        }
        $end = $#{$lines} unless defined $end;
    }
    return ($start, $end, undef);
}

sub _expected_start {
    my ($target, $lines) = @_;
    my $expected = $target->{expected_function};
    return (undef, 'expected_function ausente') unless defined($expected) && !ref($expected);
    my $pattern;
    if ($expected =~ /\Asub\s+([A-Za-z_][A-Za-z0-9_]*)\z/) {
        $pattern = qr/^\s*sub\s+\Q$1\E\b/;
    } elsif ($expected =~ /\Aname\s*=>\s*['"]([^'"]+)['"]\z/) {
        $pattern = qr/^\s*name\s*=>\s*['"]\Q$1\E['"],/;
    } else {
        return (undef, "expected_function inválida: $expected");
    }
    my @matches = grep { $lines->[$_] =~ $pattern } 0 .. $#{$lines};
    return (undef, "expected_function não é único: $expected") unless @matches == 1;
    return ($matches[0], undef);
}

sub check_target {
    my ($target, $lines, $insert_index) = @_;
    my @errors;
    my ($expected, $expected_error) = _expected_start($target, $lines);
    push @errors, $expected_error if $expected_error;
    my ($start, $end, $scope_error) = _scope_bounds($target, $lines);
    push @errors, $scope_error if $scope_error;
    push @errors, 'scope não começa na expected_function'
        if defined($expected) && defined($start) && $expected != $start;
    push @errors, 'linha inserida fora do escopo'
        if defined($insert_index) && defined($start) && defined($end)
            && ($insert_index <= $start || $insert_index > $end);
    if (defined($insert_index) && defined($start)) {
        my $line = $lines->[$insert_index];
        my @vars = $line =~ /(?<![A-Za-z0-9_:])(\$[A-Za-z_][A-Za-z0-9_]*)/g;
        my %seen;
        for my $var (grep { !$seen{$_}++ } @vars) {
            my $declared = 0;
            for my $i ($start .. $insert_index - 1) {
                if ($lines->[$i] =~ /\b(?:my|our)\b[^;\n]*\Q$var\E\b/) {
                    $declared = 1;
                    last;
                }
            }
            push @errors, "$var não declarado antes da inserção" unless $declared;
        }
    }
    return @errors;
}

1;
