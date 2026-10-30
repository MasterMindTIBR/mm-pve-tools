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
    my $cfg = eval { MMPve::Core::Config->load };
    my $cfg_err = $@;
    if ($cfg_err) {
        # config inválida/ausente: aplica nada de módulo, mas garante patch
        $cfg = MMPve::Core::Config->default;
    }

    my %res = (
        started => _now(),
        revision => $cfg->{revision},
        modules => {},
    );

    if (!exists $opts{patches} || $opts{patches}) {    # garante patches (idempotente)
        $res{patches} = MMPve::Core::Patch->apply();
    }

    my $mode = $cfg->{modules} || {};
    for my $m (MMPve::Core::Modules->all) {
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
    for my $n (sort keys %{ $res{modules} }) {
        $res{ok} = 0 if !$res{modules}{$n}{ok};
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
    if (defined $rev_cfg && ($state->{revision} // 0) < $rev_cfg) {
        $st = 'pending';
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
        $st = 'error' if !$m->{ok};
    }
    return {
        config_revision => $rev_cfg,
        applied_revision => $state->{revision},
        state => $st,
        modules => \%mods,
        patches => MMPve::Core::Patch->check,
        finished => $state->{finished},
    };
}

1;
