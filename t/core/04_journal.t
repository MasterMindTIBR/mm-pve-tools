#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

use lib "$Bin/../../lib";
use MMPve::Journal;

my $tmp = tempdir('mm-pve-journal-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";

subtest 'ciclo de vida' => sub {
    my $j = MMPve::Journal->create('renumber-100-1100', vmid_from => 100, vmid_to => 1100);
    $j->steps([qw(reservar mover_discos config firewall refs checar destruir)]);

    is($j->first_pending, 'reservar', 'primeiro pendente');

    $j->mark_running('reservar');
    is($j->first_pending, 'reservar', 'running ainda é pendente p/ resume');
    $j->mark_done('reservar');
    is($j->first_pending, 'mover_discos', 'avança');

    $j->mark_running('mover_discos', detail => { disk => 'scsi0' });
    $j->mark_done('mover_discos');
    $j->mark_done('config');

    # falha no meio
    $j->mark_running('firewall');
    $j->mark_failed('firewall', 'arquivo .fw ausente');
    is($j->state, 'failed', 'estado failed');
    is($j->first_pending, 'firewall', 'resume refaz o passo falho');
};

subtest 'persistência entre processos' => sub {
    my $j = MMPve::Journal->open('renumber-100-1100');
    is($j->meta->{vmid_from}, 100, 'meta persistiu');
    is($j->first_pending, 'firewall', 'estado persistiu');
    my @done = $j->done_steps;
    is_deeply(\@done, [qw(reservar mover_discos config)], 'done em ordem');
    my @undo = $j->rollback_steps;
    is_deeply(\@undo, [qw(config mover_discos reservar)], 'rollback em ordem inversa');
};

subtest 'record/step_info' => sub {
    my $j = MMPve::Journal->open('renumber-100-1100');
    $j->record('mover_discos', disks => [qw(scsi0 scsi1)]);
    is_deeply($j->step_info('mover_discos')->{disks}, [qw(scsi0 scsi1)], 'dados p/ rollback');
};

subtest 'id inválido recusado' => sub {
    eval { MMPve::Journal->create('../escapa') };
    like($@, qr/id inválido/, 'sem path traversal');
};

done_testing();
