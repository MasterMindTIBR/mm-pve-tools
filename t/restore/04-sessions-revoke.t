#!/usr/bin/env perl
# Sessões (gw-restore list), revogação e remoção da tag na última sessão;
# arquivo de resultado: dono da tarefa, modo 0600, leitura única.
use strict;
use warnings;
use utf8;
use feature 'state';
use lib 't/restore';
use RestoreTest;
use Test::More;
use JSON::PP qw(encode_json decode_json);

BEGIN { use_ok('MMPve::Module::Restore') }

my $R = 'MMPve::Module::Restore';
RestoreTest::setup();
local $MMPve::Module::Restore::POLL_DELAY = 0;

# ---------- resultado: dono + one-shot ----------
my $key = 'UPID:pve1:0000012:0000AB:1:mmrestore:restore:100:root@pam:';
$R->save_result($key, 'admin@pve', { unc => 'u', password => 'x' });
my $f = "$ENV{MM_PVE_ROOT}/run/mm-pve-tools/results/$key.json";
is((stat($f))[2] & 0777, 0600, 'resultado 0600');
eval { $R->fetch_result($key, 'outro@pve') };
like($@, qr/só o dono da tarefa/, 'não-dono recusado');
ok(-f $f, 'arquivo intacto após recusa');
my $d = $R->fetch_result($key, 'admin@pve');
is($d->{unc}, 'u', 'dono lê o resultado');
ok(!-f $f, 'arquivo apagado na leitura');
eval { $R->fetch_result($key, 'admin@pve') };
like($@, qr/já foi lido|não existe/, 'one-shot');

# ---------- sessions ----------
local $MMPve::Core::Runner::OVERRIDE = RestoreTest::make_override(sessions => [
    { id => 'abc123', vmid => 100, vlan => 120, expires_at => '2026-10-28T10:00:00-03:00' },
]);
my @s = $R->sessions;
is(scalar @s, 1, 'uma sessão listada');
is($s[0]{id}, 'abc123', 'id da sessão');
my @list = grep { $_->[1] eq 'list' } @RestoreTest::execs;
is_deeply($list[0], ['gw-restore', 'list', '--json'], 'argv do list');

# ---------- revoke: última sessão → remove tag ----------
local $MMPve::Core::Runner::OVERRIDE = RestoreTest::make_override(
    dest_tags => 'producao;restore-ativo',
    sessions => [ { id => 'abc123', vmid => 100, vlan => 120 } ],
);
# make_override devolve sempre a mesma lista; para simular "última sessão"
# (lista pré com a sessão, pós vazia) usamos um mock local com estado.
{
    no warnings 'redefine';
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($argv) = @_;
        my $cmd = join(' ', @$argv);
        if ($cmd =~ /agent\/exec /) {
            return { ok => 1, rc => 0, out => '{"pid":77}', err => '' };
        }
        if ($cmd =~ /exec-status/) {
            state $n = 0; $n++;
            # 1ª chamada: list pré-revoke (com a sessão); depois: '[]'
            return { ok => 1, rc => 0, out => encode_json({
                exited => 1, pid => 77, exitcode => 0,
                out => $n == 1 ? encode_json([ { id => 'abc123', vmid => 100 } ]) : '[]',
                err => '' }), err => '' };
        }
        if ($cmd =~ /cluster\/resources/) {
            return { ok => 1, rc => 0, out => encode_json([
                { vmid => 100, node => 'pve1' }, { vmid => 9000, node => 'gw' }]), err => '' };
        }
        if ($cmd =~ /^pvesh get .*qemu\/100\/config/) {
            return { ok => 1, rc => 0, out => encode_json({
                net1 => 'bridge=vmbr1,tag=120', tags => 'producao;restore-ativo' }), err => '' };
        }
        if ($cmd =~ /^pvesh set .*qemu\/100\/config/) {
            my ($tags) = $cmd =~ /--tags (\S+)/;
            push @RestoreTest::tag_sets, $tags;
            return { ok => 1, rc => 0, out => 'null', err => '' };
        }
        return { ok => 0, rc => 42, out => '', err => "sem rota: $cmd" };
    };
    my $r = $R->revoke('abc123');
    ok($r->{revoked}, 'revoke ok');
    my @rev = grep { $_ && $_->[1] eq 'revoke' } @RestoreTest::execs;
    is_deeply($rev[0], ['gw-restore', 'revoke', 'abc123'], 'argv do revoke') if @rev;
    is(scalar @RestoreTest::tag_sets, 1, 'tag removida uma vez');
    unlike($RestoreTest::tag_sets[0], qr/restore-ativo/, 'tag restore-ativo saiu');
    like($RestoreTest::tag_sets[0], qr/producao/, 'demais tags preservadas');
}

# ---------- revoke: ainda há sessão da VM → tag fica ----------
{
    @RestoreTest::tag_sets = ();
    local $MMPve::Core::Runner::OVERRIDE = sub {
        my ($argv) = @_;
        my $cmd = join(' ', @$argv);
        if ($cmd =~ /agent\/exec /) {
            return { ok => 1, rc => 0, out => '{"pid":78}', err => '' };
        }
        if ($cmd =~ /exec-status/) {
            state $n = 0; $n++;
            # 1ª consulta (list pré) e 2ª (list pós) ainda têm sessão da VM 100
            return { ok => 1, rc => 0, out => encode_json({
                exited => 1, pid => 78, exitcode => 0,
                out => encode_json([ { id => 'outro', vmid => 100 } ]), err => '' }), err => '' };
        }
        if ($cmd =~ /cluster\/resources/) {
            return { ok => 1, rc => 0, out => encode_json([
                { vmid => 100, node => 'pve1' }, { vmid => 9000, node => 'gw' }]), err => '' };
        }
        return { ok => 0, rc => 42, out => '', err => "sem rota: $cmd" };
    };
    $R->revoke('abc123');
    is(scalar @RestoreTest::tag_sets, 0, 'tag mantida com sessão restante');
}

# id inválido
eval { $R->revoke('../escapa') };
like($@, qr/id de sessão inválido/, 'id inválido recusado');

done_testing();
