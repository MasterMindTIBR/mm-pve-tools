#!/usr/bin/env perl
# Fluxo publish completo com mocks: payload enviado ao gateway, poll de
# exec-status, resultado one-shot 0600, tag restore-ativo, validações
# (duração, max_sessions, vm_ip, sem agent) e ausência de senha em
# journal/log.
use strict;
use warnings;
use utf8;
use lib 't/restore';
use RestoreTest;
use Test::More;
use JSON::PP qw(decode_json);

BEGIN { use_ok('MMPve::Module::Restore') }

my $R = 'MMPve::Module::Restore';
RestoreTest::setup();
local $MMPve::Module::Restore::POLL_DELAY = 0;

my $PATH = RestoreTest::b64('/drive-scsi1.img.fidx/part/2/Dados/Financeiro');
my $BACKUP = 'pbs1:backup/vm/100/2026-10-26T02:00:03Z';

sub run_publish {
    my (%arg) = @_;
    local $MMPve::Core::Runner::OVERRIDE = RestoreTest::make_override(%arg);
    local $MMPve::Module::Restore::GW_TIMEOUT = $arg{gw_timeout} // 300;
    my $res = eval { $R->publish(
        backup => $BACKUP, path_b64 => $PATH,
        storage_config => { ids => { pbs1 => { datastore => 'bkp01', namespace => 'cliente/a' } } },
        map { $_ => $arg{$_} } grep { defined $arg{$_} } qw(vmid hours ticket vm_ip user resume),
    ) };
    return ($res, $@);
}

# ---------- fluxo feliz (IP via guest agent) ----------
my ($res, $err) = run_publish(dest_tags => 'cli;producao');
ok($res && $res->{ok}, "publish ok") or diag $err;
is($res->{vmid}, 100, 'destino padrão = dona do backup');
is($res->{vlan}, 120, 'VLAN da net1 tag=120');
is($res->{expires_at}, '2026-10-28T10:00:00-03:00', 'expires_at');

# payload enviado ao gateway via --input-data
is(scalar @RestoreTest::payloads, 1, 'um --input-data no publish');
my $payload = decode_json($RestoreTest::payloads[0]);
is($payload->{contract}, 1, 'payload contract version');
is($payload->{archive}, 'drive-scsi1.img', 'payload archive');
is($payload->{partition}, 2, 'payload partition');
is($payload->{subpath}, 'Dados/Financeiro', 'payload subpath');
is($payload->{snapshot}, 'vm/100/2026-10-26T02:00:03Z', 'payload snapshot');
is($payload->{datastore}, 'bkp01', 'payload datastore do storage.cfg');
is($payload->{namespace}, 'cliente/a', 'payload namespace do storage.cfg');
is($payload->{vlan}, 120, 'payload vlan');
is($payload->{gw_ip}, '10.20.120.250', 'payload gw_ip');
is($payload->{prefix}, 24, 'payload prefix');
is($payload->{vm_ip}, '10.20.120.77', 'payload vm_ip (do agent)');
is($payload->{hours}, 24, 'payload hours (padrão)');
is($payload->{target_vmid}, 100, 'payload target VMID');
is($payload->{source_vmid}, 100, 'payload source VMID');

# comando exec correto no gateway
my @pub = grep { $_->[1] && $_->[1] eq 'publish' } @RestoreTest::execs;
is_deeply($pub[0], ['gw-restore', 'publish'], 'argv do agent/exec');

# resultado one-shot 0600
my $file = $res->{result_key};
my $path = "$ENV{MM_PVE_ROOT}/run/mm-pve-tools/results/$file.json";
ok(-f $path, 'arquivo de resultado criado');
is((stat($path))[2] & 0777, 0600, 'resultado 0600');
my $data = $R->fetch_result($file, 'root@pam');
is($data->{user}, 'gwr-abc123', 'resultado user');
ok(length($data->{password}), 'resultado password');
ok(!-f $path, 'leitura apaga o arquivo (one-shot)');
eval { $R->fetch_result($file, 'root@pam') };
like($@, qr/já foi lido|não existe/, 'segunda leitura falha');

# senha NUNCA em journal/log
my @hits = RestoreTest::grep_files($ENV{MM_PVE_CONFIG_DIR}, 'SECRETA-xyz');
my @logs = RestoreTest::grep_files("$ENV{MM_PVE_ROOT}/var/log", 'SECRETA-xyz');
is(scalar @hits, 0, 'senha ausente do journal');
is(scalar @logs, 0, 'senha ausente do log');

# tag adicionada preservando existentes
is(scalar @RestoreTest::tag_sets, 1, 'um set de tags');
like($RestoreTest::tag_sets[0], qr/producao/, 'tags preservadas');
like($RestoreTest::tag_sets[0], qr/restore-ativo/, 'tag restore-ativo adicionada');

# idempotência da tag
local $MMPve::Core::Runner::OVERRIDE = RestoreTest::make_override(
    dest_tags => 'producao;restore-ativo');
is($R->set_tag('pve1', 100, 1), 0, 'tag já presente → sem escrita');
is(scalar @RestoreTest::tag_sets, 0, 'nenhum set chamado');

# ---------- destino explícito + ticket + vm_ip manual ----------
($res, $err) = run_publish(vmid => 150, hours => 8, ticket => 'GLPI-4231',
    vm_ip => '10.20.120.50');
ok($res, 'publish com destino/ticket/vm_ip') or diag $err;
$payload = decode_json($RestoreTest::payloads[0]);
is($payload->{target_vmid}, 150, 'payload target VMID explícito');
is($payload->{hours}, 8, 'payload hours explícito');
is($payload->{ticket}, 'GLPI-4231', 'payload ticket');
is($payload->{vm_ip}, '10.20.120.50', 'vm_ip manual prevalece');

# ---------- validações que recusam ----------
($res, $err) = run_publish(hours => 169);
like($err, qr/duração precisa ser inteiro 1\.\.168/, 'duração acima do máximo');
like($err, qr/mm-pve restore publish .* --resume\n?\z/, 'erro termina com comando --resume');

($res, $err) = run_publish(ticket => 'X-1');
like($err, qr/GLPI-<número>/, 'ticket inválido');

($res, $err) = run_publish(vm_ip => '10.99.99.99');
like($err, qr/fora do prefixo do gateway/, 'vm_ip fora do prefixo');

# sem guest agent e sem --vm-ip
($res, $err) = run_publish(agent_ip => undef);
like($err, qr/guest agent indisponível .*--vm-ip/s, 'sem agent exige --vm-ip');
like($err, qr/--resume\n?\z/, 'mensagem de continuação presente');
unlike($err, qr/SECRETA/, 'sem senha no erro');

# max_sessions atingido
($res, $err) = run_publish(sessions => [
    { id => 'a', target_vmid => 100, source_vmid => 100, vlan => 120, vm_ip => '10.20.120.10', expires_at => '2026-10-29T00:00:00Z' },
    { id => 'b', target_vmid => 101, source_vmid => 101, vlan => 120, vm_ip => '10.20.120.11', expires_at => '2026-10-29T00:00:00Z' },
    { id => 'c', target_vmid => 102, source_vmid => 102, vlan => 120, vm_ip => '10.20.120.12', expires_at => '2026-10-29T00:00:00Z' },
]);
like($err, qr/limite de sessões atingido \(max_sessions=3, ativas=3\)/, 'max_sessions');

# gateway devolve exit != 0
($res, $err) = run_publish(exitcode => 2, gw_out => 'map falhou');
like($err, qr/gw-restore falhou \(exit 2\)/, 'erro do gateway sem stdout');
unlike($err, qr/map falhou/, 'stdout do gateway não vaza no erro');
unlike($err, qr/SECRETA/, 'sem senha no erro do gateway');

# timeout do poll
($res, $err) = run_publish(never_exit => 1, gw_timeout => 1);
like($err, qr/timeou?t \(1s\) esperando o gateway/, 'timeout do poll');

# resultado sem campo obrigatório
($res, $err) = run_publish(gw_result => { unc => 'x', user => 'u', password => 'p' });
like($err, qr/contract\.publish_response\.expires_at:/, 'resultado incompleto recusado');
unlike($err, qr/\bp\b.*password/xs, 'senha não vazada no erro');    # campo nomeado apenas

# ---------- resume: journal guarda vm_ip descoberto ----------
($res, $err) = run_publish(agent_ip => '10.20.120.77');
ok($res, 'publish para teste de journal');
my ($jfile) = glob("$ENV{MM_PVE_CONFIG_DIR}/journal/restore-publish-*.json");
ok($jfile, 'journal criado');
my $j = do { local $/; open(my $fh, '<', $jfile); <$fh> };
unlike($j, qr/SECRETA/, 'journal sem senha');
like($j, qr/vm_ip/, 'journal registra vm_ip p/ resume');

done_testing();
