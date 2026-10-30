package RestoreTest;
# Helper dos testes do módulo restore: ambiente temporário + config +
# fábrica de mocks do Runner (pvesh/qga via OVERRIDE).
use Exporter qw(import);
use strict;
use warnings;
use utf8;
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use File::Temp qw(tempdir);
use feature 'state';
use MMPve::Core::Config;
our @EXPORT_OK = qw(setup b64);

our $TMP;

sub setup {
    my (%opt) = @_;
    $TMP = tempdir(CLEANUP => 1);
    $ENV{MM_PVE_ROOT}      = "$TMP/root";
    $ENV{MM_PVE_CONFIG_DIR} = "$TMP/cfg";
    my $cfg = MMPve::Core::Config->default;
    $cfg->{restore} = {
        gateway_vmid => 9000,
        vlans => {
            120 => { gw_ip => '10.20.120.250', prefix => 24 },
            200 => { gw_ip => '10.20.200.250', prefix => 24 },
        },
        session_default_hours => 24,
        session_max_hours     => 168,
        max_sessions          => 3,
    };
    MMPve::Core::Config->save($cfg);
    return $TMP;
}

sub b64 { my ($s) = @_; my $e = encode_base64($s); $e =~ s/\n//g; return $e }

# estado capturado dos mocks
our (@payloads, @execs, @tag_sets, @calls);

# dispatcher padrão do pvesh/qga para o fluxo publish/sessions/revoke
# opções: dest_node, dest_tags, agent_ip (ou undef p/ sem agent),
#         gw_result (hash resultado), sessions (arrayref), exitcode
sub make_override {
    my (%opt) = @_;
    my $dest_node  = $opt{dest_node} // 'pve1';
    my $dest_tags  = $opt{dest_tags};
    my $gwvmid     = 9000;
    @payloads = (); @execs = (); @tag_sets = (); @calls = ();

    return sub {
        my ($argv, $stdin) = @_;
        my $cmd = join(' ', @$argv);
        push @calls, $cmd;
        # agent/exec (create) — devolve pid; a saída vem do poll exec-status
        if ($cmd =~ m{create /nodes/\S+/qemu/$gwvmid/agent/exec}) {
            my @cmds = grep { defined } map { $argv->[$_] eq '--command' ? $argv->[$_+1] : () } 0..$#$argv-1;
            push @execs, [@cmds];
            my ($input) = $cmd =~ /--input-data (\S+)/;
            push @payloads, $input if defined $input;
            return { ok => 1, rc => 0, out => encode_json({ pid => 4242 }), err => '' };
        }
        # exec-status poll
        if ($cmd =~ /exec-status/ && $cmd =~ /--pid (\d+)/) {
            state $n = 0; $n++;
            if ($opt{never_exit}) {
                return { ok => 1, rc => 0, out => encode_json({ exited => 0, pid => $1 }), err => '' };
            }
            my $out = '';
            my @c = @{ $execs[-1] // [] };
            if ($opt{exitcode}) {
                $out = $opt{gw_out} // '';
            } elsif ($c[1] && $c[1] eq 'publish') {
                $out = encode_json($opt{gw_result} // {
                    request_id => 'mock-request-id',
                    unc => '\\\\10.20.120.250\\r-abc123',
                    user => 'gwr-abc123',
                    password => 'SECRETA-xyz',
                    expires_at => '2026-10-28T10:00:00-03:00',
                });
            } elsif ($c[1] && $c[1] eq 'list') {
                $out = encode_json({
                    contract => 1,
                    sessions => $opt{sessions} // [],
                });
            } else {
                $out = $opt{gw_out} // "\x{2714} plugin ntfs3g ok\n\x{2714} PBS alcancavel\n";
            }
            my $ec = $opt{exitcode} // 0;
            return {
                ok => 1, rc => 0,
                out => encode_json({ exited => 1, pid => $1, exitcode => $ec, out => $out, err => '' }),
                err => '',
            };
        }
        # cluster/resources
        if ($cmd =~ /cluster\/resources/) {
            return { ok => 1, rc => 0, out => encode_json([
                { vmid => 100, node => $dest_node, type => 'vm' },
                { vmid => 150, node => $dest_node, type => 'vm' },
                { vmid => 9000, node => 'pvegwdon', type => 'vm' },
            ]), err => '' };
        }
        # config da VM destino
        if ($cmd =~ /qemu\/(\d+)\/config/) {
            my $vmid = $1;
            if ($cmd =~ /^pvesh set/) {
                my ($tags) = $cmd =~ /--tags (\S+)/;
                push @tag_sets, $tags;
                return { ok => 1, rc => 0, out => 'null', err => '' };
            }
            return { ok => 1, rc => 0, out => encode_json({
                vmid => $vmid,
                net0 => 'virtio=AA:BB,bridge=vmbr0',
                net1 => 'virtio=CC:DD,bridge=vmbr1,tag=120',
                tags => $dest_tags,
            }), err => '' };
        }
        # guest agent
        if ($cmd =~ /network-get-interfaces/) {
            if (exists $opt{agent_ip} && !defined $opt{agent_ip}) {
                return { ok => 0, rc => 255, out => '', err => 'agent nao rodando' };
            }
            my $ip = $opt{agent_ip} // '10.20.120.77';
            return { ok => 1, rc => 0, out => encode_json({ result => [
                { name => 'lo', 'ip-addresses' => [
                    { 'ip-address-type' => 'ipv4', 'ip-address' => '127.0.0.1' }] },
                { name => 'eth0', 'ip-addresses' => [
                    { 'ip-address-type' => 'ipv4', 'ip-address' => '192.168.77.5' },
                    { 'ip-address-type' => 'ipv4', 'ip-address' => $ip }] },
            ] }), err => '' };
        }
        return { ok => 0, rc => 42, out => '', err => "mock sem rota para: $cmd" };
    };
}

# varre arquivos sob $dir procurando $needle (binário-safe)
sub grep_files {
    my ($dir, $needle) = @_;
    my @hit;
    require File::Find;
    File::Find::find(sub {
        return unless -f $_;
        open(my $fh, '<', $_) or return;
        binmode($fh);
        local $/;
        my $data = <$fh> // '';
        close($fh);
        push @hit, $File::Find::name if index($data, $needle) >= 0;
    }, $dir);
    return @hit;
}

1;
