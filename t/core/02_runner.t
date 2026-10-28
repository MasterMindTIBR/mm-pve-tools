#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

use lib "$Bin/../../lib";
use MMPve::Core::Runner;

subtest 'run básico' => sub {
    my $r = MMPve::Core::Runner->run(['echo', 'ola']);
    ok($r->{ok}, 'rc 0');
    is($r->{out}, "ola\n", 'stdout');
};

subtest 'run falha' => sub {
    my $r = MMPve::Core::Runner->run(['sh', '-c', 'echo pro-err >&2; exit 3']);
    ok(!$r->{ok}, 'rc!=0');
    is($r->{rc}, 3, 'rc propagado');
    is($r->{err}, "pro-err\n", 'stderr capturado');
};

subtest 'timeout' => sub {
    my $r = MMPve::Core::Runner->run(['sleep', '10'], timeout => 1);
    ok(!$r->{ok}, 'sleep morto');
    ok($r->{timeout}, 'flag timeout');
};

subtest 'stdin' => sub {
    my $r = MMPve::Core::Runner->run(['cat'], stdin => "linha1\n");
    is($r->{out}, "linha1\n", 'stdin chega ao comando');
};

subtest 'executável ausente' => sub {
    my $r = MMPve::Core::Runner->run(['binario-que-nao-existe-xyz']);
    ok(!$r->{ok}, 'falha');
    is($r->{rc}, 127, 'rc 127');
};

subtest 'OVERRIDE' => sub {
    no warnings 'once';
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($argv, $stdin) = @_;
        return { rc => 0, out => '{"ok":true}' };
    };
    my $r = MMPve::Core::Runner->run(['qualquer', 'coisa']);
    ok($r->{ok}, 'override ok');
    my $j = MMPve::Core::Runner->run_json(['x']);
    is($j->{ok}, 1, 'json decodificado');
};

subtest 'pvesh builder' => sub {
    no warnings 'once';
    my @vistos;
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($argv) = @_;
        push @vistos, [@$argv];
        return { rc => 0, out => 'null' };
    };
    my $r = MMPve::Core::Runner->pvesh('get', '/cluster/status', __timeout => 7);
    is($r, undef, 'null → undef');
    is_deeply($vistos[0],
        ['pvesh', 'get', '/cluster/status', '--output-format', 'json'],
        '__timeout NÃO vira flag') or diag explain \@vistos;
    MMPve::Core::Runner->pvesh('create', '/nodes/n/qemu', vmid => 100, name => 'x');
    like(join(' ', @{ $vistos[1] }), qr/--name x/, 'args viram --chave valor');
};

done_testing();
