package MMPve::Core::Util;

use strict;
use warnings;
use Exporter qw(import);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock);
use POSIX qw(strftime);
use Sys::Hostname qw(hostname);

our @EXPORT_OK = qw(
    root_path log_line now_iso sha256_hex_of read_file write_file_atomic
    ensure_dir flock_ex unlock random_uuid
);

our $VERSION = '@MM_PVE_VERSION@';

# Todos os caminhos de sistema passam por root_path: em teste, MM_PVE_ROOT
# desloca o prefixo. Caminhos do pmxcfs (/etc/pve/mm-tools) NÃO passam por
# aqui — usam config_dir()/journal_dir().
sub root_path {
    my ($path) = @_;
    my $root = $ENV{MM_PVE_ROOT} || '';
    return $path if $root eq '' || $path eq '';
    return "$root$path";
}

sub now_iso {
    return strftime('%Y-%m-%dT%H:%M:%S%z', localtime);
}

sub sha256_hex_of {
    my ($data) = @_;
    return sha256_hex(ref $data ? $$data : $data);
}

sub random_uuid {
    my $raw = '';
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        my $read = read($fh, $raw, 16);
        close($fh);
        $raw = '' if !defined($read) || $read != 16;
    }
    $raw = pack('H*', sha256_hex(join(':', $$, time, rand(), {}))) if length($raw) != 16;
    my @bytes = unpack('C16', $raw);
    $bytes[6] = ($bytes[6] & 0x0f) | 0x40;
    $bytes[8] = ($bytes[8] & 0x3f) | 0x80;
    return sprintf('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x', @bytes);
}

sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "não consegui ler $path: $!\n";
    local $/;
    my $data = <$fh>;
    close($fh);
    return defined $data ? $data : '';
}

sub write_file_atomic {
    my ($path, $data, $mode) = @_;
    $mode //= 0644;
    my $tmp = "$path.mm-tmp.$$";
    open(my $fh, '>', $tmp) or die "não consegui gravar $tmp: $!\n";
    binmode($fh);
    print {$fh} $data or die "erro gravando $tmp: $!\n";
    close($fh) or die "erro fechando $tmp: $!\n";
    chmod($mode, $tmp);
    rename($tmp, $path) or do { unlink($tmp); die "rename $tmp -> $path: $!\n" };
    return 1;
}

sub ensure_dir {
    my ($dir, $mode) = @_;
    $mode //= 0755;
    require File::Path;
    File::Path::make_path($dir, { mode => $mode, error => \my $err });
    die "não consegui criar $dir\n" if $err && @{$err};
    return $dir;
}

# Log operacional local (nunca segredo). Ignora falha de log.
sub log_line {
    my ($msg) = @_;
    my $path = root_path('/var/log/mm-pve-tools.log');
    return unless eval { ensure_dir(root_path('/var/log')); 1 };
    return unless open(my $fh, '>>', $path);
    print {$fh} sprintf("[%s] %s\n", now_iso(), $msg);
    close($fh);
    return 1;
}

# flock advisory em arquivo local.
sub flock_ex {
    my ($path) = @_;
    open(my $fh, '>', $path) or die "não consegui abrir lock $path: $!\n";
    flock($fh, LOCK_EX) or die "flock $path: $!\n";
    return $fh;    # manter referência até unlock
}

sub unlock {
    my ($fh) = @_;
    return unless $fh;
    flock($fh, LOCK_UN) if $fh;
    close($fh);
    return;
}

1;

__END__

=head1 NAME

MMPve::Core::Util - auxiliares do mm-pve-tools (caminhos, log, arquivos)

=head1 SEE ALSO

AGENTS.md do repositório; plano mm-pve-tools, seção "Núcleo".
