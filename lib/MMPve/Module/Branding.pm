package MMPve::Module::Branding;

# Branding é estado desejado em pmxcfs e uma cópia local servida pelo pveproxy.
# Assets são PNGs content-addressed; o arquivo de configuração só referencia
# blobs que já foram staged sob a trava mm-branding.

use strict;
use warnings;
use base qw(MMPve::Core::ModuleBase);

use Digest::SHA ();
use File::Basename qw(basename);
use File::Copy qw(copy);
use JSON::PP ();
use MMPve::Core::Config;
use MMPve::Core::Util qw(
    root_path read_file write_file_atomic ensure_dir log_line
);

our $VERSION = '@MM_PVE_VERSION@';

use constant {
    IMAGES_DIR => '/usr/share/pve-manager/images/mm-branding',
    JSON_PATH  => '/usr/share/pve-manager/js/mm-branding.json',
    GC_GRACE_SECONDS => 15 * 60,
};

sub images_dir  { return root_path(IMAGES_DIR) }
sub json_path   { return root_path(JSON_PATH) }
sub branding_dir { return MMPve::Core::Config->branding_dir }

sub raw_asset_limit       { return MMPve::Core::Config::MAX_BRANDING_BYTES() }
sub request_limit         { return MMPve::Core::Config::MAX_BRANDING_REQUEST_BYTES() }
sub proxy_request_limit   { return MMPve::Core::Config::PVE_PROXY_MAX_POST_BYTES() }
sub request_margin        { return MMPve::Core::Config::BRANDING_REQUEST_MARGIN_BYTES() }

sub _request_json {
    my ($class, $payload) = @_;
    die 'payload da requisição precisa ser objeto\n' unless ref $payload eq 'HASH';
    return JSON::PP->new->canonical->utf8->encode($payload);
}

sub encoded_request_bytes {
    my ($class, $payload) = @_;
    return length($class->_request_json($payload));
}

sub request_fits {
    my ($class, $payload) = @_;
    return $class->encoded_request_bytes($payload) <= $class->request_limit;
}

sub _asset_filename {
    my ($class, $hex) = @_;
    return "$hex.png";
}

sub _validate_png {
    my ($class, $data, $name) = @_;
    my $label = defined $name && length $name ? $name : 'arquivo';
    die "$label: tamanho excede o limite de " . $class->raw_asset_limit . " bytes\n"
        if length($data) > $class->raw_asset_limit;
    die "$label: conteúdo não é um PNG válido\n"
        unless substr($data, 0, 8) eq "\x89PNG\r\n\x1a\n";
    die "$label: PNG sem IHDR completo\n" if length($data) < 33;

    my $length = unpack('N', substr($data, 8, 4));
    die "$label: IHDR inválido\n"
        unless $length == 13 && substr($data, 12, 4) eq 'IHDR';
    my ($width, $height, $depth, $colour, $compression, $filter, $interlace)
        = unpack('NNCCCCC', substr($data, 16, 13));
    die "$label: dimensões IHDR inválidas\n" unless $width && $height;
    die "$label: profundidade IHDR inválida\n"
        unless $depth == 1 || $depth == 2 || $depth == 4 || $depth == 8 || $depth == 16;
    my %depths = (
        0 => { 1 => 1, 2 => 1, 4 => 1, 8 => 1, 16 => 1 },
        2 => { 8 => 1, 16 => 1 },
        3 => { 1 => 1, 2 => 1, 4 => 1, 8 => 1 },
        4 => { 8 => 1, 16 => 1 },
        6 => { 8 => 1, 16 => 1 },
    );
    die "$label: tipo IHDR inválido\n"
        unless exists $depths{$colour} && $depths{$colour}{$depth};
    die "$label: compressão/filtro/interlace IHDR inválidos\n"
        unless !$compression && !$filter && ($interlace == 0 || $interlace == 1);
    return 1;
}

sub inspect_asset {
    my ($class, %opt) = @_;
    my $kind = $opt{kind} // die "kind obrigatório (logo|favicon)\n";
    die "kind inválido '$kind'\n" unless $kind eq 'logo' || $kind eq 'favicon';
    my $submitted = basename($opt{filename} // ($kind . '.png'));
    die "$submitted: apenas PNG é aceito\n" unless $submitted =~ /\.png\z/i;
    die "nome de arquivo inválido para $kind\n"
        unless $submitted =~ /^[A-Za-z0-9._-]+$/ && $submitted !~ /^\./;
    my $data = $opt{data};
    $data = $$data if ref $data eq 'SCALAR';
    die "$submitted: conteúdo ausente\n" unless defined $data && !ref $data && length $data;
    $class->_validate_png($data, $submitted);
    my $hex = Digest::SHA::sha256_hex($data);
    return {
        kind => $kind, filename => $class->_asset_filename($hex),
        hash => 'sha256:' . $hex, sha256 => $hex, size => length($data), data => $data,
    };
}

sub _stage_asset_locked {
    my ($class, $asset) = @_;
    ensure_dir(branding_dir());
    my $dest = branding_dir() . '/' . $asset->{filename};
    if (-f $dest) {
        my $existing = read_file($dest);
        die "asset content-addressed inconsistente: $asset->{filename}\n"
            unless Digest::SHA::sha256_hex($existing) eq $asset->{sha256};
    } else {
        write_file_atomic($dest, $asset->{data}, 0644);
    }
    return { %{$asset}, path => $dest };
}

sub stage_asset {
    my ($class, %opt) = @_;
    my $asset = $class->inspect_asset(%opt);
    return MMPve::Core::Config->with_domain_lock('mm-branding', sub {
        return $class->_stage_asset_locked($asset);
    });
}

sub store_asset {
    my ($class, %opt) = @_;
    return $class->stage_asset(%opt);
}

sub store_asset_from_file {
    my ($class, %opt) = @_;
    my $path = $opt{path} // die "path obrigatório\n";
    my $data = read_file($path);
    $opt{filename} //= basename($path);
    return $class->stage_asset(%opt, data => $data);
}

sub _branding {
    my ($class, $cfg) = @_;
    return $cfg->{branding} if ref $cfg eq 'HASH' && ref $cfg->{branding} eq 'HASH';
    return $cfg if ref $cfg eq 'HASH';
    return {};
}

sub _referenced_assets {
    my ($class, $cfg) = @_;
    my $b = $class->_branding($cfg);
    my %refs;
    for my $field (qw(logo favicon)) {
        my $name = $b->{$field};
        $refs{$name} = 1 if defined $name && $name =~ /^[0-9a-f]{64}\.png$/;
    }
    return \%refs;
}

# A integridade inclui somente os blobs apontados pela seção branding. Um
# orphan staged não muda o resultado.
sub assets_hash {
    my ($class, $cfg) = @_;
    my $concat = '';
    my $dir = branding_dir();
    for my $name (sort keys %{ $class->_referenced_assets($cfg) }) {
        my $path = "$dir/$name";
        next unless -f $path;
        my $data = eval { read_file($path) };
        next if $@;
        $concat .= $name . '=' . Digest::SHA::sha256_hex($data) . "\n";
    }
    return 'sha256:' . Digest::SHA::sha256_hex($concat);
}

sub _short {
    my ($hash) = @_;
    return '' unless defined $hash;
    $hash =~ s/^sha256://;
    return substr($hash, 0, 10);
}

sub validate_section {
    my ($class, $cfg) = @_;
    my @errors;
    my $b = $cfg->{branding} || {};
    my $dir = branding_dir();
    for my $field (qw(logo favicon)) {
        my $name = $b->{$field};
        next unless defined $name && length $name;
        if ($name !~ /^[0-9a-f]{64}\.png$/) {
            push @errors, "branding.$field: asset precisa ser <sha256>.png";
            next;
        }
        my $path = "$dir/$name";
        if (!-f $path) {
            push @errors, "branding.$field '$name' não existe em $dir";
            next;
        }
        my $data = eval { read_file($path) };
        if ($@) {
            push @errors, "branding.$field '$name' não pôde ser lido";
            next;
        }
        my $hex = Digest::SHA::sha256_hex($data);
        push @errors, "branding.$field '$name' não confere com o conteúdo"
            unless $hex eq substr($name, 0, 64);
        eval { $class->_validate_png($data, $name); 1 }
            or push @errors, $@;
    }
    if (defined $b->{assets_hash} && length $b->{assets_hash}) {
        my $cur = $class->assets_hash($cfg);
        push @errors, "branding.assets_hash não confere com os assets referenciados"
            if $cur ne $b->{assets_hash};
    } elsif (grep { defined $b->{$_} && length $b->{$_} } qw(logo favicon)) {
        push @errors, 'branding.assets_hash obrigatório quando há asset';
    }
    return @errors;
}

sub _desired_json {
    my ($class, $cfg) = @_;
    my $b = $cfg->{branding} || {};
    my $hash = $class->assets_hash($cfg);
    my $short = _short($hash);
    my %json = (
        title => $b->{title} // '', header_text => $b->{header_text} // '',
        login_text => $b->{login_text} // '', logo => $b->{logo} // '',
        favicon => $b->{favicon} // '', assets_hash => $hash,
    );
    $json{logo_url} = length $json{logo}
        ? '/pve2/images/mm-branding/' . $json{logo} . '?v=' . $short : '';
    $json{favicon_url} = length $json{favicon}
        ? '/pve2/images/mm-branding/' . $json{favicon} . '?v=' . $short : '';
    return (\%json, $hash);
}

sub _gc_assets_locked {
    my ($class, $cfg, %opt) = @_;
    my %referenced = %{ $class->_referenced_assets($cfg) };
    my $now = defined $opt{now} ? $opt{now} : time;
    my @deleted;
    my $dir = branding_dir();
    return \@deleted unless opendir(my $dh, $dir);
    while (my $name = readdir($dh)) {
        next unless $name =~ /^[0-9a-f]{64}\.png$/;
        next if $referenced{$name};
        my @st = stat "$dir/$name";
        next unless @st && defined $st[9] && $now - $st[9] >= GC_GRACE_SECONDS;
        if (unlink "$dir/$name") { push @deleted, $name }
    }
    closedir($dh);
    return \@deleted;
}

sub gc {
    my ($class, %opt) = @_;
    return MMPve::Core::Config->with_domain_lock('mm-branding', sub {
        my ($cfg) = MMPve::Core::Config->load;
        return $class->_gc_assets_locked($cfg, %opt);
    });
}

sub apply {
    my ($class, $cfg) = @_;
    my $b = $cfg->{branding} || {};
    my @wanted = grep { defined $b->{$_} && length $b->{$_} } qw(logo favicon);
    if (!@wanted && !length($b->{title} // '') && !length($b->{header_text} // '')
        && !length($b->{login_text} // '')) {
        my $r = $class->revert;
        return { ok => 1, changed => $r->{changed}, message => 'branding vazio: nada a aplicar' };
    }

    my $changed = 0;
    ensure_dir(images_dir());
    for my $field (@wanted) {
        my $name = $b->{$field};
        my $src = branding_dir() . '/' . $name;
        my $dst = images_dir() . '/' . $name;
        die "branding.$field '$name' não existe em " . branding_dir() . "\n" unless -f $src;
        my $same = -f $dst
            && Digest::SHA::sha256_hex(read_file($src)) eq Digest::SHA::sha256_hex(read_file($dst));
        if (!$same) { copy($src, $dst) or die "copiar $src -> $dst: $!\n"; $changed = 1 }
    }
    if (opendir(my $dh, images_dir())) {
        my %want = map { $b->{$_} => 1 } @wanted;
        while (my $name = readdir($dh)) {
            next if $name =~ /^\./ || $want{$name};
            unlink(images_dir() . '/' . $name);
            $changed = 1;
        }
        closedir($dh);
    }

    my ($json, $hash) = $class->_desired_json($cfg);
    my $raw = JSON::PP->new->canonical->pretty->utf8->encode($json) . "\n";
    my $cur = eval { read_file(json_path()) };
    if (!defined $cur || $cur ne $raw) {
        ensure_dir(root_path('/usr/share/pve-manager/js'));
        write_file_atomic(json_path(), $raw, 0644);
        $changed = 1;
    }
    log_line("branding: aplicado (assets $hash)");
    return {
        ok => 1, changed => $changed,
        message => $changed ? 'branding aplicado neste node' : 'branding já estava aplicado',
        assets_hash => $hash,
    };
}

sub revert {
    my ($class) = @_;
    my $changed = 0;
    if (-d images_dir() && opendir(my $dh, images_dir())) {
        while (my $name = readdir($dh)) {
            next if $name =~ /^\./;
            unlink(images_dir() . '/' . $name);
            $changed = 1;
        }
        closedir($dh);
        rmdir(images_dir());
    }
    if (-f json_path()) { unlink(json_path()); $changed = 1 }
    log_line('branding: revertido') if $changed;
    return { ok => 1, changed => $changed,
        message => $changed ? 'branding removido deste node' : 'branding já estava ausente' };
}

sub check {
    my ($class, $cfg) = @_;
    my $b = $cfg->{branding} || {};
    my $modules = $cfg->{modules} || {};
    my $cur = eval { read_file(json_path()) };
    my ($want) = $class->_desired_json($cfg);
    my $curj = defined $cur ? eval { JSON::PP::decode_json($cur) } : undef;
    my $applied = 0;
    if ($curj) {
        $applied = 1;
        for my $field (qw(logo favicon)) {
            my $name = $b->{$field} // '';
            $applied = 0 if length($name) && !-f images_dir() . '/' . $name;
        }
        $applied = 0 unless ($curj->{assets_hash} // '') eq ($want->{assets_hash} // '');
    }
    my $serves_asset = $applied && grep { defined $b->{$_} && length $b->{$_} } qw(logo favicon);
    return {
        ok => 1, module => 'branding', enabled => ($modules->{branding} ? 1 : 0),
        applied => $applied ? 1 : 0, serves_asset => $serves_asset ? 1 : 0,
        config_hash => $want->{assets_hash}, current_hash => ($curj ? $curj->{assets_hash} : undef),
        json_path => json_path(), images_dir => images_dir(),
    };
}

sub _save_section {
    my ($class, $branding, %opt) = @_;
    return MMPve::Core::Config->save_section('branding', $branding,
        lock_domain => 'mm-branding', %opt);
}

sub cli {
    my ($class, $av) = @_;
    my $sub = shift @{$av} // '';
    if ($sub eq 'set') { return $class->_cli_set($av) }
    if ($sub eq 'clear') { return $class->_cli_clear }
    if ($sub eq 'check') {
        my ($cfg) = MMPve::Core::Config->load;
        my $state = $class->check($cfg);
        printf "%-14s %s\n", $_, (defined $state->{$_} ? $state->{$_} : '-') for sort keys %$state;
        return 0;
    }
    print STDERR "uso: mm-pve branding set [--logo arq.png] [--favicon arq.png] [--title T] [--header-text T] [--login-text T]\n";
    print STDERR "     mm-pve branding clear\n     mm-pve branding check\n";
    return 2;
}

sub _cli_set {
    my ($class, $av) = @_;
    require Getopt::Long;
    my %opt;
    local $SIG{__WARN__} = sub { };
    Getopt::Long::GetOptionsFromArray($av, \%opt,
        'logo=s', 'favicon=s', 'title=s', 'header-text=s', 'login-text=s')
        or do { print STDERR "uso: mm-pve branding set [--logo arq.png] [--favicon arq.png] [--title T] [--header-text T] [--login-text T]\n"; return 2 };

    my ($cfg, $digest, $absent) = MMPve::Core::Config->load;
    my $branding = { %{ $cfg->{branding} || {} } };
    my @assets;
    for my $field (qw(logo favicon)) {
        next unless defined $opt{$field};
        my $data = read_file($opt{$field});
        my $asset = eval { $class->inspect_asset(kind => $field, filename => $opt{$field}, data => $data) };
        if ($@) { chomp(my $e = $@); print STDERR "$e\n"; return 1 }
        push @assets, $asset;
        $branding->{$field} = $asset->{filename};
    }
    for my $field (qw(title header_text login_text)) {
        (my $cli = $field) =~ s/_/-/;
        $branding->{$field} = $opt{$cli} if defined $opt{$cli};
    }
    my %save_opt;
    $save_opt{digest} = $digest if defined $digest && !$absent;
    $save_opt{before_write} = sub {
        my ($new_cfg) = @_;
        $class->_stage_asset_locked($_) for @assets;
        $new_cfg->{branding}{assets_hash} = $class->assets_hash($new_cfg);
    };
    $save_opt{after_write} = sub { $class->_gc_assets_locked($_[0]) };
    my ($saved) = eval { $class->_save_section($branding, %save_opt) };
    if ($@) { chomp(my $e = $@); print STDERR "$e\n"; return 1 }
    my $res = eval { $class->apply($saved) };
    if ($@) { chomp(my $e = $@); print STDERR "$e\n"; return 1 }
    printf "branding salvo (revision %d) e %s\n", $saved->{revision}, $res->{message};
    return 0;
}

sub _cli_clear {
    my ($class) = @_;
    my ($cfg, $digest, $absent) = MMPve::Core::Config->load;
    my $empty = { title => '', header_text => '', login_text => '', logo => '', favicon => '', assets_hash => '' };
    my %opt = (after_write => sub { $class->_gc_assets_locked($_[0]) });
    $opt{digest} = $digest if defined $digest && !$absent;
    my ($saved) = eval { $class->_save_section($empty, %opt) };
    if ($@) { chomp(my $e = $@); print STDERR "$e\n"; return 1 }
    my $res = eval { $class->apply($saved) };
    if ($@) { chomp(my $e = $@); print STDERR "$e\n"; return 1 }
    printf "branding limpo (revision %d); %s\n", $saved->{revision}, $res->{message};
    return 0;
}

1;
