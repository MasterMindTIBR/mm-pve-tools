package MMPve::Module::Ui;

# Preferências de interface e override runtime do PVE. O arquivo estático é
# servido antes do login; preferências por usuário ficam separadas, com lock
# próprio, e nunca recebem um identificador vindo do cliente.

use strict;
use warnings;
use base qw(MMPve::Core::ModuleBase);

use JSON::PP qw(decode_json);
use MMPve::Core::Config;
use MMPve::Core::Util qw(root_path read_file write_file_atomic ensure_dir log_line json_encode);

our $VERSION = '@MM_PVE_VERSION@';

use constant {
    STATIC_PATH => '/usr/share/pve-manager/js/mm-ui.json',
    PVE_JS_PATH => '/usr/share/pve-manager/js/pvemanagerlib.js',
    PWT_JS_PATH => '/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js',
};

my %VIEWER = map { $_ => 1 } qw(default html5 xtermjs vv);

sub name { 'ui' }
sub static_path { root_path(STATIC_PATH) }
sub users_path { MMPve::Core::Config->config_dir . '/ui-users.json' }

sub _ui { return ref($_[1]) eq 'HASH' ? ($_[1]{ui} || {}) : {} }

sub _viewer_error {
    my ($where, $value) = @_;
    return "$where must be one of: default, html5, xtermjs, vv"
        unless defined $value && !ref($value) && $VIEWER{$value};
    return;
}

sub validate_section {
    my ($class, $cfg) = @_;
    return () unless ref($cfg) eq 'HASH' && exists $cfg->{ui};
    my @errors;
    my $u = $class->_ui($cfg);
    my $console = $u->{console};
    if (ref($console) ne 'HASH') {
        push @errors, 'ui.console must be an object';
    } else {
        for my $type (qw(qemu lxc)) {
            my $err = _viewer_error("ui.console.$type", $console->{$type});
            push @errors, $err if $err;
        }
    }
    if (exists $u->{hide_subscription_popup}) {
        my $v = $u->{hide_subscription_popup};
        push @errors, 'ui.hide_subscription_popup must be boolean'
            unless defined($v) && (!ref($v) ? ($v eq '0' || $v eq '1') : ref($v) =~ /Boolean/);
    }
    return @errors;
}

sub _desired_json {
    my ($class, $cfg) = @_;
    my $u = $class->_ui($cfg);
    my $console = $u->{console} || {};
    return {
        revision => 0 + ($cfg->{revision} // 1),
        console => {
            qemu => $console->{qemu} // 'default',
            lxc  => $console->{lxc}  // 'default',
        },
        hide_subscription_popup => $u->{hide_subscription_popup} ? 1 : 0,
    };
}

sub apply {
    my ($class, $cfg) = @_;
    my $want = json_encode($class->_desired_json($cfg), pretty => 1) . "\n";
    my $cur = eval { read_file($class->static_path) };
    my $changed = !defined($cur) || $cur ne $want;
    if ($changed) {
        ensure_dir(root_path('/usr/share/pve-manager/js'));
        write_file_atomic($class->static_path, $want, 0644);
        log_line('ui: static file applied');
    }
    return {
        ok => 1, changed => $changed ? 1 : 0,
        message => $changed ? 'ui applied on this node' : 'ui was already applied',
        static_path => STATIC_PATH,
    };
}

sub revert {
    my ($class) = @_;
    return { ok => 1, changed => 0, message => 'ui was already absent' }
        unless -e $class->static_path;
    unlink($class->static_path) or die "could not remove " . $class->static_path . ": $!\n";
    log_line('ui: static file removed');
    return { ok => 1, changed => 1, message => 'ui removed from this node' };
}

sub _symbol_state {
    my ($path, $symbols) = @_;
    my $out = { path => $path, exists => -f root_path($path) ? 1 : 0, symbols => {} };
    if ($out->{exists}) {
        my $raw = eval { read_file(root_path($path)) };
        $out->{readable} = $@ ? 0 : 1;
        for my $symbol (@{$symbols}) {
            $out->{symbols}{$symbol} = !$@ && defined($raw) && index($raw, $symbol) >= 0 ? 1 : 0;
        }
    } else {
        $out->{readable} = 0;
        $out->{symbols}{$_} = 0 for @{$symbols};
    }
    $out->{ok} = $out->{exists} && $out->{readable}
        && !grep { !$out->{symbols}{$_} } keys %{ $out->{symbols} };
    return $out;
}

sub check {
    my ($class, $cfg) = @_;
    my $enabled = ($cfg->{modules} || {})->{ui} ? 1 : 0;
    my $static = { path => STATIC_PATH, exists => -f $class->static_path ? 1 : 0 };
    if ($static->{exists}) {
        my $raw = eval { read_file($class->static_path) };
        my $data = eval { decode_json($raw) };
        $static->{ok} = !$@ && ref($data) eq 'HASH';
        $static->{revision} = $data->{revision} if $static->{ok};
    } else {
        $static->{ok} = 0;
    }
    my $pve = _symbol_state(PVE_JS_PATH, [qw(defaultViewer openDefaultConsoleWindow openConsoleWindow pveNoVncConsole pveConsoleButton)]);
    my $pwt = _symbol_state(PWT_JS_PATH, ['checked_command', 'No valid subscription']);
    my $ok = !$enabled || ($static->{ok} && $pve->{ok} && $pwt->{ok});
    return {
        ok => $ok ? 1 : 0,
        enabled => $enabled,
        applied => $static->{exists} ? 1 : 0,
        static => $static,
        bundles => { pve_manager => $pve, widget_toolkit => $pwt },
        note => $ok ? 'symbols and static file are compatible' : 'bundle or applied state is incompatible',
    };
}

sub _safe_user {
    my ($user) = @_;
    die "authenticated user is missing\n" unless defined $user && !ref($user) && length $user;
    ($user) = $user =~ /\A([^\x00-\x1f\x7f]{1,255})\z/;
    die "authenticated user is invalid\n" unless defined $user;
    return $user;
}

sub _read_users {
    my ($class) = @_;
    return {} unless -e $class->users_path;
    my $raw = read_file($class->users_path);
    my $data = eval { decode_json($raw) };
    die "invalid ui-users.json: $@\n" if $@ || ref($data) ne 'HASH';
    return $data;
}

sub _valid_preference {
    my ($type, $value) = @_;
    return if !defined $value || $value eq 'cluster';
    my $err = _viewer_error("$type preference", $value);
    die "$err\n" if $err;
}

sub get_user_preference {
    my ($class, $user) = @_;
    $user = _safe_user($user);
    return MMPve::Core::Config->with_domain_lock('ui-users', sub {
        my $all = $class->_read_users;
        my $pref = $all->{$user};
        return ref($pref) eq 'HASH' ? { %{$pref} } : {};
    });
}

sub save_user_preference {
    my ($class, $user, $input) = @_;
    $user = _safe_user($user);
    die "preference must be an object\n" unless ref($input) eq 'HASH';
    die "unknown preference field\n"
        if grep { $_ ne 'qemu' && $_ ne 'lxc' } keys %{$input};
    for my $type (qw(qemu lxc)) {
        _valid_preference($type, $input->{$type}) if exists $input->{$type};
    }
    return MMPve::Core::Config->with_domain_lock('ui-users', sub {
        my $all = $class->_read_users;
        my $pref = ref($all->{$user}) eq 'HASH' ? { %{ $all->{$user} } } : {};
        for my $type (qw(qemu lxc)) {
            next unless exists $input->{$type};
            if (!defined($input->{$type}) || $input->{$type} eq 'cluster') {
                delete $pref->{$type};
            } else {
                $pref->{$type} = $input->{$type};
            }
        }
        if (keys %{$pref}) { $all->{$user} = $pref } else { delete $all->{$user} }
        my $json = json_encode($all, pretty => 1) . "\n";
        ensure_dir(MMPve::Core::Config->config_dir);
        write_file_atomic($class->users_path, $json, 0644);
        return { %{$pref} };
    });
}

sub effective {
    my ($class, $cfg, $pref, $type) = @_;
    my $key = $type eq 'kvm' ? 'qemu' : $type;
    my $u = $class->_ui($cfg);
    my $user_value = $pref && defined $pref->{$key} ? $pref->{$key} : undef;
    $user_value = undef if defined($user_value) && $user_value eq 'cluster';
    return $user_value
        // ($u->{console} || {})->{$key} // 'default';
}

sub cli {
    my ($class, $argv) = @_;
    my ($qemu, $lxc, $hide, $show, $digest, $check, $help);
    local @ARGV = @{$argv};
    require Getopt::Long;
    Getopt::Long::GetOptions(
        'qemu=s' => \$qemu, 'lxc=s' => \$lxc,
        'hide-subscription-popup' => \$hide,
        'show-subscription-popup' => \$show,
        'digest=s' => \$digest, 'check' => \$check, 'help|h' => \$help,
    ) or return 2;
    if ($help) {
        print "usage: mm-pve ui set [--qemu default|html5|xtermjs|vv] [--lxc ...] "
            . "[--hide-subscription-popup|--show-subscription-popup]\n";
        print "       mm-pve ui check\n";
        return 0;
    }
    if ($check) {
        print json_encode($class->check(MMPve::Core::Config->load), pretty => 1), "\n";
        return 0;
    }
    die "use: mm-pve ui set [--qemu default|html5|xtermjs|vv] [--lxc ...] [--hide-subscription-popup|--show-subscription-popup]\n"
        unless @ARGV == 1 && $ARGV[0] eq 'set';
    die "use --hide-subscription-popup OR --show-subscription-popup\n"
        if $hide && $show;
    die "ui set requires a change\n"
        unless defined($qemu) || defined($lxc) || $hide || $show;
    my ($cfg, $cur_digest) = MMPve::Core::Config->load;
    my $ui = { %{ $cfg->{ui} || {} }, console => { %{ $cfg->{ui}{console} || {} } } };
    $ui->{console}{qemu} = $qemu if defined $qemu;
    $ui->{console}{lxc} = $lxc if defined $lxc;
    $ui->{hide_subscription_popup} = $hide ? 1 : 0 if $hide || $show;
    my %opt = defined($digest) ? (digest => $digest) : ();
    my ($saved, $new_digest) = eval { MMPve::Core::Config->save_section('ui', $ui, %opt) };
    if ($@) { chomp(my $error = $@); print STDERR "$error\n"; return 1 }
    print "ui saved (revision $saved->{revision})\ndigest: $new_digest\n";
    return 0;
}

1;
