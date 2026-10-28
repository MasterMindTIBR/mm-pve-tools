#!/usr/bin/perl
# --resume (continua do primeiro passo não concluído) e --rollback (ordem
# inversa via journal), incluindo devolução dos discos e apagar a VM nova.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Path qw(make_path);

use lib "$Bin", "$Bin/../../lib";
use MockPve;
use MMPve::Module::Renumber;
use MMPve::Core::Runner;
use MMPve::Journal;

my $tmp = "$Bin/tmp-res";
system("rm -rf $tmp") == 0 or die;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_ROOT} = "$tmp";
make_path("$tmp/etc/pve/firewall");
open(my $fw, '>', "$tmp/etc/pve/firewall/100.fw") or die $!;
print $fw "[OPTIONS]\n";
close $fw;
$MMPve::Core::Runner::OVERRIDE = \&MockPve::handler;   ## no critic

subtest 'resume a partir do primeiro passo não concluído' => sub {
    MockPve->reset;
    $MockPve::S{fail_at} = 'refs';
    my $err = eval { MMPve::Module::Renumber->run(from => 100, to => 1100) };
    like($@, qr/mm-pve renumber --resume/, 'falha indica comando de retomada');
    my $n_ops_before = scalar MockPve::ops();

    # conserta a causa e retoma
    $MockPve::S{fail_at} = '';
    my $res = MMPve::Module::Renumber->resume(from => 100, to => 1100);
    ok($res->{ok}, 'resume ok') or diag explain $res;
    ok($MockPve::S{old_destroyed}, 'destroy completou após resume');

    # nenhum passo já concluído foi reexecutado (1 reserva, 3 move_disk)
    my @all = MockPve::ops();
    my @after = @all[ $n_ops_before .. $#all ];
    is(scalar(grep { $_->{op} eq 'create' && $_->{path} eq '/nodes/n1/qemu' } @all), 1,
        'reserva executada uma única vez');
    is(scalar(grep { $_->{path} eq '/nodes/n1/qemu/100/move_disk' } @all), 3,
        'move_disk executado uma vez por disco');
    # o que rodou depois da falha: refs → verify(GET) → destroy
    ok((grep { $_->{op} eq 'delete' && $_->{path} eq '/nodes/n1/qemu/100' } @after),
        'destroy veio depois do resume');
    ok(!(grep { $_->{op} eq 'create' && $_->{path} eq '/nodes/n1/qemu/100/move_disk' } @after),
        'discos não foram movidos de novo');

    my $j = MMPve::Journal->open('renumber-100-1100');
    is($j->state, 'finished', 'journal finished após resume');
    is($j->step_info('refs')->{status}, 'done', 'refs done no resume');
};

subtest 'rollback em ordem inversa' => sub {
    MockPve->reset;
    system("rm -rf $ENV{MM_PVE_CONFIG_DIR}/journal");
    $MockPve::S{fail_at} = 'config';   # concluiu reserve + move_disks
    my $err = eval { MMPve::Module::Renumber->run(from => 100, to => 1100) };
    ok($@, 'run falhou no config');
    my $j = MMPve::Journal->open('renumber-100-1100');
    is_deeply([ $j->done_steps ], [qw(reserve move_disks)], 'done: reserve, move_disks');

    my $n = scalar MockPve::ops();
    my $res = MMPve::Module::Renumber->rollback(from => 100, to => 1100);
    ok($res->{ok}, 'rollback ok') or diag explain $res;
    is_deeply($res->{undone}, [qw(move_disks reserve)], 'ordem inversa');
    my @after = (MockPve::ops())[ $n .. $#{ [MockPve::ops()] } ];

    # 1º: devolver discos (move_disk da nova para a antiga, 3x)
    my @back = grep { $_->{path} eq '/nodes/n1/qemu/1100/move_disk' } @after;
    is(scalar @back, 3, '3 discos devolvidos');
    is($back[0]{args}{'target-vmid'}, 100, 'move de volta para o ID antigo');
    # config original recriada na VM antiga (MAC/uuid preservados)
    my ($setold) = grep { $_->{op} eq 'set' && $_->{path} eq '/nodes/n1/qemu/100/config' } @after;
    ok($setold, 'config antiga recriada');
    is($setold->{args}{net0}, 'virtio=BC:24:11:AA:BB:CC,bridge=vmbr0', 'MAC devolvido');
    # último: apagar a VM nova vazia
    my ($delnew) = grep { $_->{op} eq 'delete' && $_->{path} eq '/nodes/n1/qemu/1100' } @after;
    ok($delnew, 'VM nova apagada');
    is($delnew->{args}{'destroy-unreferenced-disks'}, 0, 'sem destruir discos (já devolvidos)');
    # ordem: primeiro move_disk, por último delete da nova
    my @seq = grep { $_->{op} eq 'create' || $_->{op} eq 'delete' } @after;
    is($seq[0]{path}, '/nodes/n1/qemu/1100/move_disk', 'começa devolvendo disco');
    is($seq[-1]{path}, '/nodes/n1/qemu/1100', 'termina apagando a VM nova');

    $j = MMPve::Journal->open('renumber-100-1100');
    is($j->state, 'finished', 'journal finalizado');
    ok($j->data->{summary}{rolled_back}, 'resumo marca rolled_back');
};

subtest 'resume sem pendente e rollback sem done' => sub {
    MockPve->reset;
    system("rm -rf $ENV{MM_PVE_CONFIG_DIR}/journal");
    my $r = eval { MMPve::Module::Renumber->resume(from => 100, to => 1100) };
    like($@, qr/journal .*não encontrado/, 'resume sem journal explica');

    # journal sem nenhum passo done → rollback recusa
    MMPve::Journal->create('renumber-100-1100', from => 100, to => 1100, node => 'n1');
    my $e2 = eval { MMPve::Module::Renumber->rollback(from => 100, to => 1100) };
    like($@, qr/nenhum passo concluído/, 'rollback sem done recusa');
};

subtest 'rollback com refs: referências revertidas' => sub {
    MockPve->reset;
    system("rm -rf $ENV{MM_PVE_CONFIG_DIR}/journal");
    $MockPve::S{fail_at} = 'refs';
    eval { MMPve::Module::Renumber->run(from => 100, to => 1100) };
    my $j = MMPve::Journal->open('renumber-100-1100');
    is_deeply([ $j->done_steps ], [qw(reserve move_disks config firewall)],
        'done até firewall');

    my $n = scalar MockPve::ops();
    MMPve::Module::Renumber->rollback(from => 100, to => 1100);
    my @after = (MockPve::ops())[ $n .. $#{ [MockPve::ops()] } ];
    # firewall antigo restaurado, novo removido
    ok(-f "$tmp/etc/pve/firewall/100.fw", 'firewall antigo restaurado');
    ok(!-f "$tmp/etc/pve/firewall/1100.fw", 'firewall novo removido');
    # ordem inversa: firewall (undo) vem antes do move_disk de volta
    my @paths = map { $_->{path} } @after;
    my ($i_fw)  = grep { $paths[$_] eq '/etc/pve/firewall/1100.fw' } 0 .. $#paths;
    my ($i_mov) = grep { $paths[$_] eq '/nodes/n1/qemu/1100/move_disk' } 0 .. $#paths;
    ok(!defined $i_fw, 'op de firewall é local (arquivo), não pvesh');
    ok(defined $i_mov, 'move_disk de volta presente');
};

subtest 'CLI: flags e caminhos de erro' => sub {
    MockPve->reset;
    system("rm -rf $ENV{MM_PVE_CONFIG_DIR}/journal");
    my $rc = MMPve::Module::Renumber->cli([qw(--from 100 --to 1100 --dry-run --json)]);
    is($rc, 0, 'dry-run rc 0');
    $rc = MMPve::Module::Renumber->cli([qw(--from 100)]);
    is($rc, 2, 'sem --to → uso');
    # precheck recusando pela CLI
    $MockPve::S{vm_status}{status} = 'running';
    $rc = MMPve::Module::Renumber->cli([qw(--from 100 --to 1100)]);
    is($rc, 1, 'precheck falho → rc 1');
    is_deeply([MockPve::ops()], [], 'nada mutado pela CLI');
};

done_testing();
