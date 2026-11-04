package MMPve::Core::Patch;

# Patch mínimo no pve-manager (duas inserções, marcadas com "# mm-pve-tools"),
# conforme plano D5: se a âncora não existir, NADA muda (GUI original); se o
# arquivo alterado não compilar, restaura backup; restart só se mudou; depois
# do restart confere systemctl is-active + pvesh get /version e reverte se
# algo falhar. Nunca deixa pveproxy/pvedaemon parados.

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Copy qw(copy);
use JSON::PP qw(decode_json encode_json);
use MMPve::Core::Runner;
use MMPve::Core::Util qw(root_path read_file write_file_atomic ensure_dir log_line random_uuid);

our $VERSION = '@MM_PVE_VERSION@';

my %TARGETS = (
    index_tpl => {
        path   => '/usr/share/pve-manager/index.html.tpl',
        anchor => qr{/pve2/js/pvemanagerlib\.js\?ver=\[% version %\]},
    },
    nodes_pm => {
        path => '/usr/share/perl5/PVE/API2/Nodes.pm',
    },
);

sub targets { return \%TARGETS }

sub _target_paths {
    my ($class) = @_;
    return (
        index_tpl => root_path('/usr/share/pve-manager/index.html.tpl'),
        nodes_pm  => root_path('/usr/share/perl5/PVE/API2/Nodes.pm'),
    );
}

sub _patch_state_path { return root_path('/var/lib/mm-pve-tools/patch-state.json') }

sub _patch_state {
    my $raw = eval { read_file(_patch_state_path()) };
    return {} if $@ || !defined $raw || $raw eq '';
    return eval { decode_json($raw) } || {};
}

sub _save_patch_state {
    my ($class, $state) = @_;
    ensure_dir(root_path('/var/lib/mm-pve-tools'));
    write_file_atomic(_patch_state_path(), encode_json($state) . "\n", 0644);
}

# ---------------------------------------------------------------- check

sub _read_lines {
    my ($path) = @_;
    my $raw = eval { read_file($path) };
    return undef if $@ || !defined $raw;
    return [ split(/^/, $raw) ];
}

sub check {
    my ($class) = @_;
    my %paths = $class->_target_paths;
    my %res;
    for my $k (sort keys %paths) {
        my $lines = _read_lines($paths{$k});
        if (!$lines) {
            $res{$k} = { status => 'file_missing' };
            next;
        }
        my $has_marker = grep { /mm-pve-tools|PVE::API2::MMTools|mm-tools\.js/ } @{$lines};
        if ($k eq 'index_tpl') {
            my $has_anchor = grep { $_ =~ $TARGETS{index_tpl}{anchor} } @{$lines};
            $res{$k} = {
                status => $has_marker ? 'applied'
                : ($has_anchor ? 'not_applied' : 'anchor_missing'),
            };
        } else {
            # âncoras iguais às do apply: use PVE::API2::* + subclass Replication
            my ($has_use, $has_rep) = (0, 0);
            for my $l (@{$lines}) {
                $has_use = 1 if $l =~ /^\s*use\s+PVE::API2::\w+(?:::\w+)*;/;
                $has_rep = 1 if $l =~ /subclass\s*=>\s*"PVE::API2::Replication"/;
            }
            $res{$k} = {
                status => $has_marker ? 'applied'
                    : (($has_use && $has_rep) ? 'not_applied' : 'anchor_missing'),
            };
        }
    }
    return \%res;
}
# ---------------------------------------------------------------- apply

# opts: syntax_check => auto|always|never ; no_restart => 1
sub apply {
    my ($class, %opts) = @_;
    my %paths = $class->_target_paths;
    my %out;
    my %raw;
    my %desired;
    my %backup;
    my @changed;
    my $state = _patch_state();

    # Prepare and validate BOTH files before touching either upstream file.
    # An already-patched file is only retried when its desired content differs
    # (for example, a new mm-pve-tools version changes ?ver=).
    for my $k (sort keys %paths) {
        my $raw = eval { read_file($paths{$k}) };
        if ($@) {
            $out{$k} = { status => 'file_missing', error => "$@" };
            next;
        }
        $raw{$k} = $raw;
        my $source_hash = sha256_hex($raw);
        if ($state->{$k} && ($state->{$k}{source_hash} // '') eq $source_hash) {
            $out{$k} = {
                status => 'previous_failure',
                note => 'mesmo upstream já falhou; aguarda mudança do arquivo PVE',
                error => $state->{$k}{error},
            };
            next;
        }
        my $want = $class->_desired_content($k, $raw);
        if (!$want->{ok}) {
            $out{$k} = { status => $want->{status}, note => $want->{note} };
            next;
        }
        $desired{$k} = $want->{content};
        if ($desired{$k} eq $raw) {
            $out{$k} = { status => 'version_current', changed => 0 };
            delete $state->{$k};
            next;
        }
        push @changed, $k;
    }

    # An anchor failure is deliberately sticky in practice: this call has no
    # side effect, so timer/trigger retries cannot partially patch the GUI.
    # A later pve-manager update changes the file and makes the anchor eligible
    # again.
    if (grep { ($out{$_}{status} // '') eq 'anchor_missing' } keys %out) {
        for my $k (keys %out) {
            next unless ($out{$k}{status} // '') eq 'anchor_missing';
            $state->{$k} = { source_hash => sha256_hex($raw{$k}), error => $out{$k}{note} };
        }
        eval { $class->_save_patch_state($state); 1 };
        return {
            ok => 0, changed => 0, targets => \%out,
            error => 'patch não aplicado: âncora upstream ausente',
        };
    }
    if (grep { ($out{$_}{status} // '') eq 'file_missing' } keys %out) {
        return { ok => 0, changed => 0, targets => \%out };
    }
    if (grep { ($out{$_}{status} // '') eq 'previous_failure' } keys %out) {
        return {
            ok => 0, changed => 0, targets => \%out,
            error => 'patch não repetido até mudança do upstream',
        };
    }

    # One backup is kept for each pristine upstream content hash.  Updating
    # only the package cache-buster reuses the existing upstream backup.
    for my $k (@changed) {
        my $bak = $class->_backup_for($k, $raw{$k}, 1);
        if (!$bak) {
            $out{$k} = { status => 'failed', error => "backup: $!" };
            return { ok => 0, changed => 0, targets => \%out };
        }
        $backup{$k} = $bak;
    }

    my %staged;
    my $transaction_error;
    eval {
        for my $k (@changed) {
            my $stage = $paths{$k} . ".mm-stage-$$-" . random_uuid();
            $staged{$k} = $stage;
            write_file_atomic($stage, $desired{$k}, 0644);
        }
        for my $k (@changed) {
            my $valid = $class->_validate_staged($k, $staged{$k}, \%opts);
            die "$k: $valid->{error}\n" unless $valid->{ok};
        }
        for my $k (@changed) {
            rename($staged{$k}, $paths{$k})
                or die "rename do stage para $paths{$k}: $!\n";
        }
        for my $k (@changed) {
            my $after = read_file($paths{$k});
            die "$k: verificação pós-commit falhou\n" unless $after eq $desired{$k};
        }
        1;
    } or do {
        $transaction_error = $@ || 'falha desconhecida na transação';
    };

    if ($transaction_error) {
        unlink($_) for values %staged;
        my @rollback_errors;
        for my $k (@changed) {
            push @rollback_errors, "$k: $!" unless copy($backup{$k}, $paths{$k});
        }
        my $error = $transaction_error;
        $error .= ' rollback: ' . join('; ', @rollback_errors) if @rollback_errors;
        $out{$_} = {
            status => 'failed', error => $error, restored => @rollback_errors ? 0 : 1,
        } for @changed;
        log_line('patch apply: transação revertida: ' . $error);
        $state->{$_} = { source_hash => sha256_hex($raw{$_}), error => $error } for @changed;
        eval { $class->_save_patch_state($state); 1 };
        return { ok => 0, changed => 0, targets => \%out, error => $error };
    }

    my $any_changed = scalar @changed ? 1 : 0;
    for my $k (@changed) {
        $out{$k} = { status => 'applied', changed => 1, backup => $backup{$k} };
        delete $state->{$k};
    }
    eval { $class->_save_patch_state($state); 1 };

    my $restart;
    if ($any_changed && !$opts{no_restart}) {
        $restart = $class->_restart_and_verify();
    }

    my $ok = 1;
    for my $k (sort keys %out) { $ok = 0 if $out{$k}{status} eq 'failed' }
    my $res = {
        ok => ($ok && (!$restart || $restart->{ok})) ? 1 : 0,
        changed => $any_changed,
        targets => \%out,
        ($restart ? (restart => $restart) : ()),
    };
    log_line('patch apply: ok=' . $res->{ok} . ' changed=' . $res->{changed} . ' '
        . join(' ', map { "$_=" . $out{$_}{status} } sort keys %out));
    return $res;
}

sub _index_insert {
    return '<!-- mm-pve-tools --><script type="text/javascript" src="/pve2/js/mm-tools.js?ver='
        . $VERSION . '"></script>';
}

sub _desired_content {
    my ($class, $k, $raw) = @_;
    my @lines = split(/^/, $raw);
    if ($k eq 'index_tpl') {
        my $insert = _index_insert();
        my $found = 0;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /mm-tools\.js/) {
                $lines[$i] = $insert . "\n";
                $found = 1;
                last;
            }
        }
        if (!$found) {
            my @new;
            for my $line (@lines) {
                push @new, $line;
                push @new, $insert . "\n" if $line =~ $TARGETS{index_tpl}{anchor};
            }
            return {
                ok => 0, status => 'anchor_missing',
                note => 'âncora (pvemanagerlib.js) não encontrada; GUI fica original',
            } if @new == @lines;
            @lines = @new;
        }
        return { ok => 1, content => join('', @lines) };
    }

    return { ok => 1, content => $raw } if grep { /PVE::API2::MMTools/ } @lines;
    my $r = $class->_patch_nodes_pm(\@lines);
    return { ok => 0, status => $r->{status}, note => $r->{note} } unless $r->{status} eq 'inserted';
    return { ok => 1, content => join('', @{ $r->{lines} }) };
}

sub _backup_for {
    my ($class, $k, $raw, $create) = @_;
    my $dir = root_path('/var/lib/mm-pve-tools/patch-backups');
    ensure_dir($dir);
    my $name = $k eq 'index_tpl' ? 'index.html.tpl' : 'Nodes.pm';
    # A version-only rewrite of the mm-tools script must reuse the upstream
    # backup, not create a backup of an already patched file.
    if ($raw =~ /mm-pve-tools|mm-tools\.js/) {
        if (opendir(my $dh, $dir)) {
            my @found = sort grep { /^\Q$name\E\.[0-9a-f]{64}$/ } readdir($dh);
            closedir($dh);
            return "$dir/$found[0]" if @found;
        }
    }
    my $bak = "$dir/$name." . sha256_hex($raw);
    return $bak if -f $bak;
    my %paths = $class->_target_paths;
    return undef unless $create && copy($paths{$k}, $bak);
    return $bak;
}

sub _validate_staged {
    my ($class, $k, $path, $opts) = @_;
    my $raw = eval { read_file($path) };
    return { ok => 0, error => "não consegui ler stage: $@" } if $@;
    return { ok => 0, error => 'stage sem script mm-tools.js' }
        if $k eq 'index_tpl' && $raw !~ /mm-tools\.js\?ver=\Q$VERSION\E/;
    if ($k eq 'nodes_pm' && $class->_syntax_check_mode($opts) ne 'never') {
        my $can = $class->_perl_c($path);
        return { ok => 0, error => ($can->{err} // "rc=$can->{rc}") } unless $can->{ok};
    }
    return { ok => 1 };
}

# Insere no Nodes.pm (package PVE::API2::Nodes::Nodeinfo):
#   use PVE::API2::MMTools; # mm-pve-tools   → após o último "use PVE::API2::*;"
#   __PACKAGE__->register_method({ subclass => "PVE::API2::MMTools", path => 'mm-tools' }); # mm-pve-tools
#                                                → após o bloco subclass Replication
sub _patch_nodes_pm {
    my ($class, $lines) = @_;

    return { status => 'applied', changed => 0 }
        if grep { /PVE::API2::MMTools/ } @{$lines};

    my @uses = grep { $lines->[$_] =~ /^\s*use\s+PVE::API2::\w+(?:::\w+)*;/ } 0 .. $#{$lines};
    my $last_use = pop @uses;
    return { status => 'anchor_missing', note => 'âncora use PVE::API2::* ausente no Nodes.pm' }
        unless defined $last_use;

    my ($rep_line) = grep { $lines->[$_] =~ /subclass\s*=>\s*"PVE::API2::Replication"/ } 0 .. $#{$lines};
    my $close_after;
    if (defined $rep_line) {
        ($close_after) = grep {
            $lines->[$_] =~ /^\s*\}\);\s*$/
            && $_ >= $rep_line
        } $rep_line .. $#{$lines};
    }
    return { status => 'anchor_missing', note => 'âncora subclass Replication ausente no Nodes.pm' }
        unless defined $close_after;

    my @new;
    for my $i (0 .. $#{$lines}) {
        push @new, $lines->[$i];
        if ($i == $close_after) {
            push @new,
                q{__PACKAGE__->register_method({ subclass => "PVE::API2::MMTools", path => 'mm-tools' }); # mm-pve-tools} . "\n";
        }
        if ($i == $last_use) {
            push @new, 'use PVE::API2::MMTools; # mm-pve-tools' . "\n";
        }
    }
    return { status => 'inserted', inserted => 1, lines => \@new };
}

sub _syntax_check_mode {
    my ($class, $opts) = @_;
    my $m = $opts->{syntax_check} || 'auto';
    return $m if $m ne 'auto';
    # auto: só roda perl -c se o ambiente PVE existir (CI usa fixtures sem PVE)
    our $_can_syntax;
    $_can_syntax //= MMPve::Core::Runner->run(['perl', '-MPVE::RESTHandler', '-e1'], timeout => 15)->{ok} ? 'always' : 'never';
    return $_can_syntax;
}

sub _perl_c {
    my ($class, $path) = @_;
    return MMPve::Core::Runner->run(['perl', '-c', $path], timeout => 120);
}

sub _restart_and_verify {
    my ($class) = @_;
    my $unit = 'mm-pve-patch-reload-' . substr(random_uuid(), 0, 12);
    my $restart = MMPve::Core::Runner->run(
        ['systemd-run', '--wait', '--collect', "--unit=$unit",
         'systemctl', 'reload', 'pveproxy.service', 'pvedaemon.service'],
        timeout => 120);
    my $v = { restart_rc => $restart->{rc}, ok => 0 };
    for my $svc (qw(pveproxy pvedaemon)) {
        my $a = MMPve::Core::Runner->run(['systemctl', 'is-active', "$svc.service"], timeout => 30);
        $v->{"active_$svc"} = ($a->{out} // '') =~ /active/ ? 1 : 0;
    }
    my $ver = MMPve::Core::Runner->run(
        ['pvesh', 'get', '/version', '--output-format', 'json'], timeout => 60);
    $v->{pve_version_ok} = $ver->{ok} ? 1 : 0;
    $v->{ok} = ($v->{active_pveproxy} && $v->{active_pvedaemon} && $ver->{ok}) ? 1 : 0;

    if (!$v->{ok}) {
        log_line('patch: pós-restart falhou (' . ($ver->{err} // 'rc=' . $ver->{rc}) . '); revertendo');
        my $rev = $class->revert(force => 1, no_restart => 1);
        $v->{reverted} = $rev->{changed};
        $v->{ok} = 0;
    }
    return $v;
}

sub reload_services {
    my ($class) = @_;
    return $class->_restart_and_verify();
}

# ---------------------------------------------------------------- revert

sub revert {
    my ($class, %opts) = @_;
    my %paths = $class->_target_paths;
    my $any_changed = 0;
    my %out;
    for my $k (sort keys %paths) {
        my $lines = _read_lines($paths{$k});
        if (!$lines) { $out{$k} = { status => 'file_missing' }; next }
        my @kept = grep {
               !($_ =~ /use PVE::API2::MMTools;/ && $_ =~ /mm-pve-tools/)
            && !($_ =~ /subclass => "PVE::API2::MMTools"/ && $_ =~ /mm-pve-tools/)
            && $_ !~ /<!-- mm-pve-tools -->/
            && $_ !~ m{^\s*<script[^>]*src="/pve2/js/mm-tools\.js[^"]*"></script>\s*$}
        } @{$lines};
        my $changed = scalar(@kept) != scalar(@{$lines}) ? 1 : 0;
        if ($changed) {
            eval { write_file_atomic($paths{$k}, join('', @kept)); 1 }
                or do { $out{$k} = { status => 'failed', error => $@ }; next };
        }
        $out{$k} = { status => 'reverted', changed => $changed };
        $any_changed = 1 if $changed;
    }
    my $restart;
    if ($any_changed && !$opts{no_restart}) {
        $restart = $class->_restart_and_verify();
    }
    log_line('patch revert: changed=' . ($any_changed ? 1 : 0));
    return { changed => $any_changed, targets => \%out, ($restart ? (restart => $restart) : ()) };
}

1;
