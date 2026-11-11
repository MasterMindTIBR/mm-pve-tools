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

# Saída real do lab (pvesh create num node remoto, rodado no lab1): o proxy junta
# a saída do worker remoto sem quebras e a devolve como uma string JSON. O bulk
# do updates falhava em todo node remoto com "saída do pvesh não contém UPID".
subtest 'extract_upid em saída de proxy para outro node' => sub {
    my $proxied = '"starting apt-get updateHit:1 http://security.debian.org/debian-security trixie-security InRelease'
        . 'Hit:2 http://deb.debian.org/debian trixie InReleaseReading package lists...'
        . '\\"UPID:lab3:00006A26:0008547E:6AF1F460:aptupdate::root@pam:\\""' . "\n";
    is(MMPve::Core::Runner->extract_upid($proxied), 'UPID:lab3:00006A26:0008547E:6AF1F460:aptupdate::root@pam:',
        'UPID no fim da string do proxy');
    my $mm = '"job 91556cbf-03db-4b6e-8d43-0f6e1c3a8e2b agendado'
        . '\\"UPID:lab3:0000690F:00083A65:6AF1F41E:mmupdates:updates-lab3:root@pam:\\""' . "\n";
    is(MMPve::Core::Runner->extract_upid($mm), 'UPID:lab3:0000690F:00083A65:6AF1F41E:mmupdates:updates-lab3:root@pam:',
        'run remoto do updates');
    my $local = "Reading package lists...\n\"UPID:lab1:000070BA:000856F1:6AF1F465:aptupdate::root\@pam:\"\n";
    is(MMPve::Core::Runner->extract_upid($local), 'UPID:lab1:000070BA:000856F1:6AF1F465:aptupdate::root@pam:',
        'node local continua igual');
    my $two = "\"log citando UPID:lab2:00000001:00000002:00000003:qmstart:100:root\@pam: antes"
        . '\\"UPID:lab3:0000690F:00083A65:6AF1F41E:mmupdates:updates-lab3:root@pam:\\""' . "\n";
    like(MMPve::Core::Runner->extract_upid($two), qr/^UPID:lab3:/, 'vale a última UPID da linha');
    ok(!eval { MMPve::Core::Runner->extract_upid("\"job agendado sem upid\"\n"); 1 }, 'sem UPID continua falhando');
};

subtest 'pvesh get sem JSON falha com mensagem limpa' => sub {
    local $MMPve::Core::Runner::OVERRIDE = sub { return { rc => 0, out => "texto solto\n" } };
    eval { MMPve::Core::Runner->pvesh(get => '/nodes/n/status') };
    like($@, qr/output does not contain JSON\n\z/, 'error ends with a real newline');
    unlike($@, qr/ at \S+ line \d+/, 'sem "at ... line" do Perl');
};

done_testing();
