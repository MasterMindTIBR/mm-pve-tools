package MMPve::Journal;

# Journal de tarefa longa (ex.: troca de VMID), replicado pelo pmxcfs em
# /etc/pve/mm-tools/journal/<id>.json — permite --resume e --rollback a
# partir de qualquer node do cluster.
#
#   my $j = MMPve::Journal->create('renumber-100-1100', meta => {...});
#   my $j = MMPve::Journal->open('renumber-100-1100');
#   $j->steps(['reservar', 'mover_discos', 'config', 'firewall', 'refs', 'checar', 'destruir']);
#   $j->mark_running('mover_discos', detail => {disk => 'scsi0'});   # ANTES
#   $j->mark_done('mover_discos');
#   $j->mark_failed('mover_discos', 'mensagem');
#   my $next = $j->first_pending;        # primeiro passo sem done
#   my @done = $j->done_steps;
#   my @undo = $j->rollback_steps;       # done em ordem inversa
#   $j->record('mover_discos', disks => [...]);   # dados p/ rollback

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use MMPve::Core::Util qw(read_file write_file_atomic ensure_dir now_iso log_line flock_ex unlock);
use Sys::Hostname qw(hostname);
use POSIX qw(getpid);

our $VERSION = '@MM_PVE_VERSION@';

my $MAX = 1024 * 1024;    # limite do pmxcfs

sub dir {
    my ($class) = @_;
    return ($ENV{MM_PVE_CONFIG_DIR} || '/etc/pve/mm-tools') . '/journal';
}

sub path_for {
    my ($class, $id) = @_;
    die "id inválido\n" unless $id =~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
    return $class->dir . "/$id.json";
}

sub create {
    my ($class, $id, %meta) = @_;
    my $self = bless { id => $id, file => $class->path_for($id) }, $class;
    $self->{data} = {
        id => $id,
        created => now_iso(),
        updated => now_iso(),
        state => 'running',
        meta => \%meta,
        step_order => [],
        steps => {},
    };
    $self->_write;
    return $self;
}

sub open {
    my ($class, $id) = @_;
    my $file = $class->path_for($id);
    my $data = eval { decode_json(read_file($file)) };
    die "journal $id não encontrado/inválido: $@\n" if $@ || !$data;
    return bless { id => $id, file => $file, data => $data }, $class;
}

sub id     { return $_[0]->{id} }
sub meta   { return $_[0]->{data}{meta} }
sub state  { return $_[0]->{data}{state} }
sub data   { return $_[0]->{data} }

sub set_meta {
    my ($self, %meta) = @_;
    $self->{data}{meta}{$_} = $meta{$_} for keys %meta;
    $self->_write;
}

sub set_state {
    my ($self, $s) = @_;
    $self->{data}{state} = $s;
    $self->_write;
}

sub steps {
    my ($self, $list) = @_;
    if ($list) {
        die "steps precisa de arrayref\n" unless ref $list eq 'ARRAY';
        $self->{data}{step_order} = [@{$list}];
    }
    return @{ $self->{data}{step_order} };
}

sub mark_running {
    my ($self, $step, %info) = @_;
    die "passo desconhecido '$step'\n"
        unless grep { $_ eq $step } @{ $self->{data}{step_order} };
    $self->{data}{steps}{$step} = {
        %{ $self->{data}{steps}{$step} // {} },
        status => 'running', started => now_iso(), %info,
    };
    $self->_write;
}

sub mark_done {
    my ($self, $step) = @_;
    $self->{data}{steps}{$step}{status} = 'done';
    $self->{data}{steps}{$step}{finished} = now_iso();
    $self->_write;
}

sub mark_failed {
    my ($self, $step, $err) = @_;
    $self->{data}{steps}{$step}{status} = 'failed';
    $self->{data}{steps}{$step}{error} = $err // 'erro';
    $self->{data}{steps}{$step}{finished} = now_iso();
    $self->{data}{state} = 'failed';
    $self->_write;
}

# dados livres para rollback/retomada (ex.: config original da VM)
sub record {
    my ($self, $step, %info) = @_;
    $self->{data}{steps}{$step} //= { status => 'pending' };
    $self->{data}{steps}{$step}{$_} = $info{$_} for keys %info;
    $self->_write;
}

sub step_info {
    my ($self, $step) = @_;
    return $self->{data}{steps}{$step} // {};
}

sub first_pending {
    my ($self) = @_;
    for my $s (@{ $self->{data}{step_order} }) {
        my $st = $self->{data}{steps}{$s}{status} // 'pending';
        return $s if $st ne 'done';    # pending/running/failed → refazer
    }
    return undef;                      # tudo done
}

sub done_steps {
    my ($self) = @_;
    return grep { ($self->{data}{steps}{$_}{status} // '') eq 'done' }
        @{ $self->{data}{step_order} };
}

sub rollback_steps {
    my ($self) = @_;
    return reverse $self->done_steps;
}

sub _write {
    my ($self) = @_;
    $self->{data}{updated} = now_iso();
    ensure_dir($self->dir);
    my $json = JSON::PP->new->canonical->pretty->utf8->encode($self->{data});
    die "journal excede 1 MiB (pmxcfs)\n" if length($json) > $MAX;
    write_file_atomic($self->{file}, $json . "\n", 0644);
    return 1;
}

# O lock de domínio só protege a transição curta do marcador. Nunca chame
# código de tarefa dentro dele: o pve-cluster aborta callbacks após 60s.
sub _with_run_lock {
    my ($self, $code) = @_;
    if (eval { require PVE::Cluster; PVE::Cluster->can('cfs_lock_domain') }) {
        my $out = PVE::Cluster::cfs_lock_domain('mm-renumber', 10, $code);
        die $@ if $@;
        return $out;
    }

    my $lock = flock_ex($self->dir . '/.mm-renumber.lock');
    my ($out, $ok);
    $ok = eval { $out = $code->(); 1 };
    my $err = $@;
    unlock($lock);
    die $err unless $ok;
    return $out;
}

sub claim_run {
    my ($self, %opt) = @_;
    my $node = $opt{owner_node} // hostname();
    my $pid = $opt{pid} // getpid();
    my $now = time;
    my $ttl = $opt{ttl} // 120;
    return $self->_with_run_lock(sub {
        my $current = $self->{data}{run_marker};
        if ($current && ($current->{heartbeat} // 0) > $now - $ttl) {
            die "renumber já está em execução no node $current->{owner_node} "
                . "(pid $current->{pid}); aguarde o heartbeat expirar\n";
        }
        $self->{data}{run_marker} = {
            owner_node => $node,
            pid => 0 + $pid,
            heartbeat => 0 + $now,
            heartbeat_at => now_iso(),
        };
        $self->_write;
        return 1;
    });
}

sub heartbeat_run {
    my ($self, %opt) = @_;
    my $node = $opt{owner_node} // hostname();
    my $pid = $opt{pid} // getpid();
    return $self->_with_run_lock(sub {
        my $m = $self->{data}{run_marker} || {};
        die "marcador de execução não pertence a este processo\n"
            unless ($m->{owner_node} // '') eq $node && ($m->{pid} // -1) == $pid;
        $m->{heartbeat} = 0 + time;
        $m->{heartbeat_at} = now_iso();
        $self->_write;
        return 1;
    });
}

sub release_run {
    my ($self, %opt) = @_;
    my $node = $opt{owner_node} // hostname();
    my $pid = $opt{pid} // getpid();
    return $self->_with_run_lock(sub {
        my $m = $self->{data}{run_marker};
        return 1 unless $m;
        die "marcador de execução pertence a outro processo\n"
            unless ($m->{owner_node} // '') eq $node && ($m->{pid} // -1) == $pid;
        delete $self->{data}{run_marker};
        $self->_write;
        return 1;
    });
}

sub finish {
    my ($self, $summary) = @_;
    $self->{data}{state} = 'finished';
    $self->{data}{summary} = $summary if $summary;
    $self->_write;
}

1;
