package MMPve::Module::Branding;

# Módulo branding — logo/favicon/título/textos (plano: "Módulo branding").
#
# Estado desejado: seção "branding" do config (pmxcfs) + imagens em
# /etc/pve/mm-tools/branding/ (pmxcfs). apply copia as imagens para
# /usr/share/pve-manager/images/mm-branding/ (servido pelo pveproxy em
# /pve2/images/mm-branding/) e grava /usr/share/pve-manager/js/mm-branding.json
# (servido em /pve2/js/mm-branding.json), lido pelo mm-tools.js no boot.
# revert apaga os dois — nenhum arquivo original do PVE é tocado.

use strict;
use warnings;
use base qw(MMPve::Core::ModuleBase);

use Digest::SHA ();
use File::Basename qw(basename);
use File::Copy qw(copy);
use MMPve::Core::Config;
use MMPve::Core::Util qw(
    root_path read_file write_file_atomic ensure_dir log_line
);

our $VERSION = '0.1.0';

use constant {
    IMAGES_DIR => '/usr/share/pve-manager/images/mm-branding',
    JSON_PATH  => '/usr/share/pve-manager/js/mm-branding.json',
};

my $MAX_BYTES = MMPve::Core::Config->can('MAX_BRANDING_BYTES')
    ? \&MMPve::Core::Config::MAX_BRANDING_BYTES
    : sub { 200 * 1024 };

sub images_dir { return root_path(IMAGES_DIR) }
sub json_path  { return root_path(JSON_PATH) }
sub branding_dir { return MMPve::Core::Config->branding_dir }

# ------------------------------------------------------------ assets

# Hash determinístico dos assets atuais: sha256 sobre
# "nome=sha256\n" de cada arquivo da branding_dir (ordenado).
sub assets_hash {
    my ($class) = @_;
    my $dir = branding_dir();
    my $concat = '';
    my @files;
    if (opendir(my $dh, $dir)) {
        @files = sort grep { !/^\./ && -f "$dir/$_" } readdir($dh);
        closedir($dh);
    }
    for my $f (@files) {
        my $data = eval { read_file("$dir/$f") };
        next if $@;
        $concat .= $f . '=' . Digest::SHA::sha256_hex($data) . "\n";
    }
    return 'sha256:' . Digest::SHA::sha256_hex($concat);
}

sub _short {
    my ($hash) = @_;
    return '' unless defined $hash;
    $hash =~ s/^sha256://;
    return substr($hash, 0, 10);
}

# Decodifica entidades numéricas/nomeadas comuns repetidamente (máx. 10
# rodadas) para pegar ofuscação tipo &lt;script&gt; ou &#x3C;script&#x3E;.
sub _decode_entities {
    my ($s) = @_;
    for (1 .. 10) {
        my $prev = $s;
        $s =~ s/&#x([0-9a-f]+);/chr(hex($1))/gie;
        $s =~ s/&#(\d+);/chr($1)/ge;
        $s =~ s/&lt;/</gi;
        $s =~ s/&gt;/>/gi;
        $s =~ s/&quot;/"/gi;
        $s =~ s/&amp;/&/gi;
        last if $s eq $prev;
    }
    return $s;
}

# Retorna () se o SVG é limpo; senão a razão (pt-BR).
sub svg_problem {
    my ($data) = @_;
    my $dec = _decode_entities($data);
    return 'SVG contém <script>'   if $dec =~ /<\s*script\b/i;
    return 'SVG contém </script>'  if $dec =~ /<\s*\/\s*script/i;
    return 'SVG contém handler on* (ex.: onclick)' if $dec =~ /\bon[a-z]+\s*=/i;
    return 'SVG contém URL javascript:' if $dec =~ /javascript\s*:/i;
    return 'SVG referencia recursos externos' if $dec =~ /\b(?:href|src)\s*=\s*["']?\s*(?:https?|data):/i;
    return '';
}

# Guarda um asset na branding_dir (pmxcfs). Valida extensão, tamanho e
# sanitização de SVG. Retorna {filename, size, sha256}. Die com mensagem
# pt-BR em erro.
sub store_asset {
    my ($class, %opt) = @_;
    my $kind = $opt{kind} // die "kind obrigatório (logo|favicon)\n";
    die "kind inválido '$kind'\n" unless $kind =~ /^(logo|favicon)$/;
    my $name = basename($opt{filename} // '');
    die "nome de arquivo inválido para $kind (use [A-Za-z0-9._-])\n"
        unless $name =~ /^[A-Za-z0-9._-]+$/ && $name !~ /^\./;
    die "$name: só .svg ou .png\n" unless $name =~ /\.(svg|png)$/i;
    my $ext = lc($1);

    my $data = $opt{data};
    die "$name: conteúdo ausente\n" unless defined $data && length $data;
    my $len = length $$data;
    die sprintf("%s: %d bytes excede o limite de %d bytes\n", $name, $len, $MAX_BYTES->())
        if $len > $MAX_BYTES->();
    if ($ext eq 'svg') {
        my $prob = svg_problem($$data);
        die "$name recusado: $prob (remova o conteúdo ativo e tente de novo; para CLI: mm-pve branding set --$kind $name)\n"
            if $prob;
    }

    ensure_dir(branding_dir());
    my $dest = branding_dir() . '/' . $name;
    write_file_atomic($dest, $$data, 0644);
    log_line("branding: asset $kind salvo ($name, $len bytes)");
    return {
        filename => $name,
        size     => $len,
        sha256   => 'sha256:' . Digest::SHA::sha256_hex($$data),
    };
}

sub store_asset_from_file {
    my ($class, %opt) = @_;
    my $path = $opt{path} // die "path obrigatório\n";
    my $data = read_file($path);    # die se não ler
    # usa o basename do arquivo enviado se não veio filename
    $opt{filename} //= basename($path);
    return $class->store_asset(%opt, data => \$data);
}

# ------------------------------------------------------------ contrato

sub validate_section {
    my ($class, $cfg) = @_;
    my @e;
    my $b = $cfg->{branding} or return ();
    # checagens de assets só valem com o módulo ligado (o config pode citar
    # um logo antes do upload, enquanto branding está desligado)
    return () unless ($cfg->{modules}{branding} // 0);
    my $dir = branding_dir();
    my $have = {};
    if (opendir(my $dh, $dir)) {
        $have->{$_} = 1 for grep { !/^\./ && -f "$dir/$_" } readdir($dh);
        closedir($dh);
    }
    for my $f (qw(logo favicon)) {
        my $v = $b->{$f} // next;
        next unless length $v;
        push @e, "branding.$f '$v' não existe em $dir — faça o upload antes de salvar (mm-pve branding set --$f $v)"
            unless $have->{$v};
    }
    if (defined $b->{assets_hash} && length $b->{assets_hash}) {
        my $cur = $class->assets_hash;
        push @e, "branding.assets_hash não confere com os arquivos de $dir (atual $cur) — reenvie as imagens ou limpe o campo (mm-pve branding clear)"
            if $cur ne $b->{assets_hash};
    }
    return @e;
}

sub _desired_json {
    my ($class, $cfg) = @_;
    my $b = $cfg->{branding};
    my $hash = $class->assets_hash;
    my $short = _short($hash);
    my %j = (
        title       => $b->{title}       // '',
        header_text => $b->{header_text} // '',
        login_text  => $b->{login_text}  // '',
        logo        => $b->{logo}        // '',
        favicon     => $b->{favicon}     // '',
        assets_hash => $hash,
    );
    $j{logo_url} = length $j{logo}
        ? '/pve2/images/mm-branding/' . $j{logo} . '?v=' . $short : '';
    $j{favicon_url} = length $j{favicon}
        ? '/pve2/images/mm-branding/' . $j{favicon} . '?v=' . $short : '';
    return \%j, $hash;
}

sub apply {
    my ($class, $cfg) = @_;
    my $b = $cfg->{branding} // {};
    my @wanted = grep { defined $b->{$_} && length $b->{$_} } qw(logo favicon);

    # sem branding configurado: garante estado limpo (idempotente)
    if (!@wanted && !length($b->{title} // '') && !length($b->{header_text} // '')
        && !length($b->{login_text} // '')) {
        my $r = $class->revert;
        return { ok => 1, changed => $r->{changed}, message => 'branding vazio: nada a aplicar' };
    }

    my $changed = 0;
    ensure_dir(images_dir());
    for my $f (@wanted) {
        my $src = branding_dir() . '/' . $b->{$f};
        my $dst = images_dir() . '/' . $b->{$f};
        die "branding.$f '$b->{$f}' não existe em " . branding_dir()
            . " — reenvie a imagem e salve de novo (mm-pve branding set --$f $b->{$f})\n"
            unless -f $src;
        my $same = (-f $dst && Digest::SHA::sha256_hex(read_file($src)) eq Digest::SHA::sha256_hex(read_file($dst)));
        if (!$same) {
            copy($src, $dst) or die "copiar $src -> $dst: $!\n";
            $changed = 1;
        }
    }

    # remove assets aplicados que saíram da configuração
    if (opendir(my $dh, images_dir())) {
        my %want = map { $b->{$_} => 1 } @wanted;
        for my $f (readdir($dh)) {
            next if $f =~ /^\./ || $want{$f};
            unlink(images_dir() . '/' . $f);
            $changed = 1;
        }
        closedir($dh);
    }

    my ($j, $hash) = $class->_desired_json($cfg);
    require JSON::PP;
    my $raw = JSON::PP->new->canonical->pretty->utf8->encode($j) . "\n";
    my $cur = eval { read_file(json_path()) };
    if (!defined $cur || $cur ne $raw) {
        ensure_dir(root_path('/usr/share/pve-manager/js'));
        write_file_atomic(json_path(), $raw, 0644);
        $changed = 1;
    }
    log_line("branding: aplicado (assets $hash)");
    return {
        ok      => 1,
        changed => $changed,
        message => $changed ? 'branding aplicado neste node' : 'branding já estava aplicado',
        assets_hash => $hash,
    };
}

sub revert {
    my ($class) = @_;
    my $changed = 0;
    if (-d images_dir()) {
        if (opendir(my $dh, images_dir())) {
            for my $f (readdir($dh)) {
                next if $f =~ /^\./;
                unlink(images_dir() . '/' . $f);
                $changed = 1;
            }
            closedir($dh);
        }
        rmdir(images_dir());
    }
    if (-f json_path()) {
        unlink(json_path());
        $changed = 1;
    }
    log_line('branding: revertido') if $changed;
    return {
        ok      => 1,
        changed => $changed,
        message => $changed ? 'branding removido deste node' : 'branding já estava ausente',
    };
}

sub check {
    my ($class, $cfg) = @_;
    my $b = $cfg->{branding} // {};
    my $cur = eval { read_file(json_path()) };
    my ($want) = $class->_desired_json($cfg);
    require JSON::PP;
    my $curj = defined $cur ? eval { JSON::PP::decode_json($cur) } : undef;
    my $applied = 0;
    if ($curj) {
        $applied = 1;
        for my $f (qw(logo favicon)) {
            my $n = $b->{$f} // '';
            if (length $n) {
                $applied = 0 unless -f images_dir() . '/' . $n;
            }
        }
        $applied = 0 unless ($curj->{assets_hash} // '') eq ($want->{assets_hash} // '');
    }
    return {
        ok          => 1,
        module      => 'branding',
        enabled     => ($cfg->{modules}{branding} ? 1 : 0),
        applied     => $applied,
        config_hash => $want->{assets_hash},
        current_hash => ($curj ? $curj->{assets_hash} : undef),
        json_path   => json_path(),
        images_dir  => images_dir(),
    };
}

# ------------------------------------------------------------ CLI

sub cli {
    my ($class, $av) = @_;
    my $sub = shift @{$av} // '';
    if ($sub eq 'set')     { return $class->_cli_set($av) }
    if ($sub eq 'clear')   { return $class->_cli_clear }
    if ($sub eq 'check') {
        my ($cfg) = MMPve::Core::Config->load;
        my $s = $class->check($cfg);
        printf "%-12s %s\n", $_, (defined $s->{$_} ? $s->{$_} : '-') for sort keys %$s;
        return 0;
    }
    print STDERR "uso: mm-pve branding set [--logo arq.svg] [--favicon arq.png] [--title T] [--header-text T] [--login-text T] [--json]\n";
    print STDERR "     mm-pve branding clear [--json]\n";
    print STDERR "     mm-pve branding check\n";
    return 2;
}

sub _cli_set {
    my ($class, $av) = @_;
    require Getopt::Long;
    my %opt;
    local $SIG{__WARN__} = sub { };
    Getopt::Long::GetOptionsFromArray($av, \%opt,
        'logo=s', 'favicon=s', 'title=s', 'header-text=s', 'login-text=s')
        or do { print STDERR "uso: mm-pve branding set [--logo arq] [--favicon arq] [--title T] [--header-text T] [--login-text T]\n"; return 2 };

    my ($cfg) = MMPve::Core::Config->load;
    $cfg->{branding} //= {};

    for my $f (qw(logo favicon)) {
        next unless defined $opt{$f};
        my $st = eval { $class->store_asset_from_file(kind => $f, path => $opt{$f}) };
        if ($@) { chomp(my $e = $@); print STDERR "$e\n"; return 1 }
        $cfg->{branding}{$f} = $st->{filename};
    }
    for my $t (qw(title header_text login_text)) {
        (my $cli = $t) =~ s/_/-/;
        $cfg->{branding}{$t} = $opt{$cli} if defined $opt{$cli};
    }
    $cfg->{branding}{assets_hash} = $class->assets_hash;

    my ($saved) = eval { MMPve::Core::Config->save($cfg) };
    if ($@) { chomp(my $e = $@); print STDERR "$e\n"; return 1 }

    my $res = eval { $class->apply($saved) };
    if ($@) { chomp(my $e = $@); print STDERR "$e\n"; return 1 }
    printf "branding salvo (revision %d) e %s\n", $saved->{revision}, $res->{message};
    return 0;
}

sub _cli_clear {
    my ($class) = @_;
    my ($cfg) = MMPve::Core::Config->load;
    $cfg->{branding} = {
        title => '', header_text => '', login_text => '',
        logo => '', favicon => '', assets_hash => '',
    };
    my ($saved) = eval { MMPve::Core::Config->save($cfg) };
    if ($@) { chomp(my $e = $@); print STDERR "$e\n"; return 1 }
    if (opendir(my $dh, branding_dir())) {
        for my $f (readdir($dh)) {
            next if $f =~ /^\./;
            unlink(branding_dir() . '/' . $f);
        }
        closedir($dh);
    }
    my $res = $class->revert;
    printf "branding limpo (revision %d); %s\n", $saved->{revision}, $res->{message};
    return 0;
}

1;
