package MMPve::Core::Runner;

# Única porta de saída para comandos externos (pvesh, qm, systemctl, ...).
# Testes sobrescrevem $MMPve::Core::Runner::OVERRIDE (ver AGENTS.md):
#   local $MMPve::Core::Runner::OVERRIDE = sub {
#       my ($argv, $stdin) = @_;
#       return { ok => 1, rc => 0, out => '...', err => '' };
#   };

use strict;
use warnings;
use IPC::Open3 qw(open3);
use IO::Select;
use Symbol qw(gensym);
use JSON::PP qw(decode_json);

our $VERSION = '@MM_PVE_VERSION@';

our $OVERRIDE;

sub run {
    my ($class, $argv, %opts) = @_;
    die "argv precisa ser arrayref\n" unless ref $argv eq 'ARRAY';
    die "comando vazio\n" unless @{$argv};

    if ($OVERRIDE) {
        my $res = $OVERRIDE->($argv, $opts{stdin});
        die "OVERRIDE retornou valor inválido\n" unless ref $res eq 'HASH';
        $res->{ok} = (($res->{rc} // 1) == 0) ? 1 : 0;
        $res->{$_} //= '' for qw(out err);
        return $res;
    }

    my $timeout = $opts{timeout} // 300;
    my ($out, $err) = ('', '');
    my ($infh, $outfh, $errfh);
    $errfh = gensym;
    my $pid = eval { open3($infh, $outfh, $errfh, @{$argv}) };
    if (!$pid) {
        return {
            ok => 0, rc => 127, out => '', err => '',
            error => "não consegui executar '$argv->[0]': $@",
        };
    }
    local $SIG{ALRM} = sub { die "timeout\n" };
    my $died;
    eval {
        alarm($timeout);
        if (defined $opts{stdin}) {
            print {$infh} $opts{stdin};
        }
        close($infh);
        my $ready = IO::Select->new($outfh, $errfh);
        while ($ready->count) {
            for my $fh ($ready->can_read) {
                my $chunk = '';
                my $read = sysread($fh, $chunk, 8192);
                if (!defined($read) || $read == 0) {
                    $ready->remove($fh);
                    close($fh);
                    next;
                }
                if ($fh == $outfh) { $out .= $chunk }
                else               { $err .= $chunk }
            }
        }
        alarm(0);
        1;
    } or do { $died = 1 };
    if ($died) {
        kill('TERM', $pid);
        my $i = 0;
        while (kill(0, $pid) && $i++ < 20) { select(undef, undef, undef, 0.1) }
        kill('KILL', $pid) if kill(0, $pid);
        close($outfh);
        close($errfh);
        waitpid($pid, 0);
        my $emsg = $@ // 'erro desconhecido';
        chomp $emsg;
        return {
            ok => 0, rc => -1, out => $out, err => $err,
            timeout => 1, error => "timeout/erro executando @$argv: $emsg",
        };
    }
    my $rc = waitpid($pid, 0) ? $? >> 8 : -1;
    return { ok => ($rc == 0 ? 1 : 0), rc => $rc, out => $out, err => $err };
}

# die em falha; retorna estrutura decodificada ('null' → undef)
sub run_json {
    my ($class, @args) = @_;
    my $res = $class->run(@args);
    die join(' ', @{ $args[0] }) . ': '
        . ($res->{error} || $res->{err} || "rc=$res->{rc}") . "\n"
        unless $res->{ok};
    my $out = $res->{out};
    return undef if !defined $out || $out =~ /^\s*$/ || $out =~ /^\s*null\s*$/;
    return decode_json($out);
}

sub extract_upid {
    my ($class, $output) = @_;
    for my $line (reverse split /\n/, $output // '') {
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;
        my $value = eval { decode_json($line) };
        return $value if !$@ && defined($value) && !ref($value) && $value =~ /^UPID:/;
        return $1 if $line =~ /^"?(UPID:[^"\r\n]+)"?,?$/;
    }
    die "saída do pvesh não contém UPID\n";
}

sub pvesh_task {
    my ($class, $method, $path, %args) = @_;
    my $timeout = delete $args{__timeout} // 300;
    my @cmd = ('pvesh', $method, $path, '--output-format', 'json');
    for my $k (sort keys %args) {
        push @cmd, "--$k";
        push @cmd, $args{$k} if defined $args{$k};
    }
    my $res = $class->run(\@cmd, timeout => $timeout);
    die join(' ', @cmd) . ': ' . ($res->{error} || $res->{err} || "rc=$res->{rc}") . "\n"
        unless $res->{ok};
    return $class->extract_upid($res->{out});
}

# pvesh <method> <path> [args] --output-format json
# args com __timeout controlam o timeout; o resto vira --chave valor.
sub pvesh {
    my ($class, $method, $path, %args) = @_;
    my $timeout = delete $args{__timeout} // 300;
    my @cmd = ('pvesh', $method, $path, '--output-format', 'json');
    for my $k (sort keys %args) {
        my $v = $args{$k};
        push @cmd, "--$k";
        push @cmd, $v if defined $v;
    }
    return $class->run_json(\@cmd, timeout => $timeout);
}

1;
