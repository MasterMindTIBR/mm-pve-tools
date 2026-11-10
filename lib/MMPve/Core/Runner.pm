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
use MMPve::Core::Util qw(log_line);

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
    # pvedaemon/pveproxy rodam com perl -T: argumento vindo da requisição ou
    # da config está contaminado e o exec morre ("Insecure dependency"). A
    # execução é por lista, sem shell, então cada argumento chega literal.
    my @argv = map { (defined $_ && /\A(.*)\z/s) ? $1 : $_ } @{$argv};
    my $pid = eval { open3($infh, $outfh, $errfh, @argv) };
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

sub run_stream {
    my ($class, $argv, %opts) = @_;
    die "argv precisa ser arrayref\n" unless ref $argv eq 'ARRAY';
    die "comando vazio\n" unless @{$argv};

    if ($OVERRIDE) {
        my $res = $OVERRIDE->($argv, $opts{stdin});
        die "OVERRIDE retornou valor inválido\n" unless ref $res eq 'HASH';
        $res->{ok} = (($res->{rc} // 1) == 0) ? 1 : 0;
        $res->{$_} //= '' for qw(out err);
        $opts{on_output}->($res->{out}, 'stdout') if $opts{on_output} && length $res->{out};
        $opts{on_output}->($res->{err}, 'stderr') if $opts{on_output} && length $res->{err};
        return $res;
    }

    my $timeout = $opts{timeout};
    my ($out, $err) = ('', '');
    my ($infh, $outfh, $errfh);
    $errfh = gensym;
    my @argv = map { (defined $_ && /\A(.*)\z/s) ? $1 : $_ } @{$argv};
    my $pid = eval { open3($infh, $outfh, $errfh, @argv) };
    if (!$pid) {
        return { ok => 0, rc => 127, out => '', err => '',
            error => "não consegui executar '$argv->[0]': $@" };
    }
    local $SIG{ALRM} = sub { die "timeout\n" };
    my $died;
    eval {
        alarm($timeout) if defined $timeout;
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
                if ($fh == $outfh) {
                    $out .= $chunk;
                    $opts{on_output}->($chunk, 'stdout') if $opts{on_output};
                } else {
                    $err .= $chunk;
                    $opts{on_output}->($chunk, 'stderr') if $opts{on_output};
                }
            }
        }
        alarm(0) if defined $timeout;
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
        return { ok => 0, rc => -1, out => $out, err => $err,
            timeout => 1, error => "timeout/erro executando @$argv: $emsg" };
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

# Token UPID até espaço, aspas ou barra invertida (o \" da string JSON do
# proxy); não exige o formato hexadecimal para aceitar o que o PVE devolver.
my $UPID_RE = qr/UPID:[^\s"\\]+/;

sub extract_upid {
    my ($class, $output) = @_;
    for my $line (reverse split /\n/, $output // '') {
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;
        # Para outro node o pvesh faz proxy e devolve a saída inteira do worker
        # remoto numa única string JSON, sem quebras de linha, com a UPID no
        # fim ("job ... agendado\"UPID:node:...\""). Vale a última UPID da linha.
        my $value = eval { decode_json($line) };
        my @texts = (!$@ && defined($value) && !ref($value)) ? ($value, $line) : ($line);
        for my $text (@texts) {
            my @all = $text =~ /($UPID_RE)/g;
            return $all[-1] if @all;
        }
    }
    die "saída do pvesh não contém UPID\n";
}

sub _last_json_line {
    my ($class, $output) = @_;
    for my $line (reverse split /\n/, $output // '') {
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;
        my $value = eval { decode_json($line) };
        return ($value, $line) unless $@;
    }
    return (undef, undef);
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
    my $res = $class->run(\@cmd, timeout => $timeout);
    die join(' ', @cmd) . ': ' . ($res->{error} || $res->{err} || "rc=$res->{rc}") . "\n"
        unless $res->{ok};
    my ($value, $json_line) = $class->_last_json_line($res->{out});
    return $value if defined $json_line;

    if ($method =~ /^(?:create|set|delete)$/) {
        my $task_text = $res->{out} // '';
        $task_text =~ s/\s+/ /g;
        $task_text =~ s/^\s+|\s+$//g;
        log_line("pvesh $method $path: $task_text") if length $task_text;
        return undef;
    }
    die join(' ', @cmd) . ": saída não contém JSON\n";
}

1;
