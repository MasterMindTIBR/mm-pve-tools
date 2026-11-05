#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
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

subtest 'run_stream entrega saída incremental e suporta sem timeout' => sub {
    my @chunks;
    my $r = MMPve::Core::Runner->run_stream(
        ['sh', '-c', 'printf primeiro; printf segundo >&2'],
        timeout => 5, on_output => sub { push @chunks, [@_] },
    );
    ok($r->{ok}, 'comando streaming conclui');
    is($r->{out}, 'primeiro', 'stdout completo');
    is($r->{err}, 'segundo', 'stderr completo');
    is_deeply([map { $_->[1] } @chunks], [qw(stdout stderr)], 'callback identifica os streams');
    my $slow = MMPve::Core::Runner->run_stream(['sleep', '1']);
    ok($slow->{ok}, 'sem timeout explícito não interrompe o comando');
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

subtest 'pvesh delete aceita log da task antes do JSON final' => sub {
    my $fixture_path = "$Bin/../fixtures/api/delete-task.stdout";
    open(my $fh, '<', $fixture_path) or die "abrir $fixture_path: $!\n";
    local $/;
    my $mixed = <$fh>;
    close($fh);
    {
        local $MMPve::Core::Runner::OVERRIDE = sub {
            return { rc => 0, out => $mixed };
        };
        is(MMPve::Core::Runner->pvesh(delete => '/nodes/n/qemu/9510', purge => 1), undef,
            'delete com log + null JSON é sucesso');
    }
    my $tmp = tempdir('mm-runner-log-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    local $ENV{MM_PVE_ROOT} = $tmp;
    {
        local $MMPve::Core::Runner::OVERRIDE = sub {
            return { rc => 0, out => "purging VM 9510 from related configurations ...\n" };
        };
        is(MMPve::Core::Runner->pvesh(delete => '/nodes/n/qemu/9510', purge => 1), undef,
            'delete sem JSON, mas rc=0, é sucesso');
    }
    open(my $log, '<', "$tmp/var/log/mm-pve-tools.log") or die "abrir log: $!\n";
    my $logged = do { local $/; <$log> };
    close($log);
    like($logged, qr/purging VM 9510/, 'texto da task sem JSON vai para o log');
};

subtest 'pvesh get sem JSON falha com mensagem limpa' => sub {
    local $MMPve::Core::Runner::OVERRIDE = sub { return { rc => 0, out => "texto solto\n" } };
    eval { MMPve::Core::Runner->pvesh(get => '/nodes/n/status') };
    like($@, qr/saída não contém JSON\n\z/, 'erro termina em quebra de linha real');
    unlike($@, qr/ at \S+ line \d+/, 'sem "at ... line" do Perl');
};

done_testing();
