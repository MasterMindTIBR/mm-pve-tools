#!/usr/bin/perl
# Rock 5: guards, locks, PVE 9 references, idempotence and destroy boundary.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);

use lib "$Bin", "$Bin/../../lib", "$Bin/../lib-stubs";
use MockPve;
use MMPve::Module::Renumber;
use MMPve::Core::Runner;
use MMPve::Journal;

my $tmp = tempdir('mm-pve-rock5-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_ROOT} = $tmp;
$MMPve::Core::Runner::OVERRIDE = \&MockPve::handler;

sub fresh {
    MockPve->reset;
    remove_tree("$tmp/etc/pve/mm-tools/journal");
    make_path("$tmp/etc/pve");
    delete $ENV{MM_RENUMBER_FAIL_AFTER};
}

subtest 'PVE 9 HA sid e regras, sem group' => sub {
    fresh();
    $MockPve::S{ha} = [{ sid => 'vm:100', state => 'started', comment => 'ha' }];
    $MockPve::S{ha_rules} = [{ rule => 'affinity', type => 'node-affinity',
        resources => 'vm:100', nodes => 'n1', affinity => 'positive', order => 1 }];
    my $res = MMPve::Module::Renumber->run(from => 100, to => 1100, handle_ha => 1);
    ok($res->{ok}, 'renumber com HA e regra PVE 9') or diag explain $res;
    my ($ha_create) = grep { $_->{op} eq 'create' && $_->{path} eq '/cluster/ha/resources' }
        MockPve::ops();
    is($ha_create->{args}{sid}, 'vm:1100', 'recurso HA usa vm:<id>');
    ok(!exists $ha_create->{args}{group}, 'não envia group removido no PVE 9');
    my ($rule) = grep { $_->{op} eq 'set' && $_->{path} eq '/cluster/ha/rules/affinity' }
        MockPve::ops();
    is($rule->{args}{resources}, 'vm:1100', 'regra HA migra resources');
};

subtest 'backup só reescreve vmid/exclude e replicação preserva schema' => sub {
    fresh();
    push @{$MockPve::S{backups}}, { id => 'job-ex', all => 1, exclude => '100',
        storage => 'pbs', schedule => 'sun 03:00' };
    $MockPve::S{repl} = [{ id => '100-3', guest => 100, jobnum => 3, target => 'n2',
        source => 'n1', type => 'local', schedule => '*/30', rate => 10,
        comment => 'preserve', disable => 1 }];
    my $res = MMPve::Module::Renumber->run(from => 100, to => 1100,
        handle_replication => 1);
    ok($res->{ok}, 'renumber com backup e replicação') or diag explain $res;
    my ($exclude) = grep { $_->{op} eq 'set' && $_->{path} eq '/cluster/backup/job-ex' }
        MockPve::ops();
    is($exclude->{args}{exclude}, '1100', 'exclude é reescrito');
    ok(!exists $exclude->{args}{all} && !exists $exclude->{args}{storage},
        'campos não-VMID do backup não são enviados');
    my ($rep) = grep { $_->{op} eq 'create' && $_->{path} eq '/cluster/replication' }
        MockPve::ops();
    is($rep->{args}{id}, '1100-3', 'jobnum é preservado no novo id');
    for my $field (qw(comment disable rate schedule source target type)) {
        is($rep->{args}{$field}, $MockPve::S{repl}[0]{$field}, "$field preservado");
    }
    ok(!exists $rep->{args}{guest} && !exists $rep->{args}{jobnum},
        'guest/jobnum derivados não são enviados como opções inválidas');
};

subtest 'replicação fora do schema preservável recusa antes de começar' => sub {
    fresh();
    $MockPve::S{repl} = [{ id => '100-0', guest => 100, jobnum => 0,
        target => 'n2', type => 'local', unsupported => 'não-preservável' }];
    my $res = MMPve::Module::Renumber->run(from => 100, to => 1100,
        handle_replication => 1);
    ok(!$res->{ok}, 'job não preservável bloqueia o run');
    my ($check) = grep { $_->{check} eq 'replicacao-preservavel' } @{$res->{checks}};
    ok($check && !$check->{ok}, 'recusa é explícita no precheck');
    is_deeply([MockPve::ops()], [], 'nenhuma mutação antes da recusa');
};

subtest 'reserve retomado com VM existente só valida o marcador e não duplica' => sub {
    fresh();
    local $ENV{MM_RENUMBER_FAIL_AFTER} = 'reserve';
    eval { MMPve::Module::Renumber->run(from => 100, to => 1100) };
    my $j = MMPve::Journal->open('renumber-100-1100');
    $j->record('reserve', status => 'running');
    delete $ENV{MM_RENUMBER_FAIL_AFTER};
    my $res = MMPve::Module::Renumber->resume(from => 100, to => 1100);
    ok($res->{ok}, 'resume aceita a reserva própria existente') or diag explain $res;
    is(scalar(MockPve::ops('create', '/nodes/n1/qemu')), 1,
        'a reserva não é criada duas vezes');
};

subtest 'config edit usa lock_config e digest alterado aborta antes da mutação' => sub {
    fresh();
    my $locks = 0;
    {
        local $MMPve::Module::Renumber::CONFIG_LOCK = sub {
            my ($vmid, $code) = @_;
            $locks++;
            return $code->();
        };
        my $res = MMPve::Module::Renumber->run(from => 100, to => 1100);
        ok($res->{ok}, 'run protegido por lock_config') or diag explain $res;
    }
    cmp_ok($locks, '>=', 4, 'cada edição de configuração passou pelo lock_config');

    fresh();
    $MockPve::S{external_digest_on_status} = 2; # 1 no precheck, 1 antes do reserve
    my $err = eval { MMPve::Module::Renumber->run(from => 100, to => 1100) };
    like($@, qr/digest.*mudou/i, 'digest externo aborta');
    is(scalar(MockPve::ops('create', '/nodes/n1/qemu')), 0,
        'nenhuma operação irreversível começou após a mudança');
};

subtest 'marcador impede segunda execução enquanto heartbeat está fresco' => sub {
    fresh();
    my $j = MMPve::Journal->create('renumber-100-1100', from => 100, to => 1100,
        node => 'n1');
    $j->steps([qw(reserve move_disks config firewall refs verify destroy)]);
    $j->set_state('running');
    $j->claim_run(owner_node => 'n1', pid => 111, ttl => 120);
    is($j->data->{run_marker}{owner_node}, 'n1', 'marker registra owner node');
    is($j->data->{run_marker}{pid}, 111, 'marker registra pid');
    ok($j->data->{run_marker}{heartbeat}, 'marker registra heartbeat');
    my $err = eval { MMPve::Module::Renumber->resume(from => 100, to => 1100) };
    like($@, qr/já está em execução.*n1.*111/, 'segunda execução é recusada');
    $j->release_run(owner_node => 'n1', pid => 111);
};

subtest 'falha após destroy deixa run retomável, mas rollback é recusado' => sub {
    fresh();
    local $ENV{MM_RENUMBER_FAIL_AFTER} = 'destroy';
    my $err = eval { MMPve::Module::Renumber->run(from => 100, to => 1100) };
    ok($@, 'fault injection interrompeu após destroy');
    ok($MockPve::S{old_destroyed}, 'destroy realmente terminou');
    my $rollback = eval { MMPve::Module::Renumber->rollback(from => 100, to => 1100) };
    like($@, qr/rollback recusado.*destroy/i, 'rollback pós-destroy recusado');
    my $res = MMPve::Module::Renumber->resume(from => 100, to => 1100);
    ok($res->{ok}, 'resume fecha o passo destroy idempotentemente');
    is(MMPve::Journal->open('renumber-100-1100')->state, 'finished', 'run completo');
    eval { MMPve::Module::Renumber->rollback(from => 100, to => 1100) };
    like($@, qr/rollback recusado.*destroy/i, 'rollback continua recusado após finished');
};

done_testing();
