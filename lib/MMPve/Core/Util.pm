package MMPve::Core::Util;

use strict;
use warnings;
use Exporter qw(import);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode FB_CROAK);
use Fcntl qw(:flock);
use JSON::PP ();
use POSIX qw(strftime);
use Scalar::Util qw(looks_like_number);
use Sys::Hostname qw(hostname);

our @EXPORT_OK = qw(
    root_path log_line now_iso sha256_hex_of read_file write_file_atomic
    ensure_dir flock_ex unlock random_uuid json_encode utf8_bytes
);

our $VERSION = '@MM_PVE_VERSION@';

# Todos os caminhos de sistema passam por root_path: em teste, MM_PVE_ROOT
# desloca o prefixo. Caminhos do pmxcfs (/etc/pve/mm-tools) NÃO passam por
# aqui — usam config_dir()/journal_dir().
sub root_path {
    my ($path) = @_;
    my $root = $ENV{MM_PVE_ROOT} || '';
    return $path if $root eq '' || $path eq '';
    ($root) = $root =~ m{\A(\/[A-Za-z0-9_.+/-]+)\z};
    die "invalid MM_PVE_ROOT\n" unless defined $root;
    return "$root$path";
}

sub now_iso {
    return strftime('%Y-%m-%dT%H:%M:%S%z', localtime);
}

sub sha256_hex_of {
    my ($data) = @_;
    return sha256_hex(ref $data ? $$data : $data);
}

# Encode structured text exactly once. Values read from PVE or a subprocess
# may be UTF-8 bytes while values decoded by JSON::PP are already characters.
sub _text_tree {
    my ($value) = @_;
    return [ map { _text_tree($_) } @{$value} ] if ref($value) eq 'ARRAY';
    if (ref($value) eq 'HASH') {
        return { map { $_ => _text_tree($value->{$_}) } keys %{$value} };
    }
    return $value if ref($value) || !defined($value) || utf8::is_utf8($value);
    return $value if looks_like_number($value);
    return $value unless $value =~ /[\x80-\xFF]/;
    return decode('UTF-8', $value, FB_CROAK);
}

sub json_encode {
    my ($value, %opts) = @_;
    my $encoder = JSON::PP->new->canonical->utf8;
    $encoder = $encoder->pretty if $opts{pretty};
    $encoder = $encoder->ascii if $opts{ascii};
    return $encoder->encode(_text_tree($value));
}

sub utf8_bytes {
    my ($value) = @_;
    return encode('UTF-8', _text_tree($value));
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
    my $uuid = sprintf('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x', @bytes);
    ($uuid) = $uuid =~ /\A([0-9a-f-]+)\z/;
    return $uuid;
}

sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "could not read $path: $!\n";
    local $/;
    my $data = <$fh>;
    close($fh);
    return '' unless defined $data;
    # pvedaemon/pveproxy rodam com perl -T e todo dado lido de arquivo vem
    # contaminado. Aqui só se lê estado próprio ou do PVE (pmxcfs, /run, /var),
    # de root; contaminado, qualquer caminho montado com ele (journal → firewall)
    # faria o worker da API morrer em open/unlink.
    ($data) = $data =~ /\A(.*)\z/s;
    return $data;
}

sub write_file_atomic {
    my ($path, $data, $mode) = @_;
    $mode //= 0644;
    my $tmp = "$path.mm-tmp.$$";
    open(my $fh, '>', $tmp) or die "could not write $tmp: $!\n";
    binmode($fh);
    print {$fh} $data or die "write failed for $tmp: $!\n";
    close($fh) or die "close failed for $tmp: $!\n";
    chmod($mode, $tmp);
    rename($tmp, $path) or do { unlink($tmp); die "rename $tmp -> $path failed: $!\n" };
    return 1;
}

sub ensure_dir {
    my ($dir, $mode) = @_;
    $mode //= 0755;
    require File::Path;
    File::Path::make_path($dir, { mode => $mode, error => \my $err });
    die "could not create $dir\n" if $err && @{$err};
    return $dir;
}

# Log operacional local (nunca segredo). Ignora falha de log.
sub log_line {
    my ($msg) = @_;
    my $path = root_path('/var/log/mm-pve-tools.log');
    return unless eval { ensure_dir(root_path('/var/log')); 1 };
    return unless open(my $fh, '>>', $path);
    binmode($fh, ':raw');
    print {$fh} utf8_bytes(sprintf("[%s] %s\n", now_iso(), $msg));
    close($fh);
    return 1;
}

# flock advisory em arquivo local.
sub flock_ex {
    my ($path) = @_;
    open(my $fh, '>', $path) or die "could not open lock $path: $!\n";
    flock($fh, LOCK_EX) or die "flock $path failed: $!\n";
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
