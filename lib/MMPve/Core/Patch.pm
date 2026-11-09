package MMPve::Core::Patch;

# Motor transacional dos patches do mm-pve-tools. O grupo __core__ mantém os
# dois patches históricos do pve-manager; módulos podem registrar manifestos
# de uma linha para outros pacotes PVE sem que o núcleo conheça seus hooks.
# Cada grupo é aplicado/revertido isoladamente e só recarrega os processos que
# declarou. Falha de reload restaura apenas o grupo que falhou e verifica o
# reload de recuperação antes de devolver o erro.

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Copy qw(copy);
use JSON::PP qw(decode_json encode_json);
use MMPve::Core::Runner;
use MMPve::Core::Util qw(root_path read_file write_file_atomic ensure_dir log_line random_uuid);

our $VERSION = '@MM_PVE_VERSION@';

my $CORE = '__core__';
my %TARGETS = (
    index_tpl => {
        id       => 'index_tpl',
        module   => $CORE,
        owner    => 'pve-manager',
        package  => 'pve-manager',
        kind     => 'index_tpl',
        backup_name => 'index.html.tpl',
        path     => '/usr/share/pve-manager/index.html.tpl',
        anchor   => qr{/pve2/js/pvemanagerlib\.js\?ver=\[% version %\]},
        daemons  => [qw(pveproxy pvedaemon)],
        processes => [qw(pveproxy pvedaemon)],
    },
    nodes_pm => {
        id       => 'nodes_pm',
        module   => $CORE,
        owner    => 'pve-manager',
        package  => 'pve-manager',
        kind     => 'nodes_pm',
        backup_name => 'Nodes.pm',
        path     => '/usr/share/perl5/PVE/API2/Nodes.pm',
        daemons  => [qw(pveproxy pvedaemon)],
        processes => [qw(pveproxy pvedaemon pvesh)],
    },
);

my %MODULE_TARGETS;
my %PATH_MODULE = map { $TARGETS{$_}{path} => $CORE } keys %TARGETS;

sub targets {
    my ($class) = @_;
    my %all = %TARGETS;
    for my $module (keys %MODULE_TARGETS) {
        $all{$_} = $MODULE_TARGETS{$module}{$_} for keys %{ $MODULE_TARGETS{$module} };
    }
    return \%all;
}

sub register_module {
    my ($class, $module) = @_;
    die "módulo de patch inválido\n"
        unless defined($module) && $module =~ /\AMMPve::Module::[A-Za-z][A-Za-z0-9_]*\z/;
    die "módulo $module não declara patch_targets\n"
        unless $module->can('patch_targets');
    my $declared = $module->patch_targets;
    die "patch_targets de $module precisa ser arrayref\n" unless ref($declared) eq 'ARRAY';
    return $class->register_targets($module, $declared);
}

sub register_targets {
    my ($class, $module, $declared) = @_;
    die "módulo de patch inválido\n"
        unless defined($module) && $module =~ /\AMMPve::Module::[A-Za-z][A-Za-z0-9_]*\z/;
    die "targets de $module precisam ser arrayref\n" unless ref($declared) eq 'ARRAY';

    my (%new, %new_paths);
    for my $source (@{$declared}) {
        die "target de $module precisa ser hashref\n" unless ref($source) eq 'HASH';
        my %t = %{$source};
        $t{id} //= $t{name};
        $t{owner} //= $t{owner_package} // $t{package};
        $t{line} //= $t{insert};
        $t{daemons} //= $t{reload_daemons};
        $t{processes} //= $t{loaders};
        my $id = $t{id};
        die "target de $module sem id\n"
            unless defined($id) && $id =~ /\A[a-z][a-z0-9_-]*\z/;
        die "target $id já declarado por $module\n" if exists $new{$id};
        die "target $id já pertence a outro módulo\n" if exists $TARGETS{$id};
        die "target $id já pertence a outro módulo\n"
            if grep { exists $MODULE_TARGETS{$_}{$id} && $_ ne $module } keys %MODULE_TARGETS;

        for my $required (qw(owner path line daemons processes)) {
            die "target $id sem $required\n" unless exists $t{$required};
        }
        die "owner do target $id inválido\n"
            unless $t{owner} =~ /\A[a-z0-9][a-z0-9+.-]*\z/;
        die "path do target $id inválido\n"
            unless $t{path} =~ m{\A/[A-Za-z0-9_./:+-]+\z};
        die "linha do target $id precisa ser uma linha\n"
            unless !ref($t{line}) && $t{line} !~ /\n/;
        die "target $id sem âncora\n" unless exists $t{anchor};
        die "âncora do target $id precisa ser regexp\n" unless ref($t{anchor}) eq 'Regexp';
        die "escopo do target $id precisa ser regexp\n"
            if exists($t{scope_anchor}) && ref($t{scope_anchor}) ne 'Regexp';
        for my $field (qw(daemons processes)) {
            die "$field do target $id precisa ser arrayref\n" unless ref($t{$field}) eq 'ARRAY';
            die "$field do target $id vazio\n" unless @{ $t{$field} };
            for my $name (@{ $t{$field} }) {
                die "$field do target $id inválido\n"
                    unless defined($name) && $name =~ /\A[A-Za-z0-9_.\@:-]+\z/;
            }
        }
        my $path_key = $t{path};
        die "arquivo $path_key já pertence a outro módulo\n"
            if exists($PATH_MODULE{$path_key}) && $PATH_MODULE{$path_key} ne $module;
        for my $other (keys %MODULE_TARGETS) {
            next if $other eq $module;
            for my $old (values %{ $MODULE_TARGETS{$other} }) {
                die "arquivo $path_key já pertence a $other\n" if $old->{path} eq $t{path};
            }
        }
        $t{module} = $module;
        $t{marker} //= $t{line};
        die "marker do target $id inválido\n"
            if ref($t{marker}) || $t{marker} eq '' || $t{marker} =~ /\n/;
        $t{syntax} //= ($t{path} =~ /\.pm\z/ ? 1 : 0);
        $new{$id} = \%t;
        $new_paths{$path_key} = 1;
    }

    $MODULE_TARGETS{$module} = \%new;
    $PATH_MODULE{$_->{path}} = $module for values %new;
    return 1;
}

sub unregister_module {
    my ($class, $module) = @_;
    my $old = delete $MODULE_TARGETS{$module} or return 0;
    for my $path (keys %PATH_MODULE) {
        delete $PATH_MODULE{$path} if $PATH_MODULE{$path} eq $module;
    }
    return scalar keys %{$old};
}

sub _patch_state_path { return root_path('/var/lib/mm-pve-tools/patch-state.json') }

sub _patch_state {
    my $raw = eval { read_file(_patch_state_path()) };
    return {} if $@ || !defined($raw) || $raw eq '';
    return eval { decode_json($raw) } || {};
}

sub _save_patch_state {
    my ($class, $state) = @_;
    ensure_dir(root_path('/var/lib/mm-pve-tools'));
    write_file_atomic(_patch_state_path(), encode_json($state) . "\n", 0644);
}

sub _read_lines {
    my ($path) = @_;
    my $raw = eval { read_file($path) };
    return undef if $@ || !defined($raw);
    return [ split(/^/, $raw) ];
}

sub _marker {
    my ($target) = @_;
    return '<!-- mm-pve-tools -->' if ($target->{kind} // '') eq 'index_tpl';
    return 'PVE::API2::MMTools' if ($target->{kind} // '') eq 'nodes_pm';
    return defined($target->{marker}) ? $target->{marker} : $target->{line};
}

sub _state_target {
    my ($target) = @_;
    my %copy = %{$target};
    delete $copy{anchor};
    delete $copy{scope_anchor};
    $copy{anchor_text} = "$target->{anchor}" if ref($target->{anchor}) eq 'Regexp';
    return \%copy;
}

sub _all_targets_with_state {
    my ($class) = @_;
    my %all = %{ $class->targets };
    my $state = _patch_state();
    for my $id (keys %{$state}) {
        next if exists $all{$id};
        next unless ref($state->{$id}) eq 'HASH';
        my $saved = $state->{$id}{target};
        next unless ref($saved) eq 'HASH';
        $all{$id} = { %{$saved}, id => ($saved->{id} // $id) };
    }
    return \%all;
}

# ---------------------------------------------------------------- check

sub check {
    my ($class, %opts) = @_;
    my $all = $class->_all_targets_with_state;
    my $state = _patch_state();
    my %res;
    for my $id (sort keys %{$all}) {
        my $target = $all->{$id};
        next if exists($opts{core}) && !$opts{core} && $target->{module} eq $CORE;
        my $path = root_path($target->{path});
        my $lines = _read_lines($path);
        if (!$lines) {
            $res{$id} = { status => 'file_missing', owner => $target->{owner} };
            next;
        }
        my $marker = _marker($target);
        my $has_marker = grep { index($_, $marker) >= 0 } @{$lines};
        if (($target->{kind} // '') eq 'index_tpl') {
            my $has_anchor = grep { $_ =~ $target->{anchor} } @{$lines};
            my $previous_failure = $state->{$id}{previous_failure}
                && ($state->{$id}{source_hash} // '') eq sha256_hex(join('', @{$lines}));
            $res{$id} = {
                status => $has_marker ? 'applied' : (!$has_anchor ? 'anchor_missing'
                    : ($previous_failure ? 'previous_failure' : 'not_applied')),
                owner => $target->{owner},
            };
        } elsif (($target->{kind} // '') eq 'nodes_pm') {
            my ($has_use, $has_rep) = (0, 0);
            for my $line (@{$lines}) {
                $has_use = 1 if $line =~ /^\s*use\s+PVE::API2::\w+(?:::\w+)*;/;
                $has_rep = 1 if $line =~ /subclass\s*=>\s*"PVE::API2::Replication"/;
            }
            my $previous_failure = $state->{$id}{previous_failure}
                && ($state->{$id}{source_hash} // '') eq sha256_hex(join('', @{$lines}));
            $res{$id} = {
                status => $has_marker ? 'applied' : (!( $has_use && $has_rep ) ? 'anchor_missing'
                    : ($previous_failure ? 'previous_failure' : 'not_applied')),
                owner => $target->{owner},
            };
        } else {
            my $has_anchor = defined($class->_anchor_index($target, $lines));
            my $previous_failure = $state->{$id}{previous_failure}
                && ($state->{$id}{source_hash} // '') eq sha256_hex(join('', @{$lines}));
            $res{$id} = {
                status => $has_marker ? 'applied' : (!$has_anchor ? 'anchor_missing'
                    : ($previous_failure ? 'previous_failure' : 'not_applied')),
                owner => $target->{owner}, module => $target->{module},
                daemons => [ @{ $target->{daemons} // [] } ],
                processes => [ @{ $target->{processes} // [] } ],
            };
        }
    }
    return \%res;
}

# ---------------------------------------------------------------- content

sub _anchor_index {
    my ($class, $target, $lines) = @_;
    my ($start, $end) = (0, $#{$lines});
    if (exists($target->{scope_anchor})) {
        my @scope = grep { $lines->[$_] =~ $target->{scope_anchor} } 0 .. $#{$lines};
        return undef unless @scope == 1;
        $start = $scope[0];
        if ($lines->[$start] =~ /^\s*sub\s+[A-Za-z_][A-Za-z0-9_]*\b/) {
            # Plain Perl subs close with an unindented `}` in the PVE sources.
            # Never let a missing anchor fall through into the next function.
            $end = undef;
            for my $i ($start + 1 .. $#{$lines}) {
                if ($lines->[$i] =~ /^}\s*(?:#.*)?$/) {
                    $end = $i;
                    last;
                }
            }
            return undef unless defined($end);
        } else {
            for my $i ($start + 1 .. $#{$lines}) {
                if ($lines->[$i] =~ /^\s*__PACKAGE__->register_method\s*\(/) {
                    $end = $i - 1;
                    last;
                }
            }
        }
    }
    my $wanted = $target->{occurrence} // 1;
    my $seen = 0;
    for my $i ($start .. $end) {
        next unless $lines->[$i] =~ $target->{anchor};
        $seen++;
        return $i if $seen == $wanted;
    }
    return undef;
}

sub _index_insert {
    return '<!-- mm-pve-tools --><script type="text/javascript" src="/pve2/js/mm-tools.js?ver='
        . $VERSION . '"></script>';
}

sub _patch_nodes_pm {
    my ($class, $lines) = @_;
    return { status => 'applied', changed => 0 } if grep { /PVE::API2::MMTools/ } @{$lines};
    my @uses = grep { $lines->[$_] =~ /^\s*use\s+PVE::API2::\w+(?:::\w+)*;/ } 0 .. $#{$lines};
    my $last_use = pop @uses;
    return { status => 'anchor_missing', note => 'âncora use PVE::API2::* ausente no Nodes.pm' }
        unless defined $last_use;
    my ($rep_line) = grep { $lines->[$_] =~ /subclass\s*=>\s*"PVE::API2::Replication"/ } 0 .. $#{$lines};
    my $close_after;
    if (defined $rep_line) {
        ($close_after) = grep { $lines->[$_] =~ /^\s*\}\);\s*$/ && $_ >= $rep_line }
            $rep_line .. $#{$lines};
    }
    return { status => 'anchor_missing', note => 'âncora subclass Replication ausente no Nodes.pm' }
        unless defined $close_after;
    my @new;
    for my $i (0 .. $#{$lines}) {
        push @new, $lines->[$i];
        push @new, q{__PACKAGE__->register_method({ subclass => "PVE::API2::MMTools", path => 'mm-tools' }); # mm-pve-tools} . "\n"
            if $i == $close_after;
        push @new, 'use PVE::API2::MMTools; # mm-pve-tools' . "\n" if $i == $last_use;
    }
    return { status => 'inserted', inserted => 1, lines => \@new };
}

sub _generic_desired {
    my ($class, $target, $raw) = @_;
    my @lines = split(/^/, $raw);
    my $line = $target->{line} . "\n";
    my $marker = _marker($target);
    for my $i (0 .. $#lines) {
        next unless index($lines[$i], $marker) >= 0;
        return { ok => 1, content => $raw } if $lines[$i] eq $line;
        $lines[$i] = $line;
        return { ok => 1, content => join('', @lines) };
    }
    my $at = $class->_anchor_index($target, \@lines);
    return { ok => 0, status => 'anchor_missing', note => "âncora ausente em $target->{id}" }
        unless defined $at;
    splice @lines, $at + 1, 0, $line;
    return { ok => 1, content => join('', @lines) };
}

sub _desired_content {
    my ($class, $target, $raw) = @_;
    if (($target->{kind} // '') eq 'index_tpl') {
        my @lines = split(/^/, $raw);
        my $insert = _index_insert();
        my $found = 0;
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /mm-tools\.js/) {
                $lines[$i] = $insert . "\n"; $found = 1; last;
            }
        }
        if (!$found) {
            my @new;
            for my $line (@lines) {
                push @new, $line;
                push @new, $insert . "\n" if $line =~ $target->{anchor};
            }
            return { ok => 0, status => 'anchor_missing', note => 'âncora (pvemanagerlib.js) não encontrada; GUI fica original' }
                if @new == @lines;
            @lines = @new;
        }
        return { ok => 1, content => join('', @lines) };
    }
    if (($target->{kind} // '') eq 'nodes_pm') {
        return { ok => 1, content => $raw } if $raw =~ /PVE::API2::MMTools/;
        my @lines = split(/^/, $raw);
        my $r = $class->_patch_nodes_pm(\@lines);
        return { ok => 0, status => $r->{status}, note => $r->{note} } unless $r->{status} eq 'inserted';
        return { ok => 1, content => join('', @{ $r->{lines} }) };
    }
    return $class->_generic_desired($target, $raw);
}

sub _revert_content {
    my ($class, $target, $raw) = @_;
    my @lines = split(/^/, $raw);
    my $marker = _marker($target);
    my @kept;
    if (($target->{kind} // '') eq 'index_tpl') {
        @kept = grep { $_ !~ /<!-- mm-pve-tools -->/
            && $_ !~ m{^\s*<script[^>]*src="/pve2/js/mm-tools\.js[^"]*"></script>\s*$} } @lines;
    } elsif (($target->{kind} // '') eq 'nodes_pm') {
        @kept = grep { !($_ =~ /use PVE::API2::MMTools;/ && $_ =~ /mm-pve-tools/)
            && !($_ =~ /subclass => "PVE::API2::MMTools"/ && $_ =~ /mm-pve-tools/) } @lines;
    } else {
        @kept = grep { index($_, $marker) < 0 } @lines;
    }
    return { ok => 1, content => join('', @kept), changed => scalar(@kept) != scalar(@lines) };
}

# ---------------------------------------------------------------- transaction

sub _syntax_check_mode {
    my ($class, $opts) = @_;
    my $mode = $opts->{syntax_check} || 'auto';
    return $mode if $mode ne 'auto';
    our $_can_syntax;
    $_can_syntax //= MMPve::Core::Runner->run(['perl', '-MPVE::RESTHandler', '-e1'], timeout => 15)->{ok}
        ? 'always' : 'never';
    return $_can_syntax;
}

# Valida o stage de um módulo como o módulo que ele é: um hook no @INC entrega
# o stage quando alguém pede o caminho do módulo, e o require resolve os ciclos
# de use como nos daemons. Compilar o arquivo solto (perl -c) quebra nesses
# ciclos: PVE/Storage.pm usa DirPlugin, que usa GuestImport::OVF, que usa
# PVE::Storage e carrega o Storage.pm original no meio da compilação ("Can't
# locate object method register via package PVE::Storage::DirPlugin") mesmo
# sem patch nenhum, e o poollimits nunca ligava num PVE real.
my $STAGED_LOADER = <<'PERL';
my ($rel, $staged) = @ARGV;
unshift @INC, sub {
    my (undef, $file) = @_;
    return unless $file eq $rel;
    open(my $fh, '<', $staged) or die "não consegui abrir $staged: $!\n";
    return $fh;
};
require $rel;
print "$rel OK\n";
PERL

sub _perl_c {
    my ($class, $path, $target) = @_;
    my ($rel) = ref($target) eq 'HASH'
        ? ($target->{path} // '') =~ m{\A/usr/share/perl5/((?:[A-Za-z0-9_]+/)*[A-Za-z0-9_]+\.pm)\z}
        : ();
    return MMPve::Core::Runner->run(['perl', '-c', $path], timeout => 120) unless defined($rel);
    return MMPve::Core::Runner->run(['perl', '-e', $STAGED_LOADER, $rel, $path], timeout => 120);
}

# Esquece falhas anteriores de patch. Roda na instalação do pacote: código novo
# merece uma nova tentativa, sem o timer martelar a mesma falha a cada ciclo.
sub clear_failures {
    my ($class) = @_;
    my $state = _patch_state();
    my @cleared = sort grep { ref($state->{$_}) eq 'HASH' && $state->{$_}{previous_failure} } keys %{$state};
    delete @{$state}{@cleared};
    $class->_save_patch_state($state) if @cleared;
    return { cleared => \@cleared };
}

sub _safe_name {
    my ($text) = @_;
    ($text) = $text =~ /\A([A-Za-z0-9_.-]+)\z/;
    return $text // 'target';
}

sub _backup_for {
    my ($class, $target, $raw, $path) = @_;
    my $dir = root_path('/var/lib/mm-pve-tools/patch-backups'); ensure_dir($dir);
    my $name = _safe_name($target->{backup_name} // $target->{id});
    my $marker = _marker($target);
    if ($raw =~ /mm-pve-tools|\Q$marker\E/) {
        if (opendir(my $dh, $dir)) {
            my @found = sort grep { /^\Q$name\E\.[0-9a-f]{64}$/ } readdir($dh);
            closedir($dh); return "$dir/$found[0]" if @found;
        }
    }
    my $bak = "$dir/$name." . sha256_hex($raw);
    return $bak if -f $bak;
    return undef unless copy($path, $bak);
    return $bak;
}

sub _transaction_backup {
    my ($class, $target, $path) = @_;
    my $dir = root_path('/var/lib/mm-pve-tools/patch-backups'); ensure_dir($dir);
    my $bak = "$dir/.txn-" . _safe_name($target->{id}) . "-$$-" . random_uuid();
    copy($path, $bak) or return; return $bak;
}

sub _validate_staged {
    my ($class, $target, $path, $opts) = @_;
    my $raw = eval { read_file($path) };
    return { ok => 0, error => "não consegui ler stage: $@" } if $@;
    if (!$opts->{reverting} && ($target->{kind} // '') eq 'index_tpl'
        && $raw !~ /mm-tools\.js\?ver=\Q$VERSION\E/) {
        return { ok => 0, error => 'stage sem script mm-tools.js' };
    }
    my $syntax = $target->{syntax} // (($target->{path} // '') =~ /\.pm\z/ ? 1 : 0);
    if ($syntax && $class->_syntax_check_mode($opts) ne 'never') {
        my $can = $class->_perl_c($path, $target);
        return { ok => 0, error => ($can->{err} // $can->{error} // "rc=$can->{rc}") } unless $can->{ok};
    }
    return { ok => 1 };
}

sub _sync_group {
    my ($class, $module, $ids, $all, $want_on, %opts) = @_;
    my $state = _patch_state();
    my (%out, %raw, %desired, %backup, %staged, %path_raw, %path_desired, @changed);
    my $group = { module => $module, enabled => $want_on ? 1 : 0, target_ids => [ @{$ids} ],
        targets => \%out, changed => 0, daemons => [], processes => [], ok => 1 };
    my (%daemons, %processes);
    for my $id (@{$ids}) {
        my $target = $all->{$id}; my $path = root_path($target->{path});
        my $raw_now = eval { read_file($path) };
        if ($@) { $out{$id} = { status => 'file_missing', owner => $target->{owner}, module => $module };
            $group->{ok} = 0 if $want_on; next; }
        $path_raw{$path} //= $raw_now;
        $raw{$id} = $raw_now;
        my $working = exists($path_desired{$path}) ? $path_desired{$path} : $raw_now;
        if ($want_on) {
            my $source_hash = sha256_hex($path_raw{$path});
            if ($state->{$id} && ($state->{$id}{source_hash} // '') eq $source_hash && $state->{$id}{previous_failure}) {
                $out{$id} = { status => 'previous_failure', error => $state->{$id}{error} };
                $group->{ok} = 0; next;
            }
            my $want = $class->_desired_content($target, $working);
            if (!$want->{ok}) {
                $out{$id} = { status => $want->{status}, note => $want->{note}, owner => $target->{owner} };
                $state->{$id} = { source_hash => $source_hash, previous_failure => 1, error => $want->{note}, target => _state_target($target) }
                    if ($want->{status} // '') eq 'anchor_missing';
                $group->{ok} = 0; next;
            }
            $desired{$id} = $want->{content};
            $path_desired{$path} = $desired{$id};
            if ($desired{$id} eq $working) { $out{$id} = { status => 'version_current', changed => 0, owner => $target->{owner} };
                delete $state->{$id} if $state->{$id} && $state->{$id}{previous_failure}; next; }
            my $bak = $class->_backup_for($target, $path_raw{$path}, $path);
            if (!$bak) { $out{$id} = { status => 'failed', error => "backup: $!", owner => $target->{owner} };
                $group->{ok} = 0; next; }
            $backup{$id} = $bak;
        } else {
            my $rev = $class->_revert_content($target, $working); $desired{$id} = $rev->{content};
            $path_desired{$path} = $desired{$id};
            if (!$rev->{changed}) { $out{$id} = { status => 'not_applied', changed => 0, owner => $target->{owner} }; next; }
            my $bak = $class->_transaction_backup($target, $path);
            if (!$bak) { $out{$id} = { status => 'failed', error => "backup de rollback: $!", owner => $target->{owner} };
                $group->{ok} = 0; next; }
            $backup{$id} = $bak;
        }
        push @changed, $id; $daemons{$_} = 1 for @{ $target->{daemons} // [] };
        $processes{$_} = 1 for @{ $target->{processes} // [] };
    }
    if (!$group->{ok}) { $class->_save_patch_state($state) if $want_on; return $group; }

    my $transaction_error;
    my %changed_paths;
    $changed_paths{root_path($all->{$_}{path})} = 1 for @changed;
    eval {
        for my $path (keys %changed_paths) {
            my $stage = $path . ".mm-stage-$$-" . random_uuid();
            $staged{$path} = $stage;
            write_file_atomic($stage, $path_desired{$path}, 0644);
        }
        for my $id (@changed) { my %validate_opts = (%opts, reverting => !$want_on);
            my $valid = $class->_validate_staged($all->{$id}, $staged{root_path($all->{$id}{path})}, \%validate_opts);
            die "$id: $valid->{error}\n" unless $valid->{ok}; }
        for my $path (keys %changed_paths) { rename($staged{$path}, $path)
            or die "rename do stage para $path: $!\n"; }
        for my $path (keys %changed_paths) { my $after = read_file($path);
            die "$path: verificação pós-commit falhou\n" unless $after eq $path_desired{$path}; }
        1;
    } or do { $transaction_error = $@ || 'falha desconhecida na transação' };
    if ($transaction_error) {
        unlink($_) for values %staged; my @rollback_errors;
        my %rolled;
        for my $id (@changed) {
            my $path = $all->{$id}{path};
            next if $rolled{$path}++;
            push @rollback_errors, "$id: $!" unless copy($backup{$id}, root_path($path));
        }
        my $error = $transaction_error; $error .= ' rollback: ' . join('; ', @rollback_errors) if @rollback_errors;
        $out{$_} = { status => 'failed', error => $error, restored => @rollback_errors ? 0 : 1 } for @changed;
        $group->{ok} = 0; $group->{error} = $error;
        log_line('patch apply: transação do grupo ' . $module . ' revertida: ' . $error);
        $state->{$_} = { source_hash => sha256_hex($raw{$_}), previous_failure => 1, error => $error, target => _state_target($all->{$_}) } for @changed;
        $class->_save_patch_state($state); return $group;
    }
    for my $id (@changed) {
        my $target = $all->{$id}; $out{$id} = { status => $want_on ? 'applied' : 'reverted', changed => 1,
            owner => $target->{owner}, module => $module, backup => $backup{$id} };
        if ($want_on) { $state->{$id} = { source_hash => sha256_hex($raw{$id}), applied => 1, target => _state_target($target) }; }
        else { delete $state->{$id}; }
    }
    $class->_save_patch_state($state); $group->{changed} = @changed ? 1 : 0;
    $group->{daemons} = [ sort keys %daemons ]; $group->{processes} = [ sort keys %processes ];
    if ($group->{changed} && !$opts{no_restart}) {
        my $reload = $class->_restart_and_verify($group->{daemons}); $group->{reload} = $reload;
        if (!$reload->{ok}) {
            my $rev = $class->_sync_group($module, $ids, $all, 0, %opts, no_restart => 1);
            $group->{reverted} = $rev->{changed}; $group->{recovery_reload} = $class->_restart_and_verify($group->{daemons});
            $group->{ok} = 0; $group->{error} = 'daemon não voltou ativo após reload; patch do módulo revertido';
        }
    }
    return $group;
}

sub _module_enabled {
    my ($module, $active) = @_;
    return 0 unless ref($active) eq 'HASH';
    return 1 if $active->{$module};
    (my $name = $module) =~ s/^MMPve::Module:://;
    return $active->{lc($name)} ? 1 : 0;
}

# opts: syntax_check => auto|always|never ; no_restart => 1 ;
# active_modules => { module-name => boolean } ; core => 0 (test helper only)
sub apply {
    my ($class, %opts) = @_;
    my $all = $class->_all_targets_with_state; my %modules;
    push @{ $modules{ $all->{$_}{module} // $CORE } }, $_ for keys %{$all};
    my %res = (ok => 1, changed => 0, targets => {}, modules => {}, daemons => [], processes => []);
    my (%daemons, %processes);
    for my $module (sort keys %modules) {
        next if exists($opts{core}) && !$opts{core} && $module eq $CORE;
        my $enabled = $module eq $CORE ? 1 : _module_enabled($module, $opts{active_modules});
        my $group = $class->_sync_group($module, $modules{$module}, $all, $enabled, %opts);
        if ($module eq $CORE) { $res{targets}{$_} = $group->{targets}{$_} for keys %{ $group->{targets} }; }
        else { $res{modules}{$module} = $group; }
        $res{changed} = 1 if $group->{changed}; $res{ok} = 0 unless $group->{ok};
        $daemons{$_} = 1 for @{ $group->{daemons} // [] }; $processes{$_} = 1 for @{ $group->{processes} // [] };
    }
    $res{daemons} = [ sort keys %daemons ]; $res{processes} = [ sort keys %processes ];
    my $state = _patch_state();
    if ($opts{no_restart}) {
        my @pending = map {
            {
                module => $_->{module}, enabled => $_->{enabled}, target_ids => $_->{target_ids},
                daemons => $_->{daemons},
            }
        } grep { $_->{changed} && @{ $_->{daemons} // [] } } values %{ $res{modules} };
        # __core__ is represented separately because it lives in targets.
        if ($res{changed} && keys %{ $res{targets} }) {
            my @ids = grep { ($all->{$_}{module} // '') eq $CORE
                && $res{targets}{$_}{changed} } keys %{ $res{targets} };
            my %d;
            $d{$_} = 1 for map { @{ $all->{$_}{daemons} // [] } } @ids;
            push @pending, { module => $CORE, enabled => 1, target_ids => \@ids,
                daemons => [ sort keys %d ] } if @ids;
        }
        if ($res{changed} && @pending) {
            $state->{pending_reload} = \@pending;
        } else {
            delete $state->{pending_reload};
        }
    } else {
        delete $state->{pending_reload};
    }
    $class->_save_patch_state($state);
    log_line('patch apply: ok=' . $res{ok} . ' changed=' . $res{changed} . ' daemons=' . join(',', @{ $res{daemons} }));
    return \%res;
}

sub revert {
    my ($class, %opts) = @_;
    my $all = $class->_all_targets_with_state; my %modules;
    push @{ $modules{ $all->{$_}{module} // $CORE } }, $_ for keys %{$all};
    my %res = (ok => 1, changed => 0, targets => {}, modules => {}, daemons => [], processes => []);
    my (%daemons, %processes);
    for my $module (sort keys %modules) {
        next if exists($opts{core}) && !$opts{core} && $module eq $CORE;
        my $group = $class->_sync_group($module, $modules{$module}, $all, 0, %opts, no_restart => 1);
        if ($module eq $CORE) { $res{targets}{$_} = $group->{targets}{$_} for keys %{ $group->{targets} }; }
        else { $res{modules}{$module} = $group; }
        $res{changed} = 1 if $group->{changed}; $res{ok} = 0 unless $group->{ok};
        $daemons{$_} = 1 for @{ $group->{daemons} // [] }; $processes{$_} = 1 for @{ $group->{processes} // [] };
    }
    if ($res{changed} && !$opts{no_restart}) {
        $res{reload} = $class->_restart_and_verify([ sort keys %daemons ]);
        if (!$res{reload}{ok}) {
            $res{recovery_reload} = $class->_restart_and_verify([ sort keys %daemons ]);
            $res{ok} = 0;
        }
    }
    $res{daemons} = [ sort keys %daemons ]; $res{processes} = [ sort keys %processes];
    my $state = _patch_state();
    delete $state->{pending_reload};
    $class->_save_patch_state($state);
    log_line('patch revert: ok=' . $res{ok} . ' changed=' . $res{changed});
    return \%res;
}

sub _restart_and_verify {
    my ($class, $daemons) = @_;
    my @services = sort grep { defined && length } @{ $daemons // [qw(pveproxy pvedaemon)] };
    return { ok => 1, daemons => [] } unless @services;
    my $unit = 'mm-pve-patch-reload-' . substr(random_uuid(), 0, 12);
    my @units = map { "$_.service" } @services;
    my $restart = MMPve::Core::Runner->run(['systemd-run', '--wait', '--collect', "--unit=$unit", 'systemctl', 'reload', @units], timeout => 120);
    my $v = { restart_rc => $restart->{rc}, ok => 0, daemons => \@services };
    for my $svc (@services) { my $a = MMPve::Core::Runner->run(['systemctl', 'is-active', "$svc.service"], timeout => 30);
        $v->{"active_$svc"} = ($a->{out} // '') =~ /^active\s*$/m ? 1 : 0; }
    my $ver = MMPve::Core::Runner->run(['pvesh', 'get', '/version', '--output-format', 'json'], timeout => 60);
    $v->{pve_version_ok} = $ver->{ok} ? 1 : 0;
    $v->{ok} = $restart->{ok} && $ver->{ok} && (grep { !$v->{"active_$_"} } @services) == 0 ? 1 : 0;
    log_line('patch: pós-reload falhou (' . ($ver->{err} || $restart->{err} || 'daemon inativo após reload') . ')') unless $v->{ok};
    return $v;
}

sub reload_services {
    my ($class, %opts) = @_;
    return $class->_restart_and_verify($opts{daemons});
}

sub reload_verify {
    my ($class, %opts) = @_;
    my $state = _patch_state();
    my $pending = ref($state->{pending_reload}) eq 'ARRAY' ? $state->{pending_reload} : [];
    my $all = $class->_all_targets_with_state;
    my (@groups, @results);
    my $ok = 1;

    if (!@{$pending} && ref($opts{fallback_daemons}) eq 'ARRAY' && @{ $opts{fallback_daemons} }) {
        push @groups, { module => undef, daemons => $opts{fallback_daemons}, target_ids => [] };
    }
    for my $pending_group (@groups, @{$pending}) {
        my $daemons = $pending_group->{daemons} // [];
        my $result = { module => $pending_group->{module}, daemons => [ @{$daemons} ] };
        my $reload = $class->_restart_and_verify($daemons);
        $result->{reload} = $reload;
        if (!$reload->{ok}) {
            my $module = $pending_group->{module};
            if (defined($module)) {
                my @ids = @{ $pending_group->{target_ids} // [] };
                @ids = grep { ($all->{$_}{module} // '') eq $module } keys %{$all} unless @ids;
                my $reverted = $class->_sync_group($module, \@ids, $all, 0,
                    no_restart => 1, syntax_check => 'never');
                $result->{reverted} = $reverted->{changed};
            }
            $result->{recovery_reload} = $class->_restart_and_verify($daemons);
            $result->{ok} = 0;
            $ok = 0;
        } else {
            $result->{ok} = 1;
        }
        push @results, $result;
    }
    delete $state->{pending_reload};
    $class->_save_patch_state($state);
    return { ok => $ok, groups => \@results };
}

1;
