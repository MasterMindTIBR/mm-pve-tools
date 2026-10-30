package MMPve::Module::Restore;

# Módulo restore (lado node) — publicação de pasta de backup PBS via VM
# gateway (plano: "Módulo restore", seção "No node").
#
# Regras de ouro:
#   * a senha do resultado NUNCA vai para log/journal/Task Log — só para
#     /run/mm-pve-tools/results/<key>.json (0600, one-shot, dono da tarefa);
#   * toda mensagem de erro termina com o comando exato para continuar;
use strict;
use warnings;
use utf8;
use MIME::Base64 qw(decode_base64);
use JSON::PP qw(encode_json decode_json);
use Getopt::Long qw(GetOptionsFromArray);
use POSIX qw(strftime);

use MMPve::Core::ModuleBase;
use parent qw(MMPve::Core::ModuleBase);

use MMPve::Core::Runner;
use MMPve::Core::Config;
use MMPve::Core::Util qw(root_path log_line read_file write_file_atomic ensure_dir now_iso);
use MMPve::Contract::Gateway;
use MMPve::Journal;

our $VERSION = '@MM_PVE_VERSION@';

# intervalo entre polls de agent/exec-status (sobrescrito em teste)
our $POLL_DELAY = 2;
# limite do poll do gateway (plano: 5 minutos)
our $GW_TIMEOUT = 300;

sub name { 'restore' }

# ------------------------------------------------------------ tradução

sub parse_volid {
    my ($class, $volid) = @_;
    die "volid inválido (esperado <storage>:backup/vm/<id>/<ts>): "
        . (defined $volid ? $volid : '<undef>') . "\n"
        unless defined $volid
        && $volid =~ m{^([A-Za-z0-9][A-Za-z0-9_.-]*):backup/vm/(\d+)/([0-9][0-9T:.\-Z]*)$};
    return (storage => $1, vmid => $2 + 0, timestamp => $3);
}

# Decodifica o caminho vindo do File Restore (base64). Espaços e Unicode são
# aceitos; somente controles e traversal são proibidos.
sub decode_path_b64 {
    my ($class, $b64) = @_;
    die "caminho em base64 ausente\n" unless defined $b64 && length $b64;
    my $path = eval { decode_base64($b64) };
    die "caminho base64 inválido\n" if $@ || !defined $path;
    utf8::decode($path) unless utf8::is_utf8($path);
    die "caminho precisa começar com '/' (ex.: /drive-scsi1.img.fidx/part/2/Dados)\n"
        unless $path =~ m{^/};
    die "caminho contém caracteres de controle\n" if $path =~ /[\x00-\x1F\x7F]/;
    die "caminho não pode conter '..'\n" if $path =~ m{(?:^|/)\.\.(?:/|$)};
    die "caminho vazio\n" if $path eq '/';
    $path =~ s{/+$}{};
    return $path;
}

# /drive-scsi1.img.fidx/part/2/Dados/Financeiro
#   → drive=drive-scsi1.img, part=2, subpath=Dados/Financeiro
# Buckets lvm/zpool/raw: fase 2 (Linux) — recusados com mensagem clara.
sub translate_path {
    my ($class, $path) = @_;
    $path = $class->decode_path_b64($path) if $path !~ m{^/};
    my @segs = grep { length } split m{/}, $path;
    die "caminho inválido\n" unless @segs;
    for my $s (@segs) {
        die "bucket '$s' ainda não suportado (fase 2 — restore de Linux). "
            . "Use uma pasta dentro de uma partição de disco (drive-*.img.fidx/part/N/...).\n"
            if $s =~ /^(lvm|zpool|raw)$/i;
    }
    my ($drive) = $segs[0] =~ /^([A-Za-z0-9][A-Za-z0-9._-]*)\.fidx$/
        or die "o primeiro componente do caminho precisa ser um disco do backup "
            . "(drive-*.img.fidx), veio '$segs[0]'\n";
    shift @segs;
    my $part;
    if (@segs >= 2 && $segs[0] eq 'part' && $segs[1] =~ /^\d+$/) {
        $part = $segs[1] + 0;
        die "partição precisa ser 1..128\n" if $part < 1 || $part > 128;
        splice(@segs, 0, 2);
    }
    my $subpath = join('/', @segs);
    die "caminho não pode terminar em 'part'\n" if !defined $part && @segs && $segs[-1] eq 'part';
    return {
        drive   => $drive,
        part    => $part,
        subpath => $subpath,
    };
}



sub _ip_to_num {
    my ($ip) = @_;
    return unless $ip =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
    my @o = ($1, $2, $3, $4);
    return if grep { $_ > 255 } @o;
    return ($o[0] << 24) | ($o[1] << 16) | ($o[2] << 8) | $o[3];
}

sub ip_in_prefix {
    my ($class, $ip, $net_ip, $prefix) = @_;
    my $a = _ip_to_num($ip) // return 0;
    my $b = _ip_to_num($net_ip) // return 0;
    return 0 if $prefix < 0 || $prefix > 32;
    my $mask = $prefix == 0 ? 0 : (0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF;
    return ($a & $mask) == ($b & $mask);
}

# VLAN: tag de NIC da VM destino que tem entrada em restore.vlans
sub pick_vlan {
    my ($class, $vmconf, $vlans) = @_;
    $vlans //= {};
    my @nets = sort { ($a =~ /(\d+)/)[0] <=> ($b =~ /(\d+)/)[0] }
        grep { /^net\d+$/ } keys %{$vmconf // {}};
    for my $n (@nets) {
        next unless ($vmconf->{$n} // '') =~ /(?:^|,)tag=(\d+)/;
        my $tag = $1;
        return $tag if $vlans->{$tag};
    }
    die "nenhuma NIC da VM destino tem tag com entrada em restore.vlans. "
        . "Configure restore.vlans no mm-pve-tools ou coloque a VM numa VLAN cadastrada.\n";
}

# escolhe IPv4 do guest agent dentro do prefixo do gateway
sub pick_vm_ip {
    my ($class, $ifaces, $gw_ip, $prefix) = @_;
    my $list = ref($ifaces) eq 'ARRAY' ? $ifaces : ($ifaces->{result} // []);
    for my $if (@{$list}) {
        next unless ref $if eq 'HASH';
        for my $addr (@{ $if->{'ip-addresses'} // [] }) {
            next unless ref $addr eq 'HASH';
            next unless ($addr->{'ip-address-type'} // '') eq 'ipv4';
            my $ip = $addr->{'ip-address'};
            next if !defined $ip || $ip =~ /^127\./;
            return $ip if $class->ip_in_prefix($ip, $gw_ip, $prefix);
        }
    }
    return undef;
}

# ------------------------------------------------------------ pvesh helpers

sub find_node_of_vmid {
    my ($class, $vmid) = @_;
    my $res = MMPve::Core::Runner->pvesh(get => '/cluster/resources', type => 'vm');
    for my $e (@{$res}) {
        next unless ref $e eq 'HASH' && ($e->{vmid} // -1) == $vmid;
        return $e->{node};
    }
    die "VM $vmid não encontrada no cluster\n";
}

sub vm_config {
    my ($class, $node, $vmid) = @_;
    return MMPve::Core::Runner->pvesh(get => "/nodes/$node/qemu/$vmid/config");
}

# executa um comando dentro da VM gateway via qga e espera até exited
sub gw_exec {
    my ($class, $gw_node, $gwvmid, $argv, %opt) = @_;
    my @cmd = ('pvesh', 'create', "/nodes/$gw_node/qemu/$gwvmid/agent/exec",
        '--output-format', 'json');
    push @cmd, '--command', $_ for @{$argv};
    my $json;
    if (defined $opt{input_data}) {
        $json = ref $opt{input_data} ? encode_json($opt{input_data}) : $opt{input_data};
        push @cmd, '--input-data', $json;
    }
    my $res = MMPve::Core::Runner->run(\@cmd, timeout => 60);
    die "agent/exec no gateway falhou: " . ($res->{err} || "rc=$res->{rc}") . "\n"
        unless $res->{ok};
    my $pid;
    eval { $pid = (decode_json($res->{out}))->{pid} }
        or die "resposta do agent/exec sem pid: $res->{out}\n";

    my $deadline = time + ($opt{timeout} // $GW_TIMEOUT);
    my $st;
    while (1) {
        $st = MMPve::Core::Runner->pvesh(get => "/nodes/$gw_node/qemu/$gwvmid/agent/exec-status",
            pid => $pid);
        last if $st->{exited};
        die "timeout (${GW_TIMEOUT}s) esperando o gateway (pid $pid)\n"
            if time >= $deadline;
        sleep($POLL_DELAY);
    }
    if (defined $st->{exitcode} && $st->{exitcode} != 0) {
        my $detail = $st->{err} // '';
        $detail =~ s/\s+$//;
        $detail = substr($detail, 0, 500) if length($detail) > 500;
        die "gw-restore falhou (exit " . $st->{exitcode} . ")"
            . (length($detail) ? ": $detail" : "") . "\n";
    }
    return $st->{out} // '';
}

sub gateway_locate {
    my ($class, $cfg) = @_;
    my $gwvmid = $cfg->{restore}{gateway_vmid};
    die "restore.gateway_vmid não configurado (mm-pve-tools config)\n"
        unless defined $gwvmid && length $gwvmid;
    return ($class->find_node_of_vmid($gwvmid), $gwvmid);
}

# ------------------------------------------------------------ resultado (one-shot)

sub results_dir {
    my ($class) = @_;
    return root_path('/run/mm-pve-tools/results');
}

# grava resultado com a senha — NUNCA em log/journal/Task Log
sub save_result {
    my ($class, $key, $user, $data) = @_;
    die "key inválida\n" unless $key =~ /^[A-Za-z0-9:._\@-]+$/;
    my $dir = $class->results_dir;
    ensure_dir($dir, 0700);
    chmod(0700, $dir);
    my $file = "$dir/$key.json";
    write_file_atomic($file, encode_json({
        user    => $user,
        created => now_iso(),
        data    => $data,
    }) . "\n", 0600);
    chmod(0600, $file);    # write_file_atomic respeita umask; garante
    return $file;
}

# leitura única: apaga o arquivo; só o dono da tarefa (ou root@pam)
sub fetch_result {
    my ($class, $key, $user) = @_;
    die "key inválida\n" unless $key =~ /^[A-Za-z0-9:._\@-]+$/;
    my $file = $class->results_dir . "/$key.json";
    my $raw = eval { read_file($file) };
    die "resultado não encontrado (não existe ou já foi lido — a leitura é única)\n" if $@;
    my $res = decode_json($raw);
    die "resultado pertence a '$res->{user}'; só o dono da tarefa pode lê-lo\n"
        unless !defined $user || $user eq 'root@pam' || $user eq ($res->{user} // '');
    unlink($file);
    return $res->{data};
}

# ------------------------------------------------------------ tags da VM destino

my $TAG = 'restore-ativo';

sub _parse_tags {
    my ($s) = @_;
    return () unless defined $s && length $s;
    return grep { length } split /[;,]/, $s;
}

sub set_tag {
    my ($class, $node, $vmid, $add) = @_;
    my $conf = $class->vm_config($node, $vmid);
    my @tags = _parse_tags($conf->{tags});
    my %have = map { $_ => 1 } @tags;
    if ($add) {
        return 0 if $have{$TAG};               # idempotente
        push @tags, $TAG;
    } else {
        return 0 unless $have{$TAG};
        @tags = grep { $_ ne $TAG } @tags;
    }
    my $val = join(';', @tags);
    my @cmd = ('pvesh', 'set', "/nodes/$node/qemu/$vmid/config",
        '--output-format', 'json');
    push @cmd, '--tags', $val;
    my $res = MMPve::Core::Runner->run(\@cmd, timeout => 30);
    die "não consegui " . ($add ? 'adicionar' : 'remover')
        . " a tag $TAG na VM $vmid: " . ($res->{err} || "rc=$res->{rc}") . "\n"
        unless $res->{ok};
    return 1;
}

# ------------------------------------------------------------ sessões

sub sessions {
    my ($class, %opt) = @_;
    my $cfg = $opt{config} // MMPve::Core::Config->load;
    my ($gwn, $gwvmid) = $class->gateway_locate($cfg);
    my $out = $class->gw_exec($gwn, $gwvmid, ['gw-restore', 'list', '--json'],
        timeout => $opt{timeout} // $GW_TIMEOUT);
    my $response = eval { decode_json($out) };
    die "saída do gw-restore list não é JSON\n" if $@;
    MMPve::Contract::Gateway->validate('list_response', $response);
    my $list = $response->{sessions};
    return wantarray ? @{$list} : $list;
}

sub revoke {
    my ($class, $sid, %opt) = @_;
    die "id de sessão inválido\n" unless defined $sid && $sid =~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
    my $cfg = $opt{config} // MMPve::Core::Config->load;
    my ($gwn, $gwvmid) = $class->gateway_locate($cfg);
    my @before = $class->sessions(config => $cfg);
    my ($sess) = grep { ($_->{id} // '') eq $sid } @before;
    $class->gw_exec($gwn, $gwvmid, ['gw-restore', 'revoke', $sid], timeout => 120);
    # tag sai na última revogação daquela VM
    my @after = eval { $class->sessions(config => $cfg) };
    @after = () if $@;
    my $vmid = $sess ? $sess->{target_vmid} : undef;
    if (defined $vmid && !grep { ($_->{target_vmid} // '') == $vmid } @after) {
        my $node = $class->find_node_of_vmid($vmid);
        $class->set_tag($node, $vmid, 0);
    }
    return { id => $sid, revoked => 1 };
}

sub test_gateway {
    my ($class, %opt) = @_;
    my $cfg = $opt{config} // MMPve::Core::Config->load;
    my ($gwn, $gwvmid) = $class->gateway_locate($cfg);
    my $out = $class->gw_exec($gwn, $gwvmid, ['gw-restore', 'selfcheck'], timeout => 120);
    my @items;
    for my $line (split /\n/, $out) {
        $line =~ s/\s+$//;
        next unless length $line;
        my $ok = ($line =~ /^[✘✗xX]/ || $line =~ /(?:FALH|ERRO|FAIL)/i) ? 0 : 1;
        push @items, { ok => $ok, line => $line };
    }
    push @items, { ok => 1, line => 'selfcheck executou sem saída' } unless @items;
    return { node => $gwn, gateway_vmid => $gwvmid, items => \@items };
}

# ------------------------------------------------------------ publish

sub _resume_cmd {
    my ($spec) = @_;
    my @c = ('mm-pve restore publish',
        "--backup $spec->{backup}",
        "--path-b64 $spec->{path_b64}");
    push @c, "--vmid $spec->{vmid}" if defined $spec->{vmid};
    push @c, "--hours $spec->{hours}" if defined $spec->{hours};
    push @c, "--ticket $spec->{ticket}" if defined $spec->{ticket};
    push @c, "--vm-ip $spec->{vm_ip}" if defined $spec->{vm_ip};
    return join(' ', @c, '--resume');
}

sub publish {
    my ($class, %arg) = @_;
    my $cfg = $arg{config} // MMPve::Core::Config->load;
    my $r = $cfg->{restore};
    my $spec = {
        backup   => $arg{backup},
        path_b64 => $arg{path_b64},
        vmid     => $arg{vmid},
        hours    => $arg{hours} // $r->{session_default_hours},
        ticket   => $arg{ticket},
        vm_ip    => $arg{vm_ip},
        user     => $arg{user} // 'root@pam',
    };
    my $resume_cmd;

    my $jid = 'restore-publish-' . substr(
        MMPve::Core::Util::sha256_hex_of(($spec->{backup} // '') . ($spec->{path_b64} // '')), 0, 12);
    my $j;
    if ($arg{resume}) {
        $j = eval { MMPve::Journal->open($jid) };
        if ($j) {
            my $m = $j->meta;
            $spec->{$_} //= $m->{$_} for qw(backup path_b64 vmid hours ticket vm_ip user);
            $spec->{request_id} //= $m->{request_id};
        }
    }
    $spec->{request_id} //= substr(MMPve::Core::Util::sha256_hex_of(
        join(':', $$, time, rand(), $spec->{backup} // '', $spec->{path_b64} // '')), 0, 32);
    $j //= MMPve::Journal->create($jid, %{$spec});
    $resume_cmd = _resume_cmd($spec);
    my $fail = sub {
        my ($step, $msg) = @_;
        chomp $msg;
        $j->mark_failed($step, $msg);
        log_line("restore publish FALHOU passo $step: $msg");
        die "$msg\nPara continuar: $resume_cmd\n";
    };
    $j->steps([qw(validar limites rede gateway resultado tag)]);

    # --- validar
    eval {
        $j->mark_running('validar');
        die "backup ausente\n" unless defined $spec->{backup};
        my %vol = $class->parse_volid($spec->{backup});
        $spec->{owner_vmid} = $vol{vmid};
        $spec->{storage}    = $vol{storage};
        $spec->{timestamp}  = $vol{timestamp};
        $spec->{xlate} = $class->translate_path($spec->{path_b64});
        die "duração precisa ser inteiro 1.." . $r->{session_max_hours} . " horas\n"
            unless defined $spec->{hours} && $spec->{hours} =~ /^\d+$/
            && $spec->{hours} >= 1 && $spec->{hours} <= $r->{session_max_hours};
        if (defined $spec->{ticket}) {
            die "chamado precisa ter formato GLPI-<número>\n"
                unless $spec->{ticket} =~ /^GLPI-\d+$/;
        }
        $spec->{vmid} //= $spec->{owner_vmid};
        $j->mark_done('validar');
    } or $fail->('validar', $@);

    # --- limites (max_sessions)
    eval {
        $j->mark_running('limites');
        my @sess = $class->sessions(config => $cfg);
        die "limite de sessões atingido (max_sessions="
            . $r->{max_sessions} . ", ativas=" . scalar(@sess) . ")\n"
            if scalar(@sess) >= $r->{max_sessions};
        $j->mark_done('limites');
    } or $fail->('limites', $@);

    # --- rede (VLAN, gateway, IP da VM)
    eval {
        $j->mark_running('rede');
        $spec->{dest_node} = $class->find_node_of_vmid($spec->{vmid});
        my $conf = $class->vm_config($spec->{dest_node}, $spec->{vmid});
        $spec->{vlan} = $class->pick_vlan($conf, $r->{vlans});
        my $vent = $r->{vlans}{ $spec->{vlan} };
        $spec->{gw_ip}  = $vent->{gw_ip};
        $spec->{prefix} = $vent->{prefix};
        if (defined $spec->{vm_ip}) {
            die "IP $spec->{vm_ip} fora do prefixo do gateway "
                . "$spec->{gw_ip}/$spec->{prefix}\n"
                unless $class->ip_in_prefix($spec->{vm_ip}, $spec->{gw_ip}, $spec->{prefix});
        } else {
            my $ifaces = eval {
                MMPve::Core::Runner->pvesh(get =>
                    "/nodes/$spec->{dest_node}/qemu/$spec->{vmid}/agent/network-get-interfaces");
            };
            $spec->{vm_ip} = $class->pick_vm_ip($ifaces, $spec->{gw_ip}, $spec->{prefix});
            die "guest agent indisponível na VM $spec->{vmid} e nenhum --vm-ip informado\n"
                unless defined $spec->{vm_ip};
            $j->record('rede', vm_ip => $spec->{vm_ip});
        }
        $j->mark_done('rede');
    } or $fail->('rede', $@);

    # --- chamada ao gateway
    my $gw_out;
    eval {
        $j->mark_running('gateway');
        my ($gwn, $gwvmid) = $class->gateway_locate($cfg);
        $spec->{gw_node} = $gwn;
        my $storage_cfg = $arg{storage_config};
        if (!$storage_cfg) {
            $storage_cfg = eval {
                require PVE::Storage;
                PVE::Storage::config();
            };
            die "não consegui ler storage.cfg: $@\n" if $@;
        }
        my $storage = $storage_cfg->{ids}{ $spec->{storage} }
            or die "storage '$spec->{storage}' não encontrado no storage.cfg\n";
        die "o caminho selecionado não contém uma partição\n"
            unless defined $spec->{xlate}{part};
        my $payload = {
            contract => 1,
            snapshot => 'vm/' . $spec->{owner_vmid} . '/' . $spec->{timestamp},
            datastore => $storage->{datastore} // $spec->{storage},
            namespace => $storage->{namespace} // '',
            archive => $spec->{xlate}{drive},
            partition => $spec->{xlate}{part},
            subpath => $spec->{xlate}{subpath},
            vlan => $spec->{vlan} + 0,
            gw_ip => $spec->{gw_ip},
            prefix => $spec->{prefix} + 0,
            vm_ip => $spec->{vm_ip},
            hours => $spec->{hours} + 0,
            requester => $spec->{user},
            source_vmid => $spec->{owner_vmid} + 0,
            target_vmid => $spec->{vmid} + 0,
            ticket => $spec->{ticket} // '',
            request_id => $spec->{request_id},
        };
        MMPve::Contract::Gateway->validate('publish_request', $payload);
        $j->record('gateway', payload_sent => 1);
        $gw_out = $class->gw_exec($gwn, $gwvmid,
            ['gw-restore', 'publish'], input_data => $payload);
        $j->mark_done('gateway');
    } or $fail->('gateway', $@);

    # --- resultado (senha só no arquivo one-shot)
    my $result;
    eval {
        $j->mark_running('resultado');
        $result = eval { decode_json($gw_out) };
        die "saída do gw-restore publish não é JSON\n" if $@;
        MMPve::Contract::Gateway->validate('publish_response', $result);
        my $key = $arg{result_key}
            || 'manual-' . $$ . '-' . substr(MMPve::Core::Util::sha256_hex_of($gw_out), 0, 10);
        $class->save_result($key, $spec->{user}, $result);
        $spec->{result_key} = $key;
        $j->record('resultado', result_key => $key);    # SEM a senha
        $j->mark_done('resultado');
    } or $fail->('resultado', $@);

    # --- tag restore-ativo
    eval {
        $j->mark_running('tag');
        $class->set_tag($spec->{dest_node}, $spec->{vmid}, 1);
        $j->mark_done('tag');
    } or do {
        chomp(my $warning = $@);
        $j->record('tag', warning => $warning);
        log_line("restore publish: sessão criada, mas tag não aplicada: $warning");
    };

    $j->finish('publicado');
    log_line("restore publish ok vm=$spec->{vmid} vlan=$spec->{vlan} horas=$spec->{hours}"
        . ($spec->{ticket} ? " chamado=$spec->{ticket}" : ''));

    return {
        ok         => 1,
        result_key => $spec->{result_key},
        vmid       => $spec->{vmid},
        vlan       => $spec->{vlan},
        hours      => $spec->{hours},
        expires_at => $result->{expires_at},
        # senha NÃO vai aqui — só no arquivo one-shot (fetch_result)
    };
}


# ------------------------------------------------------------ ModuleBase

sub validate_section {
    my ($class, $sec) = @_;
    return ();    # validação completa fica em MMPve::Core::Config::validate
}

sub apply {
    my ($class, $cfg) = @_;
    my $r = ($cfg // {})->{restore};
    return { ok => 0, changed => 0, error => 'seção restore ausente' } unless $r;
    return { ok => 0, changed => 0, error => 'restore.gateway_vmid não configurado' }
        unless defined $r->{gateway_vmid} && length $r->{gateway_vmid};
    return { ok => 0, changed => 0, error => 'restore.vlans vazio (nenhuma VLAN cadastrada)' }
        unless $r->{vlans} && %{ $r->{vlans} };
    return { ok => 1, changed => 0, message => 'restore configurado (gateway e VLANs ok)' };
}

sub revert {
    my ($class) = @_;
    return { ok => 1, changed => 0, message => 'restore: nada aplicado por node' };
}

sub check {
    my ($class, $cfg) = @_;
    my $r = ($cfg // {})->{restore};
    return { ok => 0, note => 'seção restore ausente' } unless $r;
    return {
        ok          => (defined $r->{gateway_vmid} && %{ $r->{vlans} // {} }) ? 1 : 0,
        gateway_vmid => $r->{gateway_vmid} // '',
        vlans        => scalar(keys %{ $r->{vlans} // {} }),
        max_sessions => $r->{max_sessions},
    };
}

# ------------------------------------------------------------ CLI

sub cli {
    my ($class, $av) = @_;
    my $cmd = shift @{$av} // '';
    if ($cmd eq 'publish') {
        my %opt;
        GetOptionsFromArray($av, \%opt,
            'backup=s', 'path-b64=s', 'vmid=i', 'hours=i', 'ticket=s',
            'vm-ip=s', 'json!', 'resume!', 'dry-run!',
        ) or return 2;
        if ($opt{'dry-run'}) {
            my %vol = $class->parse_volid($opt{backup});
            my $x = $class->translate_path($opt{'path-b64'});
            printf "publicaria storage=%s vm_origem=%d ts=%s drive=%s part=%s subpasta=%s\n",
                @vol{qw(storage vmid timestamp)}, $x->{drive},
                (defined $x->{part} ? $x->{part} : '-'), ($x->{subpath} || '-');
            return 0;
        }
        my $res = $class->publish(
            backup   => $opt{backup},
            path_b64 => $opt{'path-b64'},
            vmid     => $opt{vmid},
            hours    => $opt{hours},
            ticket   => $opt{ticket},
            vm_ip    => $opt{'vm-ip'},
            resume   => $opt{resume},
        );
        my $data = $class->fetch_result($res->{result_key}, undef);
        if ($opt{json}) {
            print encode_json({ %{$res}, result => $data }), "\n";
        } else {
            print "Publicação criada (VM $res->{vmid}, VLAN $res->{vlan}, expira $data->{expires_at})\n";
            print "UNC:      $data->{unc}\n";
            print "Usuário:  $data->{user}\n";
            print "Senha:    $data->{password}\n";
            print "Guarde a senha: ela não será mostrada de novo.\n";
        }
        return 0;
    }
    if ($cmd eq 'sessions') {
        my %opt;
        GetOptionsFromArray($av, \%opt, 'json!') or return 2;
        my @s = $class->sessions;
        if ($opt{json}) {
            print encode_json(\@s), "\n";
        } else {
            if (!@s) { print "nenhuma sessão ativa\n"; return 0 }
            printf "%-14s %-8s %-15s %-16s %s\n", qw(ID VMID VLAN EXPIRA PASTA);
            for my $s (@s) {
                printf "%-14s %-8s %-15s %-16s %s\n",
                    $s->{id} // '?', $s->{vmid} // '?', $s->{vlan} // '?',
                    $s->{expires_at} // '?', $s->{path} // '?';
            }
        }
        return 0;
    }
    if ($cmd eq 'revoke') {
        my $id = shift @{$av};
        unless (defined $id) {
            print STDERR "uso: mm-pve restore revoke <id> (veja mm-pve restore sessions)\n";
            return 2;
        }
        my $res = $class->revoke($id);
        print "sessão $res->{id} revogada\n";
        return 0;
    }
    if ($cmd eq 'test-gateway') {
        my $res = $class->test_gateway;
        print "gateway: VM $res->{gateway_vmid} no node $res->{node}\n";
        for my $it (@{ $res->{items} }) {
            print(($it->{ok} ? '✔' : '✘'), ' ', $it->{line}, "\n");
        }
        return 1 if grep { !$_->{ok} } @{ $res->{items} };
        return 0;
    }
    print STDERR "uso: mm-pve restore <publish|sessions|revoke|test-gateway> [opções]\n";
    return 2;
}

1;
