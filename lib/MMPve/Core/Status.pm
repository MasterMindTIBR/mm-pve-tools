package MMPve::Core::Status;

# Diagnóstico do node (tela MasterMind → Diagnóstico).
# Lê só o necessário; qualquer sub-item que falhar vira {ok => 0, error},
# sem derrubar o resto.

use strict;
use warnings;
use Sys::Hostname qw(hostname);
use MMPve::Core::Apply;
use MMPve::Core::Modules;
use MMPve::Core::Runner;
use MMPve::Core::Config;
use MMPve::Core::Util qw(log_line);

our $VERSION = '@MM_PVE_VERSION@';

# ntfs3g-check: contrato JSON do meta-pacote (ver plano ntfs3g, Rock 3):
#   {"ok":true,"file_restore":{...},"restore_image":{...},"initramfs_cache_fresh":true}
sub _ntfs3g_state {
    my $res = eval {
        MMPve::Core::Runner->run(
            ['pve-file-restore-ntfs3g-check', '--json'], timeout => 60);
    };
    return { ok => 0, error => 'falha executando pve-file-restore-ntfs3g-check: ' . ($@ || '') }
        if $@ || !$res;
    return { ok => 0, error => ($res->{err} || "rc=$res->{rc}") } unless $res->{ok};
    my $data = eval { JSON::PP::decode_json($res->{out}) };
    return { ok => 0, error => 'saída inválida do pve-file-restore-ntfs3g-check: ' . ($@ || '') }
        if $@ || !$data;
    return $data;
}

sub collect {
    my ($class, %opts) = @_;
    my %s;

    $s{node} = hostname() // 'unknown';

    my $v = MMPve::Core::Runner->run(
        ['dpkg-query', '-W', '-f=${Version}', 'mm-pve-tools'], timeout => 30);
    $s{package_version} = $v->{ok} ? ($v->{out} // '') =~ s/\s+//gr : 'unknown';

    my $pv = MMPve::Core::Runner->run(
        ['pvesh', 'get', '/version', '--output-format', 'json'], timeout => 60);
    if ($pv->{ok}) {
        my $j = eval { JSON::PP::decode_json($pv->{out}) };
        $s{pve_version} = $j ? ($j->{version} // ($j->{release} // '')) : '';
    } else {
        $s{pve_version} = '';
    }

    $s{applied} = eval { MMPve::Core::Apply->status };
    $s{applied} = { state => 'error', error => $@ } if $@;

    $s{ntfs3g} = $opts{skip_ntfs3g} ? { ok => undef, skipped => 1 } : $class->_ntfs3g_state;

    my %mods;
    my $cfg = $opts{config} // MMPve::Core::Config->load;
    for my $m (MMPve::Core::Modules->all) {
        $mods{ $m->name } = { check => eval { $m->check($cfg) } || { ok => 0, error => $@ } };
    }
    $s{modules} = \%mods;
    $s{branding} = $mods{branding}{check} if $mods{branding};

    return \%s;
}

1;
