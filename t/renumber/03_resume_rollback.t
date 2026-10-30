#!/usr/bin/perl
# --resume (continua do primeiro passo não concluído) e --rollback (ordem
# inversa via journal), incluindo devolução dos discos e apagar a VM nova.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib "$Bin", "$Bin/../../lib", "$Bin/../lib-stubs";
use MockPve;
use MMPve::Module::Renumber;
use MMPve::Core::Runner;
use MMPve::Journal;
require PVE::Storage;    # stub (ver t/lib-stubs/PVE/Storage.pm) — R2.6 #9

my $tmp = tempdir('mm-pve-renumber-resume-XXXXXX', TMPDIR => 1, CLEANUP => 1);
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
    ok(!exists $delnew->{args}{purge}, 'sem --purge na VM nova (R2.6 #5)');
    is($delnew->{args}{'destroy-unreferenced-disks'}, 0, 'sem destruir discos (já devolvidos)');
    # protection: tinha sido limpa na antiga antes do move; volta a 1 no rollback (R2.6 #7 / acceptance B)
    is($MockPve::S{vm_config}{protection}, 1, 'protection restaurada na VM antiga após rollback');
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

subtest 'rollback após processo morto no meio do move_disks não perde disco — R2.6 #5 (acceptance A)' => sub {
    MockPve->reset;
    system("rm -rf $ENV{MM_PVE_CONFIG_DIR}/journal");
    # simula "mata o processo" depois de mover 1 de 3 discos: a próxima
    # chamada de move_disk falha, mas a 1ª já moveu de verdade (saiu da
    # antiga, está na nova) — journal não marca 'done' nem 'failed' num
    # kill de verdade, mas um 'failed' no meio é o mesmo cenário pro
    # rollback: ele não pode confiar que "não done" == "nada mudou".
    $MockPve::S{fail_after_moves} = 1;
    my $err = eval { MMPve::Module::Renumber->run(from => 100, to => 1100) };
    ok($@, 'run morre no meio do move_disks');

    my $j = MMPve::Journal->open('renumber-100-1100');
    is_deeply([ $j->done_steps ], [qw(reserve)], 'reserve done; move_disks não chegou a done');
    is($j->step_info('move_disks')->{status}, 'failed', 'move_disks falhou (não done)');

    # estado real: exatamente 1 disco migrou de verdade antes da queda
    my @moved_to_new = keys %{ $MockPve::S{new_vm_config} };
    is(scalar @moved_to_new, 1, 'exatamente 1 disco migrou de verdade antes da queda');
    my $moved_key = $moved_to_new[0];
    ok(!exists $MockPve::S{vm_config}{$moved_key}, "$moved_key saiu da antiga de verdade");
    my @still_old_volumes = grep { /^(?:scsi|efidisk)/ } keys %{ $MockPve::S{vm_config} };
    ok(scalar(@still_old_volumes) >= 1, 'pelo menos 1 outro disco nunca saiu da antiga');

    my $n = scalar MockPve::ops();
    my $res = MMPve::Module::Renumber->rollback(from => 100, to => 1100);
    ok($res->{ok}, 'rollback ok mesmo com move_disks não-done') or diag explain $res;
    is_deeply($res->{undone}, [qw(move_disks reserve)], 'desfaz move_disks (ao vivo) e reserve');

    # os discos terminam de volta na config real da antiga; a nova fica vazia
    ok(exists $MockPve::S{vm_config}{$moved_key}, "$moved_key devolvido à antiga");
    is(scalar(keys %{ $MockPve::S{new_vm_config} }), 0, 'VM nova fica sem nenhum disco');

    my @after = (MockPve::ops())[ $n .. $#{ [MockPve::ops()] } ];
    my @moveback = grep { $_->{op} eq 'create' && $_->{path} eq '/nodes/n1/qemu/1100/move_disk' } @after;
    is(scalar @moveback, 1, 'só 1 disco precisou ser movido de volta');
    is($moveback[0]{args}{disk}, $moved_key, 'o disco devolvido é o que realmente tinha sido movido');

    my ($delnew) = grep { $_->{op} eq 'delete' && $_->{path} eq '/nodes/n1/qemu/1100' } @after;
    ok($delnew, 'VM nova apagada');
    ok(!exists $delnew->{args}{purge}, 'sem --purge');
    is($delnew->{args}{'destroy-unreferenced-disks'}, 0, 'sem destroy-unreferenced-disks=1');
};

subtest 'resume após processo morto no meio do move_disks só move o que falta — R2.6 #6' => sub {
    MockPve->reset;
    system("rm -rf $ENV{MM_PVE_CONFIG_DIR}/journal");
    $MockPve::S{fail_after_moves} = 1;
    eval { MMPve::Module::Renumber->run(from => 100, to => 1100) };
    my $moved_key = (keys %{ $MockPve::S{new_vm_config} })[0];

    # conserta a causa e retoma
    $MockPve::S{fail_after_moves} = undef;
    my $n = scalar MockPve::ops();
    my $res = MMPve::Module::Renumber->resume(from => 100, to => 1100);
    ok($res->{ok}, 'resume completa') or diag explain $res;

    my @after = (MockPve::ops())[ $n .. $#{ [MockPve::ops()] } ];
    my @moves = grep { $_->{op} eq 'create' && $_->{path} eq '/nodes/n1/qemu/100/move_disk' } @after;
    ok(!(grep { $_->{args}{disk} eq $moved_key } @moves), 'disco já movido não é remexido no resume');
    is(scalar @moves, 2, 'os 2 discos restantes são movidos no resume');
};

subtest 'rollback com refs: HA/replicação voltam pro vmid antigo — R2.6 #10' => sub {
    MockPve->reset;
    system("rm -rf $ENV{MM_PVE_CONFIG_DIR}/journal");
    $MockPve::S{ha} = [{ sid => 'vmid:100', state => 'started' }];
    $MockPve::S{repl} = [{ id => 'rep1', guest => 100, target => 'n2', type => 'local' }];
    $MockPve::S{fail_at} = 'destroy';   # refs roda inteiro antes de falhar
    my $err = eval {
        MMPve::Module::Renumber->run(from => 100, to => 1100,
            handle_ha => 1, handle_replication => 1);
    };
    ok($@, 'run falha no destroy (refs já concluiu)');
    my $j = MMPve::Journal->open('renumber-100-1100');
    is_deeply([ $j->done_steps ], [qw(reserve move_disks config firewall refs verify)],
        'refs concluído antes da falha');

    my $n = scalar MockPve::ops();
    my $res = MMPve::Module::Renumber->rollback(from => 100, to => 1100);
    ok($res->{ok}, 'rollback ok') or diag explain $res;
    my @after = (MockPve::ops())[ $n .. $#{ [MockPve::ops()] } ];

    my ($ha_del_new) = grep { $_->{op} eq 'delete' && $_->{path} eq '/cluster/ha/resources/vmid:1100' } @after;
    ok($ha_del_new, 'HA novo removido no rollback');
    my ($ha_new_old) = grep { $_->{op} eq 'create' && $_->{path} eq '/cluster/ha/resources' } @after;
    is($ha_new_old->{args}{sid}, 'vmid:100', 'HA antigo recriado no rollback');

    my @rep_del = grep { $_->{op} eq 'delete' && $_->{path} =~ m{^/cluster/replication/1100-} } @after;
    ok(scalar(@rep_del) >= 1, 'job de replicação novo removido no rollback');
    my ($rep_new_old) = grep { $_->{op} eq 'create' && $_->{path} eq '/cluster/replication' } @after;
    is($rep_new_old->{args}{id}, 'rep1', 'job antigo (rep1) recriado no rollback');
};

subtest 'wait_task: segue running->stopped e morre limpo no timeout — R2.6 #3 (acceptance H)' => sub {
    MockPve->reset;
    local $MMPve::Core::Runner::OVERRIDE = \&MockPve::handler;   ## no critic
    local $MMPve::Module::Renumber::TASK_POLL = 0;

    my $upid_ok = 'UPID:n1:00000001:00000002:00000003:test:1:jung@pam:';
    $MockPve::S{task_status}{$upid_ok} = {
        sequence => [qw(running running stopped)], exitstatus => 'OK',
    };
    my $ok = eval { MMPve::Module::Renumber->wait_task($upid_ok) };
    ok($ok, 'completou depois de 2 "running"') or diag $@;

    my $upid_timeout = 'UPID:n1:00000004:00000005:00000006:test:2:jung@pam:';
    $MockPve::S{task_status}{$upid_timeout} = {
        sequence => [('running') x 5], exitstatus => 'OK',
    };
    my $err = eval { MMPve::Module::Renumber->wait_task($upid_timeout, timeout => 0) };
    ok($@, 'timeout morre (nunca chega a stopped)');
    like($@, qr/timeout/i, 'mensagem de timeout clara');
    like($@, qr/\Q$upid_timeout\E/, 'UPID aparece na mensagem');
};

done_testing();
