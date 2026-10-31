package PVE::API2::MMTools::Branding;

# Endpoints do módulo branding sob /nodes/{node}/mm-tools/branding/...
# Os writes de assets usam JSON e o mesmo limite calculado pelo cliente.

use strict;
use warnings;

use MIME::Base64 qw(decode_base64);
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;

use MMPve::Core::Config;
use MMPve::Module::Branding;

use base qw(PVE::RESTHandler);

my @REQUEST_FIELDS = qw(digest logo_b64 logo_name favicon_b64 favicon_name);

sub _request_payload {
    my ($param) = @_;
    my %payload;
    $payload{$_} = $param->{$_} for grep { defined $param->{$_} } @REQUEST_FIELDS;
    return \%payload;
}

sub _check_request_size {
    my ($param) = @_;
    my $payload = _request_payload($param);
    my $bytes = MMPve::Module::Branding->encoded_request_bytes($payload);
    return if $bytes <= MMPve::Module::Branding->request_limit;
    raise_param_exc({ request => sprintf(
        'requisição JSON excede %d bytes (recebidos %d; limite do pveproxy %d com margem %d)',
        MMPve::Module::Branding->request_limit, $bytes,
        MMPve::Module::Branding->proxy_request_limit,
        MMPve::Module::Branding->request_margin,
    ) });
}

sub _asset_from_param {
    my ($param, $field, $namefield, $kind) = @_;
    return unless defined $param->{$field};
    my $name = $param->{$namefield} // ($kind . '.png');
    my $data = decode_base64($param->{$field});
    my $asset = eval {
        MMPve::Module::Branding->inspect_asset(kind => $kind, filename => $name, data => $data);
    };
    if ($@) {
        chomp(my $error = $@);
        raise_param_exc({ $field => $error });
    }
    return $asset;
}

__PACKAGE__->register_method({
    name => 'index', path => '', method => 'GET', proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Audit']] },
    description => 'Branding: config atual e estado aplicado neste node.', protected => 0,
    parameters => { additionalProperties => 0, properties => { node => get_standard_option('pve-node') } },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my ($cfg, $digest) = MMPve::Core::Config->load;
        return {
            branding => $cfg->{branding}, digest => $digest // '',
            state => MMPve::Module::Branding->check($cfg),
        };
    },
});

__PACKAGE__->register_method({
    name => 'set', path => 'set', method => 'PUT', proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Modify']] },
    description => 'Salva a seção de textos do branding; clear restaura o padrão.', protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            digest => { type => 'string', optional => 1, pattern => '^sha256:[0-9a-f]{64}$' },
            title => { type => 'string', maxLength => 100, optional => 1 },
            header_text => { type => 'string', maxLength => 60, optional => 1 },
            login_text => { type => 'string', maxLength => 200, optional => 1 },
            clear => { type => 'boolean', optional => 1, default => 0 },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my ($cfg, $digest, $absent) = MMPve::Core::Config->load;
        my $clear = $param->{clear} ? 1 : 0;
        my $branding = $clear
            ? { title => '', header_text => '', login_text => '', logo => '', favicon => '', assets_hash => '' }
            : { %{ $cfg->{branding} || {} } };
        if (!$clear) {
            $branding->{$_} = $param->{$_} for grep { defined $param->{$_} } qw(title header_text login_text);
        }
        my %opt = (lock_domain => 'mm-branding');
        $opt{digest} = $param->{digest} if defined $param->{digest};
        $opt{before_write} = sub {
            my ($new_cfg) = @_;
            $new_cfg->{branding}{assets_hash} = $clear
                ? '' : MMPve::Module::Branding->assets_hash($new_cfg);
        };
        $opt{after_write} = sub { MMPve::Module::Branding->_gc_assets_locked($_[0]) };
        my ($saved, $new_digest) = MMPve::Core::Config->save_section('branding', $branding, %opt);
        return {
            revision => $saved->{revision}, digest => $new_digest,
            branding => $saved->{branding}, apply_queued => $clear,
        };
    },
});

__PACKAGE__->register_method({
    name => 'upload', path => 'upload', method => 'PUT', proxyto => 'node',
    permissions => { check => ['perm', '/', ['Sys.Modify']] },
    description => 'Envia PNGs em JSON base64; limite bruto 256 KiB por asset.', protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            digest => { type => 'string', optional => 1, pattern => '^sha256:[0-9a-f]{64}$' },
            logo_b64 => { type => 'string', optional => 1 },
            logo_name => { type => 'string', optional => 1 },
            favicon_b64 => { type => 'string', optional => 1 },
            favicon_name => { type => 'string', optional => 1 },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        raise_param_exc({ logo_b64 => 'envie logo_b64 ou favicon_b64' })
            unless defined $param->{logo_b64} || defined $param->{favicon_b64};
        _check_request_size($param);

        my $logo = _asset_from_param($param, 'logo_b64', 'logo_name', 'logo');
        my $favicon = _asset_from_param($param, 'favicon_b64', 'favicon_name', 'favicon');
        my ($cfg, $digest, $absent) = MMPve::Core::Config->load;
        my $branding = { %{ $cfg->{branding} || {} } };
        $branding->{logo} = $logo->{filename} if $logo;
        $branding->{favicon} = $favicon->{filename} if $favicon;
        my %opt = (lock_domain => 'mm-branding');
        $opt{digest} = $param->{digest} if defined $param->{digest};
        $opt{before_write} = sub {
            my ($new_cfg) = @_;
            MMPve::Module::Branding->_stage_asset_locked($_) for grep { $_ } ($logo, $favicon);
            $new_cfg->{branding}{assets_hash} = MMPve::Module::Branding->assets_hash($new_cfg);
        };
        $opt{after_write} = sub { MMPve::Module::Branding->_gc_assets_locked($_[0]) };
        my ($saved, $new_digest) = MMPve::Core::Config->save_section('branding', $branding, %opt);
        return {
            revision => $saved->{revision}, digest => $new_digest,
            logo => $saved->{branding}{logo}, favicon => $saved->{branding}{favicon},
            assets_hash => $saved->{branding}{assets_hash},
        };
    },
});

1;
