package MMPve::Core::Patch;

# Patch mínimo no pve-manager (duas inserções, marcadas com "# mm-pve-tools"),
# conforme plano D5: se a âncora não existir, NADA muda (GUI original); se o
# arquivo alterado não compilar, restaura backup; restart só se mudou; depois
# do restart confere systemctl is-active + pvesh get /version e reverte se
# algo falhar. Nunca deixa pveproxy/pvedaemon parados.

use strict;
use warnings;
use File::Copy qw(copy);
use MMPve::Core::Runner;
use MMPve::Core::Util qw(root_path read_file write_file_atomic ensure_dir log_line now_iso);

our $VERSION = '0.1.0';

my %TARGETS = (
    index_tpl => {
        path   => '/usr/share/pve-manager/index.html.tpl',
        anchor => qr{/pve2/js/pvemanagerlib\.js\?ver=\[% version %\]},
        insert => '<!-- mm-pve-tools --><script type="text/javascript" src="/pve2/js/mm-tools.js?ver=[% version %]"></script>',
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
sub _pve_manager_version {
    my ($class) = @_;
    my $res = MMPve::Core::Runner->run(
        ['dpkg-query', '-W', '-f=${Version}', 'pve-manager'], timeout => 15);
    return undef unless $res->{ok};
    my $version = $res->{out} // '';
    $version =~ s/\s+\z//;
    return length($version) ? $version : undef;
}

sub _version_cache_path {
    return root_path('/var/lib/mm-pve-tools/pve-manager.version');
}

sub _cached_version {
    my ($class) = @_;
    return eval { read_file($class->_version_cache_path) } // undef;
}

sub _write_version_cache {
    my ($class, $version) = @_;
    return unless defined $version;
    ensure_dir(root_path('/var/lib/mm-pve-tools'));
    write_file_atomic($class->_version_cache_path, "$version\n", 0644);
}


# ---------------------------------------------------------------- apply

# opts: syntax_check => auto|always|never ; no_restart => 1
sub apply {
    my ($class, %opts) = @_;
    my %paths = $class->_target_paths;
    my %out;
    my $any_changed = 0;
    my $version = $class->_pve_manager_version;
    my $cached = $class->_cached_version;
    $cached =~ s/\s+\z// if defined $cached;

    for my $k (sort keys %paths) {
        my $status = $class->check->{$k}{status};
        if ($status eq 'applied' && defined($version) && defined($cached) && $cached eq $version) {
            $out{$k} = { status => 'version_current', changed => 0 };
            next;
        }
        $out{$k} = $class->_apply_one($k, $paths{$k}, \%opts, \$any_changed);
    }

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
    $class->_write_version_cache($version) if $res->{ok};
    log_line('patch apply: ok=' . $res->{ok} . ' changed=' . $res->{changed} . ' '
        . join(' ', map { "$_=" . $out{$_}{status} } sort keys %out));
    return $res;
}

sub _apply_one {
    my ($class, $k, $path, $opts, $changed_ref) = @_;

    my $lines = _read_lines($path);
    if (!$lines) {
        return { status => 'file_missing', note => 'arquivo ausente; nada feito' };
    }

    my (@new, $inserted);
    if ($k eq 'index_tpl') {
        return { status => 'applied', changed => 0 }
            if grep { /mm-pve-tools|mm-tools\.js/ } @{$lines};
        my $anchor_seen = 0;
        for my $l (@{$lines}) {
            push @new, $l;
            if ($l =~ $TARGETS{index_tpl}{anchor}) {
                $anchor_seen = 1;
                push @new, $TARGETS{index_tpl}{insert} . "\n";
            }
        }
        if (!$anchor_seen) {
            return {
                status => 'anchor_missing',
                note => 'âncora (pvemanagerlib.js) não encontrada; GUI fica original',
            };
        }
        $inserted = 1;
    } else {
        my $r = $class->_patch_nodes_pm($lines);
        return $r unless ($r->{status} // '') eq 'inserted';
        @new = @{ $r->{lines} };
        $inserted = 1;
    }

    # backup
    my $bakdir = root_path('/var/lib/mm-pve-tools/patch-backups');
    ensure_dir($bakdir);
    my $bak = $bakdir . '/' . ($k eq 'index_tpl' ? 'index.html.tpl' : 'Nodes.pm') . '.' . now_iso();
    $bak =~ s/[:+]//g;
    copy($path, $bak) or return { status => 'failed', error => "backup: $!" };

    # grava
    my $new_raw = join('', @new);
    eval { write_file_atomic($path, $new_raw); 1 }
        or return { status => 'failed', error => "gravação: $@" };

    # verificação perl -c no Nodes.pm (auto: só se o ambiente PVE existir)
    if ($k eq 'nodes_pm' && $class->_syntax_check_mode($opts) ne 'never') {
        my $can = $class->_perl_c($path);
        if (!$can->{ok}) {
            copy($bak, $path);
            my $msg = 'perl -c falhou; backup restaurado: ' . ($can->{err} // '');
            log_line("patch nodes_pm: $msg");
            return { status => 'syntax_failed', error => $msg, restored => 1 };
        }
    }

    ${$changed_ref} = 1;
    return { status => 'applied', changed => 1, backup => $bak };
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
    my $restart = MMPve::Core::Runner->run(
        ['systemd-run', '--wait', '--collect', '--unit=mm-pve-patch-reload',
         'systemctl', 'reload-or-restart', 'pveproxy.service', 'pvedaemon.service'],
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
        my $rev = $class->revert(force => 1);
        $v->{reverted} = $rev->{changed};
        $v->{ok} = 0;
    }
    return $v;
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
