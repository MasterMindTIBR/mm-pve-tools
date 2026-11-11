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
use JSON::PP qw(decode_json);
use Getopt::Long qw(GetOptionsFromArray);
use POSIX qw(strftime);

use MMPve::Core::ModuleBase;
use parent qw(MMPve::Core::ModuleBase);

use MMPve::Core::Runner;
use MMPve::Core::Config;
use MMPve::Core::Util qw(root_path log_line read_file write_file_atomic ensure_dir now_iso flock_ex unlock random_uuid sha256_hex_of json_encode);
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
    die "invalid volid (expected <storage>:backup/vm/<id>/<ts>): "
        . (defined $volid ? $volid : '<undef>') . "\n"
        unless defined $volid
        && $volid =~ m{^([A-Za-z0-9][A-Za-z0-9_.-]*):backup/vm/(\d+)/([0-9][0-9T:.\-Z]*)$};
    return (storage => $1, vmid => $2 + 0, timestamp => $3);
}

# Decodifica o caminho vindo do File Restore (base64). Espaços e Unicode são
# aceitos; somente controles e traversal são proibidos.
sub decode_path_b64 {
    my ($class, $b64) = @_;
    die "base64 path is missing\n" unless defined $b64 && length $b64;
    my $path = eval { decode_base64($b64) };
    die "invalid base64 path\n" if $@ || !defined $path;
    utf8::decode($path) unless utf8::is_utf8($path);
    die "path must start with '/' (for example /drive-scsi1.img.fidx/part/2/Data)\n"
        unless $path =~ m{^/};
    die "path contains control characters\n" if $path =~ /[\x00-\x1F\x7F]/;
    die "path cannot contain '..'\n" if $path =~ m{(?:^|/)\.\.(?:/|$)};
    die "path is empty\n" if $path eq '/';
    $path =~ s{/+$}{};
    return $path;
}

# /drive-scsi1.img.fidx/part/2/Dados/Financeiro
#   → drive=drive-scsi1.img, part=2, subpath=Dados/Financeiro
# Buckets lvm/zpool/raw: fase 2 (Linux) — recusados com mensagem clara.
# O contrato v1 publica uma pasta dentro de uma partição (subpath não vazio);
# a partição ou o disco inteiro não são publicados.
sub require_folder {
    my ($class, $xlate) = @_;
    die "choose a folder inside the partition (drive-*.img.fidx/part/N/<folder>); "
        . "publishing the partition or the whole disk is not supported\n"
        unless defined $xlate->{part} && length($xlate->{subpath} // '');
    return $xlate;
}

sub translate_path {
    my ($class, $path) = @_;
    $path = $class->decode_path_b64($path) if $path !~ m{^/};
    my @segs = grep { length } split m{/}, $path;
        die "invalid path\n" unless @segs;
    for my $s (@segs) {
        die "bucket '$s' is not supported yet (phase 2 - Linux restore). "
            . "Use a folder inside a disk partition (drive-*.img.fidx/part/N/...).\n"
            if $s =~ /^(lvm|zpool|raw)$/i;
    }
    my ($drive) = $segs[0] =~ /^([A-Za-z0-9][A-Za-z0-9._-]*)\.fidx$/
        or die "the first path component must be a backup disk "
            . "(drive-*.img.fidx); got '$segs[0]'\n";
    shift @segs;
    my $part;
    if (@segs >= 2 && $segs[0] eq 'part' && $segs[1] =~ /^\d+$/) {
        $part = $segs[1] + 0;
        die "partition must be 1..128\n" if $part < 1 || $part > 128;
        splice(@segs, 0, 2);
    }
    my $subpath = join('/', @segs);
    die "path cannot end in 'part'\n" if !defined $part && @segs && $segs[-1] eq 'part';
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
    die "no destination VM NIC has a tag configured in restore.vlans. "
        . "Configure restore.vlans in mm-pve-tools or put the VM in a registered VLAN.\n";
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
    die "VM $vmid was not found in the cluster\n";
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
        # só ASCII: o pvesh decodifica o argumento e o PVE faz base64 da string
        # de caracteres, o que vira Latin-1 ("Á" chega ao gateway como 0xC1).
        # Com \uXXXX o JSON passa intacto.
        $json = ref $opt{input_data}
            ? json_encode($opt{input_data}, ascii => 1)
            : $opt{input_data};
        push @cmd, '--input-data', $json;
    }
    my $res = MMPve::Core::Runner->run(\@cmd, timeout => 60);
    die "gateway agent/exec failed: " . ($res->{err} || $res->{error} || "rc=$res->{rc}") . "\n"
        unless $res->{ok};
    my $pid;
    eval { $pid = (decode_json($res->{out}))->{pid} }
        or die "agent/exec response has no pid: $res->{out}\n";

    my $deadline = time + ($opt{timeout} // $GW_TIMEOUT);
    my $st;
    while (1) {
        $st = MMPve::Core::Runner->pvesh(get => "/nodes/$gw_node/qemu/$gwvmid/agent/exec-status",
            pid => $pid);
        last if $st->{exited};
        die "timeout (" . ($opt{timeout} // $GW_TIMEOUT) . "s) waiting for gateway (pid $pid)\n"
            if time >= $deadline;
        sleep($POLL_DELAY);
    }
    if (defined $st->{exitcode} && $st->{exitcode} != 0) {
        my $detail = $st->{'err-data'} // $st->{err} // '';
        $detail =~ s/\s+$//;
        # num traceback a exceção está no fim: guarda o final
        $detail = '...' . substr($detail, -500) if length($detail) > 500;
        die "gw-restore failed (exit " . $st->{exitcode} . ")"
            . (length($detail) ? ": $detail" : "") . "\n";
    }
    return $st->{'out-data'} // $st->{out} // '';
}

sub gateway_locate {
    my ($class, $cfg) = @_;
    my $gwvmid = $cfg->{restore}{gateway_vmid};
    die "restore.gateway_vmid is not configured (mm-pve-tools config)\n"
        unless defined $gwvmid && length $gwvmid;
    return ($class->find_node_of_vmid($gwvmid), $gwvmid);
}

# ------------------------------------------------------------ resultado (one-shot)

sub results_dir {
    my ($class) = @_;
    return root_path('/run/mm-pve-tools/results');
}

sub results_lock_path {
    my ($class) = @_;
    return $class->results_dir . '/.lock';
}

sub result_key_for_upid {
    my ($class, $upid) = @_;
    die "UPID is required to calculate result_key\n" unless defined $upid && length $upid;
    return sha256_hex_of($upid);
}

sub _result_key_ok {
    my ($key) = @_;
    return defined($key) && $key =~ /^[A-Fa-f0-9]{64}$/;
}

sub register_pending_result {
    my ($class, $key, $upid, $user) = @_;
    die "invalid result_key\n" unless _result_key_ok($key);
    die "UPID is missing\n" unless defined $upid && length $upid;
    my $dir = $class->results_dir;
    ensure_dir($dir, 0700);
    my $lock = flock_ex($class->results_lock_path);
    my $ok = eval {
        if (!-f "$dir/$key.json") {
            write_file_atomic("$dir/$key.pending", json_encode({
                user => $user, upid => $upid, created => now_iso(),
            }) . "\n", 0600);
        }
        1;
    };
    my $err = $@;
    unlock($lock);
    die $err unless $ok;
    return 1;
}

# grava resultado com a senha — NUNCA em log/journal/Task Log
sub save_result {
    my ($class, $key, $user, $data) = @_;
    die "invalid result_key\n" unless _result_key_ok($key);
    my $dir = $class->results_dir;
    ensure_dir($dir, 0700);
    chmod(0700, $dir);
    my $file = "$dir/$key.json";
    my $lock = flock_ex($class->results_lock_path);
    my $ok = eval {
        if (!-f $file) {
            write_file_atomic($file, json_encode({
                user    => $user,
                created => now_iso(),
                data    => $data,
            }) . "\n", 0600);
            chmod(0600, $file);    # write_file_atomic respeita umask; garante
        }
        unlink "$dir/$key.pending";
        1;
    };
    my $err = $@;
    unlock($lock);
    die $err unless $ok;
    return $file;
}

# leitura única: verifica dono sob lock, renomeia para uma claim opaca e só
# então lê; uma leitura não autorizada deixa o arquivo intacto.
sub fetch_result {
    my ($class, $key, $user, %opt) = @_;
    die "invalid result_key\n" unless _result_key_ok($key);
    my $dir = $class->results_dir;
    my $file = "$dir/$key.json";
    my $lock = flock_ex($class->results_lock_path);
    my ($data, $err);
    eval {
        if (!-f $file) {
            $err = -f "$dir/$key.pending"
                ? 'RESULT_UNFINISHED'
                : 'RESULT_NOT_FOUND: result not found (missing or already read - reads are one-shot)';
            die "$err\n";
        }
        my $meta = decode_json(read_file($file));
        my $allowed = !defined($user) || $opt{sys_modify}
            || $user eq 'root@pam' || $user eq ($meta->{user} // '');
        die "RESULT_FORBIDDEN: result belongs to another requester; only the task owner or Sys.Modify may read it\n"
            unless $allowed;
        my $claim = "$dir/$key.claim.$$";
        rename($file, $claim) or die "RESULT_NOT_FOUND: result not found\n";
        my $claimed = eval { read_file($claim) };
        my $read_err = $@;
        unlink($claim);
        die $read_err if $read_err;
        $data = decode_json($claimed)->{data};
        1;
    } or do { $err = $@ unless defined($err) && length($err) };
    unlock($lock);
    die $err if defined $err && length $err;
    return $data;
}

sub gc_results {
    my ($class, %opt) = @_;
    my $ttl = $opt{ttl} // 3600;
    my $dir = $class->results_dir;
    return 0 unless -d $dir;
    my $lock = flock_ex($class->results_lock_path);
    my $removed = 0;
    if (opendir(my $dh, $dir)) {
        while (my $entry = readdir($dh)) {
            # nome de readdir vem contaminado sob perl -T (worker da API)
            my ($name) = $entry =~ /^([A-Fa-f0-9]{64}\.(?:json|pending))$/ or next;
            my $path = "$dir/$name";
            my @st = stat($path);
            next unless @st && time - $st[9] > $ttl;
            $removed++ if unlink($path);
        }
        closedir($dh);
    }
    unlock($lock);
    return $removed;
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
    die "could not " . ($add ? 'add' : 'remove')
        . " a tag $TAG on VM $vmid: " . ($res->{err} || "rc=$res->{rc}") . "\n"
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
    die "gw-restore list output is not JSON\n" if $@;
    MMPve::Contract::Gateway->validate('list_response', $response);
    my $list = $response->{sessions};
    return wantarray ? @{$list} : $list;
}

sub revoke {
    my ($class, $sid, %opt) = @_;
    die "invalid session id\n" unless defined $sid && $sid =~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
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
        my $ok = ($line =~ /^(?:FAIL|ERROR|x|X)/i) ? 0 : 1;
        push @items, { ok => $ok, line => $line };
    }
    push @items, { ok => 1, line => 'selfcheck completed with no output' } unless @items;
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

    my %initial_vol = $class->parse_volid($spec->{backup});
    my $target_vmid = $spec->{vmid} // $initial_vol{vmid};
    my $jid = 'restore-publish-' . $target_vmid . '-' . substr(
        sha256_hex_of(($spec->{backup} // '') . ($spec->{path_b64} // '')), 0, 12);
    my $j;
    if ($arg{resume}) {
        $j = eval { MMPve::Journal->open($jid) };
        if ($j) {
            my $m = $j->meta;
            $spec->{$_} //= $m->{$_} for qw(backup path_b64 vmid hours ticket vm_ip user);
            $spec->{request_id} //= $m->{request_id};
        }
    }
    $spec->{request_id} //= random_uuid();
    $j //= MMPve::Journal->create($jid, %{$spec});
    $resume_cmd = _resume_cmd($spec);
    my $fail = sub {
        my ($step, $msg) = @_;
        chomp $msg;
        $j->mark_failed($step, $msg);
        log_line("restore publish FAILED at step $step: $msg");
        die "$msg\nTo continue: $resume_cmd\n";
    };
    $j->steps([qw(validate limits network gateway result tag)]);

    # --- validar
    eval {
        $j->mark_running('validate');
        die "backup is missing\n" unless defined $spec->{backup};
        my %vol = $class->parse_volid($spec->{backup});
        $spec->{owner_vmid} = $vol{vmid};
        $spec->{storage}    = $vol{storage};
        $spec->{timestamp}  = $vol{timestamp};
        $spec->{xlate} = $class->require_folder($class->translate_path($spec->{path_b64}));
        die "duration must be an integer from 1 to " . $r->{session_max_hours} . " hours\n"
            unless defined $spec->{hours} && $spec->{hours} =~ /^\d+$/
            && $spec->{hours} >= 1 && $spec->{hours} <= $r->{session_max_hours};
        if (defined $spec->{ticket}) {
            die "ticket must use the GLPI-<number> format\n"
                unless $spec->{ticket} =~ /^GLPI-\d+$/;
        }
        $spec->{vmid} //= $spec->{owner_vmid};
        $j->mark_done('validate');
    } or $fail->('validate', $@);

    # --- limites (max_sessions)
    eval {
        $j->mark_running('limits');
        my @sess = $class->sessions(config => $cfg);
        die "session limit reached (max_sessions="
            . $r->{max_sessions} . ", active=" . scalar(@sess) . ")\n"
            if scalar(@sess) >= $r->{max_sessions};
        $j->mark_done('limits');
    } or $fail->('limits', $@);

    # --- rede (VLAN, gateway, IP da VM)
    eval {
        $j->mark_running('network');
        $spec->{dest_node} = $class->find_node_of_vmid($spec->{vmid});
        my $conf = $class->vm_config($spec->{dest_node}, $spec->{vmid});
        $spec->{vlan} = $class->pick_vlan($conf, $r->{vlans});
        my $vent = $r->{vlans}{ $spec->{vlan} };
        $spec->{gw_ip}  = $vent->{gw_ip};
        $spec->{prefix} = $vent->{prefix};
        if (defined $spec->{vm_ip}) {
            die "IP $spec->{vm_ip} is outside the gateway prefix "
                . "$spec->{gw_ip}/$spec->{prefix}\n"
                unless $class->ip_in_prefix($spec->{vm_ip}, $spec->{gw_ip}, $spec->{prefix});
        } else {
            my $ifaces = eval {
                MMPve::Core::Runner->pvesh(get =>
                    "/nodes/$spec->{dest_node}/qemu/$spec->{vmid}/agent/network-get-interfaces");
            };
            $spec->{vm_ip} = $class->pick_vm_ip($ifaces, $spec->{gw_ip}, $spec->{prefix});
            die "guest agent unavailable on VM $spec->{vmid} and no --vm-ip was provided\n"
                unless defined $spec->{vm_ip};
            $j->record('network', vm_ip => $spec->{vm_ip});
        }
        $j->mark_done('network');
    } or $fail->('network', $@);

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
            die "could not read storage.cfg: $@\n" if $@;
        }
        my $storage = $storage_cfg->{ids}{ $spec->{storage} }
            or die "storage '$spec->{storage}' was not found in storage.cfg\n";
        die "the selected path does not contain a partition\n"
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
        $j->mark_running('result');
        $result = eval { decode_json($gw_out) };
        die "gw-restore publish output is not JSON\n" if $@;
        MMPve::Contract::Gateway->validate('publish_response', $result);
        die "gateway returned a different request_id\n"
            unless ($result->{request_id} // '') eq $spec->{request_id};
        my $key = $arg{result_key}
            || sha256_hex_of($spec->{request_id});
        $class->save_result($key, $spec->{user}, $result);
        $spec->{result_key} = $key;
        $j->record('result', result_key => $key);    # password excluded
        $j->mark_done('result');
    } or $fail->('result', $@);

    # --- tag restore-ativo
    eval {
        $j->mark_running('tag');
        $class->set_tag($spec->{dest_node}, $spec->{vmid}, 1);
        $j->mark_done('tag');
    } or do {
        chomp(my $warning = $@);
        $j->record('tag', warning => $warning);
        log_line("restore publish: session created, but tag was not applied: $warning");
    };

    $j->finish('published');
    log_line("restore publish ok vm=$spec->{vmid} vlan=$spec->{vlan} hours=$spec->{hours}"
        . ($spec->{ticket} ? " ticket=$spec->{ticket}" : ''));

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
    return { ok => 0, changed => 0, error => 'restore section is missing' } unless $r;
    return { ok => 0, changed => 0, error => 'restore.gateway_vmid is not configured' }
        unless defined $r->{gateway_vmid} && length $r->{gateway_vmid};
    return { ok => 0, changed => 0, error => 'restore.vlans is empty (no VLANs configured)' }
        unless $r->{vlans} && %{ $r->{vlans} };
    return { ok => 1, changed => 0, message => 'restore configured (gateway and VLANs are valid)' };
}

sub revert {
    my ($class) = @_;
    return { ok => 1, changed => 0, message => 'restore: nothing is applied per node' };
}

sub check {
    my ($class, $cfg) = @_;
    my $r = ($cfg // {})->{restore};
    return { ok => 0, note => 'restore section is missing' } unless $r;
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
            printf "would publish storage=%s source_vm=%d ts=%s drive=%s partition=%s subpath=%s\n",
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
            print json_encode({ %{$res}, result => $data }), "\n";
        } else {
            print "Publish created (VM $res->{vmid}, VLAN $res->{vlan}, expires $data->{expires_at})\n";
            print "UNC:      $data->{unc}\n";
            print "User:     $data->{user}\n";
            print "Password: $data->{password}\n";
            print "Keep the password: it will not be shown again.\n";
        }
        return 0;
    }
    if ($cmd eq 'sessions') {
        my %opt;
        GetOptionsFromArray($av, \%opt, 'json!') or return 2;
        my @s = $class->sessions;
        if ($opt{json}) {
            print json_encode(\@s), "\n";
        } else {
            if (!@s) { print "no active sessions\n"; return 0 }
            printf "%-14s %-8s %-15s %-16s %s\n", qw(ID VMID VLAN EXPIRES PATH);
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
            print STDERR "usage: mm-pve restore revoke <id> (see mm-pve restore sessions)\n";
            return 2;
        }
        my $res = $class->revoke($id);
        print "session $res->{id} revoked\n";
        return 0;
    }
    if ($cmd eq 'test-gateway') {
        my $res = $class->test_gateway;
        print "gateway: VM $res->{gateway_vmid} on node $res->{node}\n";
        for my $it (@{ $res->{items} }) {
            print(($it->{ok} ? 'OK' : 'FAIL'), ' ', $it->{line}, "\n");
        }
        return 1 if grep { !$_->{ok} } @{ $res->{items} };
        return 0;
    }
    print STDERR "usage: mm-pve restore <publish|sessions|revoke|test-gateway> [options]\n";
    return 2;
}

1;
