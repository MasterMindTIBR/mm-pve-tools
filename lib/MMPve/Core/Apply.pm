package MMPve::Core::Apply;

# Aplicação do estado desejado em cada node:
#  - patches do pve-manager (barato: é idempotente)
#  - módulos ligados → apply; módulos desligados → revert
#  - resultado por módulo em /var/lib/mm-pve-tools/applied.json
# Roda: botão GUI (POST /nodes/{node}/mm-tools/apply), timer (5 min), boot,
# trigger dpkg (via postinst). Tudo idempotente.

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);
use MMPve::Core::Config;
use MMPve::Core::Modules;
use MMPve::Core::Patch;
use MMPve::Core::Runner;
use MMPve::Core::Util qw(root_path read_file write_file_atomic ensure_dir log_line);

our $VERSION = '@MM_PVE_VERSION@';

sub state_path {
    return root_path('/var/lib/mm-pve-tools/applied.json');
}

sub _now { return strftime('%Y-%m-%dT%H:%M:%S%z', localtime) }

# opts: patches => 0|1 (default 1), dry_run => 1
sub apply_all {
    my ($class, %opts) = @_;
    if (!$opts{allow_updates}) {
        my $busy = eval {
            require MMPve::Module::Updates;
            MMPve::Module::Updates->active_job || MMPve::Module::Updates->dpkg_locked;
        };
        if ($busy) {
            return {
                ok => 1, skipped => 1, reason => 'update em execução ou lock do dpkg',
                revision => eval { MMPve::Core::Config->load->{revision} },
            };
        }
    }
    my $cfg = eval { MMPve::Core::Config->load };
    my $cfg_err = $@;
    if ($cfg_err) {
        # config inválida/ausente: aplica nada de módulo, mas garante patch
        $cfg = MMPve::Core::Config->default;
    }

    my %res = (
        started => _now(),
        package_version => $VERSION,
        revision => $cfg->{revision},
        modules => {},
    );
    my @modules = MMPve::Core::Modules->all;
    my $previous = eval { decode_json(read_file(state_path())) };
    my $patches_requested = !exists $opts{patches} || $opts{patches};
    my $version_changed = $patches_requested
        && (!$previous || ($previous->{package_version} // '') ne $VERSION);
    my $mode = $cfg->{modules} || {};
    my $patch_mode = { %{$mode} };
    if ($cfg_err) {
        eval {
            require MMPve::Module::Poollimits;
            $patch_mode->{poollimits} = MMPve::Module::Poollimits->patch_enabled_for_invalid ? 1 : 0;
            1;
        };
    }
    if ($patches_requested) {    # garante patches (idempotente), conforme estado efetivo
        $res{patches} = MMPve::Core::Patch->apply(
            active_modules => $patch_mode,
            no_restart => $opts{no_reload} ? 1 : 0,
        );
    }
    for my $m (@modules) {
        my $name = $m->name;
        my $enabled = $mode->{$name} ? 1 : 0;
        my $out;
        if ($cfg_err) {
            $out = { ok => 0, error => "config inválido; módulo não aplicado: $cfg_err" };
        } elsif ($enabled) {
            $out = eval { $m->apply($cfg) };
            $out = { ok => 0, error => $@ } unless ref $out eq 'HASH';
        } else {
            $out = eval { $m->revert() };
            $out = { ok => 0, error => $@ } unless ref $out eq 'HASH';
        }
        $out->{enabled} = $enabled;
        $out->{ts} = _now();
        $res{modules}{$name} = $out;
    }
    $res{finished} = _now();
    $res{ok} = 1;
    $res{ok} = 0 if $res{patches} && !$res{patches}{ok};
    for my $n (sort keys %{ $res{modules} }) {
        $res{ok} = 0 if !$res{modules}{$n}{ok};
    }
    $res{reload_required} = ($version_changed
        || ($res{patches} && $res{patches}{changed} && $opts{no_reload})
        || ($res{modules}{branding} && $res{modules}{branding}{changed})
        || ($res{modules}{ui} && $res{modules}{ui}{changed})) ? 1 : 0;
    if ($res{reload_required} && !$opts{no_reload} && $res{ok}) {
        $res{reload} = MMPve::Core::Patch->reload_services;
        $res{ok} = 0 unless $res{reload}{ok};
    }
    if (!$opts{dry_run}) {
        ensure_dir(root_path('/var/lib/mm-pve-tools'));
        write_file_atomic(state_path(), encode_json(\%res) . "\n", 0644);
    }
    log_line('apply: ok=' . $res{ok} . ' revision=' . $res{revision});
    return \%res;
}

# estado p/ diagnóstico: aplicado / pendente / erro (com mensagem)
sub status {
    my ($class) = @_;
    MMPve::Core::Modules->all;
    my $cfg = eval { [MMPve::Core::Config->load] };
    my $rev_cfg = $cfg ? $cfg->[0]{revision} : undef;
    my $state = eval { decode_json(read_file(state_path())) };
    return {
        config_revision => $rev_cfg,
        applied_revision => undef,
        state => 'never_applied',
        modules => {},
        patches => MMPve::Core::Patch->check,
    } if $@ || !$state;

    my $st = 'applied';
    my $last_apply_failed = exists($state->{ok}) && !$state->{ok};
    my @failures;
    my %failed_targets;
    my $patches = MMPve::Core::Patch->check;
    my $patches_were_requested = ref($state->{patches}) eq 'HASH';
    my $enabled = sub {
        my ($module) = @_;
        return 1 unless defined($module) && length($module) && $module ne '__core__';
        (my $name = $module) =~ s/^MMPve::Module:://;
        return (($cfg && ref($cfg->[0]{modules}) eq 'HASH')
            && $cfg->[0]{modules}{lc($name)}) ? 1 : 0;
    };
    for my $target (sort keys %{$patches}) {
        next unless $patches_were_requested;
        my $item = $patches->{$target} || {};
        next unless $enabled->($item->{module});
        next if ($item->{status} // '') eq 'applied';
        my $error = $item->{error} // $item->{note};
        push @failures, {
            target => $target,
            status => $item->{status},
            error => $error,
            failed_target => $item->{failed_target},
            failure => $item->{failure},
        };
        $failed_targets{$target} = 1;
    }
    my %mods;
    for my $n (sort keys %{ $state->{modules} // {} }) {
        my $m = $state->{modules}{$n};
        $mods{$n} = {
            enabled => $m->{enabled},
            ok => $m->{ok},
            error => $m->{error},
            changed => $m->{changed},
            ts => $m->{ts},
        };
        if (!$m->{ok}) {
            push @failures, { module => $n, error => $m->{error}, status => 'apply_failed' };
        }
    }
    if ($last_apply_failed || grep { !$_->{ok} } values %{ $state->{modules} // {} }) {
        $st = 'error';
    } elsif (defined $rev_cfg && ($state->{revision} // 0) < $rev_cfg) {
        $st = 'pending';
    } elsif (@failures) {
        $st = 'partial';
    }
    my @failed = sort keys %failed_targets;
    for my $failure (@failures) {
        push @failed, $failure->{target} if defined($failure->{target});
    }
    my %seen;
    @failed = sort grep { !$seen{$_}++ } @failed;
    return {
        config_revision => $rev_cfg,
        applied_revision => $state->{revision},
        state => $st,
        last_apply_ok => $last_apply_failed ? 0 : 1,
        modules => \%mods,
        patches => $patches,
        failures => \@failures,
        failed_targets => \@failed,
        finished => $state->{finished},
    };
}

1;
