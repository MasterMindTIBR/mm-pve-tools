package PVE::API2::MMTools::Branding;

# Endpoints do módulo branding sob /nodes/{node}/mm-tools/branding/...
#   GET  branding              config atual + estado aplicado (check)
#   PUT  branding/set          campos de texto (digest p/ CAS)
#   PUT  branding/upload       logo_b64/favicon_b64 (máx 200 KB; SVG sanitizado)

use strict;
use warnings;

use MIME::Base64 qw(decode_base64);
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;

use MMPve::Core::Config;
use MMPve::Module::Branding;

use base qw(PVE::RESTHandler);

my $b64_field = sub {
    my ($param, $field, $namefield, $kind) = @_;
    return unless defined $param->{$field};
    my $name = $param->{$namefield}
        // ($kind eq 'logo' ? 'logo.svg' : 'favicon.png');
    my $data = decode_base64($param->{$field});
    my $st = eval {
        MMPve::Module::Branding->store_asset(kind => $kind, filename => $name, data => \$data);
    };
    if ($@) {
        chomp(my $e = $@);
        raise_param_exc({ $field => $e });    # 400 com mensagem clara
    }
    return $st->{filename};
};


__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    permissions => { check => ['/', ['Sys.Audit']] },
    description => 'Branding: config atual e estado aplicado neste node.',
    protected => 0,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my ($cfg, $digest) = MMPve::Core::Config->load;
        my $state = MMPve::Module::Branding->check($cfg);
        return {
            branding => $cfg->{branding},
            digest => $digest // '',
            state => $state,
        };
    },
});

__PACKAGE__->register_method({
    name => 'set',
    path => 'set',
    method => 'PUT',
    permissions => { check => ['/', ['Sys.Modify']] },
    description => 'Salva os textos do branding (título, topo, login). Imagens vão pelo upload.',
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            digest => {
                type => 'string',
                description => 'sha256 do config atual (CAS).',
                pattern => '^sha256:[0-9a-f]{64}$',
                optional => 1,
            },
            title => {
                type => 'string', maxLength => 100, optional => 1,
                description => 'Título da aba (o nome do node é mantido).',
            },
            header_text => {
                type => 'string', maxLength => 60, optional => 1,
                description => 'Texto do topo no lugar de "Virtual Environment".',
            },
            login_text => {
                type => 'string', maxLength => 200, optional => 1,
                description => 'Texto extra na tela de login.',
            },
            clear => {
                type => 'boolean', optional => 1, default => 0,
                description => 'Zera toda a seção branding (restaurar padrão).',
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my ($cfg, $digest, $absent) = MMPve::Core::Config->load;
        if (!$absent && defined $param->{digest} && $param->{digest} ne ($digest // '')) {
            die PVE::Exception->new("DIGEST_MISMATCH: config mudou desde a leitura (atual ".($digest//'')."). Releia e salve de novo.\n");
        }
        if ($param->{clear}) {
            $cfg->{branding} = {
                title => '', header_text => '', login_text => '',
                logo => '', favicon => '', assets_hash => '',
            };
        } else {
            for my $f (qw(title header_text login_text)) {
                $cfg->{branding}{$f} = $param->{$f} if defined $param->{$f};
            }
        }
        $cfg->{branding}{assets_hash} = MMPve::Module::Branding->assets_hash;
        my %opt;
        $opt{digest} = $digest if defined $digest && !$absent;
        my ($saved) = MMPve::Core::Config->save($cfg, %opt);
        return { revision => $saved->{revision}, branding => $saved->{branding} };
    },
});

__PACKAGE__->register_method({
    name => 'upload',
    path => 'upload',
    method => 'PUT',
    permissions => { check => ['/', ['Sys.Modify']] },
    description => 'Envia logo/favicon (base64, máx 200 KB, só .svg/.png; SVG ativo é recusado).',
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            digest => {
                type => 'string',
                description => 'sha256 do config atual (CAS).',
                pattern => '^sha256:[0-9a-f]{64}$',
                optional => 1,
            },
            logo_b64 => {
                type => 'string', optional => 1,
                description => 'Logo (SVG/PNG) em base64.',
            },
            logo_name => {
                type => 'string', optional => 1,
                description => 'Nome do arquivo do logo (padrão logo.svg).',
            },
            favicon_b64 => {
                type => 'string', optional => 1,
                description => 'Favicon (SVG/PNG) em base64.',
            },
            favicon_name => {
                type => 'string', optional => 1,
                description => 'Nome do arquivo do favicon (padrão favicon.png).',
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        raise_param_exc({ logo_b64 => 'envie logo_b64 ou favicon_b64' })
            unless defined $param->{logo_b64} || defined $param->{favicon_b64};

        my ($cfg, $digest, $absent) = MMPve::Core::Config->load;
        if (!$absent && defined $param->{digest} && $param->{digest} ne ($digest // '')) {
            die PVE::Exception->new("DIGEST_MISMATCH: config mudou desde a leitura (atual ".($digest//'')."). Releia e salve de novo.\n");
        }

        my $logo = $b64_field->($param, 'logo_b64', 'logo_name', 'logo');
        my $fav  = $b64_field->($param, 'favicon_b64', 'favicon_name', 'favicon');
        $cfg->{branding}{logo} = $logo if defined $logo;
        $cfg->{branding}{favicon} = $fav if defined $fav;
        $cfg->{branding}{assets_hash} = MMPve::Module::Branding->assets_hash;

        my %opt;
        $opt{digest} = $digest if defined $digest && !$absent;
        my ($saved) = MMPve::Core::Config->save($cfg, %opt);
        return {
            revision => $saved->{revision},
            logo => $saved->{branding}{logo},
            favicon => $saved->{branding}{favicon},
            assets_hash => $saved->{branding}{assets_hash},
        };
    },
});

1;
