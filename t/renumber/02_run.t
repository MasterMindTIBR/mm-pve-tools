#!/usr/bin/perl
# Execução completa do renumber: dry-run sem mutação, ordem dos passos,
# journal antes/depois, preservação de MAC/uuid/vmgenid, firewall e refs.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Path qw(make_path);
use JSON::PP;

use lib "$Bin", "$Bin/../../lib";
use MockPve;
use MMPve::Module::Renumber;
use MMPve::Core::Runner;
use MMPve::Journal;

my $tmp = "$Bin/tmp-run";
system("rm -rf $tmp") == 0 or die;
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_ROOT} = "$tmp";
$MMPve::Core::Runner::OVERRIDE = \&MockPve::handler;   ## no critic

# firewall antigo para o passo firewall copiar
make_path("$tmp/etc/pve/firewall");
open(my $fw, '>', "$tmp/etc/pve/firewall/100.fw") or die $!;
print $fw "[OPTIONS]\n\n[IPSET firewall]\n10.0.0.1\n";
close $fw;

sub first_index_of {
    my ($op, $path) = @_;
    my @all = MockPve::ops();
    for my $i (0 .. $#all) {
        return $i if $all[$i]{op} eq $op && $all[$i]{path} eq $path;
    }
    return undef;
}

subtest 'dry-run: plano sem nenhuma chamada mutante' => sub {
    MockPve->reset;
    my $rc = MMPve::Module::Renumber->cli([qw(--from 100 --to 1100 --dry-run)]);
    is($rc, 0, 'rc 0');
    is_deeply([MockPve::ops()], [], 'nenhuma chamada mutante no dry-run');
};

subtest 'run completo' => sub {
    MockPve->reset;
    my $res = MMPve::Module::Renumber->run(from => 100, to => 1100);
    ok($res->{ok}, 'run ok') or diag explain $res;
    ok($MockPve::S{old_destroyed}, 'VM antiga apagada');
    like($res->{summary}, qr/vm\/100/, 'resumo lembra grupo PBS vm/100');
    like($res->{summary}, qr/PBS/, 'resumo menciona PBS');

    # reserva
    my ($create_vm) = MockPve::ops('create', '/nodes/n1/qemu');
    is($create_vm->{args}{vmid}, 1100, 'reserva vmid 1100');
    like($create_vm->{args}{name}, qr/-renumber$/, 'nome temporário');

    # ordem dos grupos de passos
    my @sigs = (
        ['create', '/nodes/n1/qemu'],
        ['create', '/nodes/n1/qemu/100/move_disk'],
        ['set',    '/nodes/n1/qemu/1100/config'],
        ['delete', '/nodes/n1/qemu/100'],
    );
    my @idx;
    for my $s (@sigs) {
        my $i = first_index_of(@$s);
        ok(defined $i, "op presente: @$s");
        push @idx, [ "@$s", $i ];
    }
    is_deeply([ map { $_->[1] } @idx ], [ sort { $a <=> $b } map { $_->[1] } @idx ],
        'ordem dos passos correta (reserva → mover → config → destroy)');

    # discos movidos um a um (scsi0, scsi1, efidisk0), esperando a tarefa
    my @moves = MockPve::ops('create', '/nodes/n1/qemu/100/move_disk');
    is(scalar @moves, 3, 'scsi0, scsi1 e efidisk0 movidos');
    for my $m (@moves) {
        is($m->{args}{'target-vmid'}, 1100, 'target-vmid novo');
        is($m->{args}{'target-disk'}, $m->{args}{disk}, 'mesmo slot');
    }

    # cloudinit: linha removida da VM antiga
    my ($ci_del) = grep { defined $_->{args}{delete} } MockPve::ops('set', '/nodes/n1/qemu/100/config');
    is($ci_del->{args}{delete}, 'ide2', 'cloudinit removido da antiga');

    # config copiado preserva MAC/smbios1/vmgenid
    my @cfgs = MockPve::ops('set', '/nodes/n1/qemu/1100/config');
    ok(@cfgs >= 1, 'config aplicado na nova');
    my %merged = map { %{ $_->{args} } } @cfgs;
    is($merged{net0},    'virtio=BC:24:11:AA:BB:CC,bridge=vmbr0', 'MAC preservado');
    is($merged{smbios1}, 'uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'uuid preservado');
    is($merged{vmgenid}, '11111111-2222-3333-4444-555555555555', 'vmgenid preservado');
    is($merged{ide2}, 'local:cloudinit', 'cloudinit recriado na nova');
    ok(!exists $merged{scsi0}, 'drive movido não vai no set config');
    # protection por último, em chamada separada
    my ($prot) = grep { exists $_->{args}{protection} } @cfgs;
    ok($prot, 'protection aplicado');
    is($prot->{args}{protection}, 1, 'protection sozinho na chamada');
    is($prot + 0, $cfgs[-1] + 0, 'protection é a última chamada de config');

    # firewall copiado
    ok(-f "$tmp/etc/pve/firewall/1100.fw", 'firewall novo criado');

    # refs: pool, ACL, backup com VMID explícito
    my ($pool) = MockPve::ops('set', '/pools/infra');
    is($pool->{args}{vms}, 1100, 'pool ganha ID novo');
    my ($acl) = MockPve::ops('set', '/access/acl');
    is($acl->{args}{path}, '/vms/1100', 'ACL recriada em /vms/1100');
    is($acl->{args}{users}, 'jung@pam', 'ACL mesmo usuário');
    my ($bk) = MockPve::ops('set', '/cluster/backup/job-1');
    is($bk->{args}{vmid}, '1100,200', 'job de backup com VMID explícito atualizado');
    my @all = MockPve::ops('set', '/cluster/backup/job-all');
    is(scalar @all, 0, 'job all não é tocado');

    # destroy com os flags do plano
    my ($del) = MockPve::ops('delete', '/nodes/n1/qemu/100');
    is($del->{args}{purge}, 1, 'purge 1');
    is($del->{args}{'destroy-unreferenced-disks'}, 0, 'destroy-unreferenced-disks 0');

    # journal: todos os passos done, com started (antes) e finished (depois)
    my $j = MMPve::Journal->open('renumber-100-1100');
    is($j->state, 'finished', 'journal finished');
    is_deeply([ $j->steps ], [qw(reserve move_disks config firewall refs verify destroy)],
        'step_order do journal');
    for my $s ($j->steps) {
        my $i = $j->step_info($s);
        is($i->{status}, 'done', "$s done");
        ok($i->{started},  "$s gravado ANTES (started)");
        ok($i->{finished}, "$s gravado DEPOIS (finished)");
    }
    like($j->data->{summary}{note}, qr/PBS/, 'journal guarda lembrete PBS');
};

subtest 'falha no meio: journal registra ANTES/DEPOIS e comando para continuar' => sub {
    MockPve->reset;
    $MockPve::S{fail_at} = 'refs';
    my $err = eval { MMPve::Module::Renumber->run(from => 100, to => 1100) };
    ok($@, 'run morre no passo refs');
    like($@, qr{mm-pve renumber --resume --from 100 --to 1100}, 'mensagem termina com comando exato');
    unlike($@, qr/(senha|token|password)/i, 'sem segredo na mensagem');

    my $j = MMPve::Journal->open('renumber-100-1100');
    is($j->state, 'failed', 'journal failed');
    is($j->step_info('reserve')->{status},    'done',   'reserve done');
    is($j->step_info('move_disks')->{status}, 'done',   'move_disks done');
    is($j->step_info('config')->{status},     'done',   'config done');
    is($j->step_info('firewall')->{status},   'done',   'firewall done');
    is($j->step_info('refs')->{status},       'failed', 'refs failed (depois de gravar ANTES como running)');
    like($j->step_info('refs')->{error}, qr/backup set falhou/, 'erro registrado');
    my @del = MockPve::ops('delete', '/nodes/n1/qemu/100');
    is(scalar @del, 0, 'destroy não rodou');
};

done_testing();
