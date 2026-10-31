#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use lib 'lib', 'perl';
use MMPve::Core::Config;
use MMPve::Module::Branding;

my $tmp = tempdir('mm-pve-branding-rock6-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";
$ENV{MM_PVE_ROOT} = $tmp;
$ENV{MM_PVE_DISABLE_CFS_LOCK} = 1;

sub png {
    my ($width) = @_;
    return "\x89PNG\r\n\x1a\n" . pack('N', 13) . 'IHDR'
        . pack('NNCCCCC', $width || 1, 1, 8, 6, 0, 0, 0) . pack('N', 0);
}

my $asset = MMPve::Module::Branding->inspect_asset(
    kind => 'logo', filename => 'logo.png', data => png(1));
my $orphan = MMPve::Module::Branding->inspect_asset(
    kind => 'logo', filename => 'orphan.png', data => png(2));

subtest 'PNG assinatura e IHDR; arquivo é content-addressed' => sub {
    like($asset->{filename}, qr/^[0-9a-f]{64}\.png$/, 'nome é sha256.png');
    eval { MMPve::Module::Branding->inspect_asset(kind => 'logo', filename => 'bad.png', data => png(0)) };
    ok(!$@, 'IHDR válido aceito');
    eval { MMPve::Module::Branding->inspect_asset(kind => 'logo', filename => 'bad.png', data => "\x89PNG\r\n\x1a\n" . ('x' x 40)) };
    like($@, qr/IHDR/, 'IHDR ausente recusado');
};

subtest 'limite exato da requisição e limite bruto' => sub {
    my $payload = { logo_b64 => 'A' x MMPve::Module::Branding->request_limit };
    ok(!MMPve::Module::Branding->request_fits($payload), 'request acima do bound é recusada');
    is(MMPve::Module::Branding->proxy_request_limit, 512 * 1024, 'limite é o do pveproxy');
    is(MMPve::Module::Branding->raw_asset_limit, 256 * 1024, 'PNG bruto limitado a 256 KiB');
    eval { MMPve::Module::Branding->inspect_asset(kind => 'logo', filename => 'big.png', data => png(1) . ('x' x (256 * 1024))) };
    like($@, qr/excede o limite/, 'PNG bruto acima do limite recusado');
};

subtest 'assets_hash ignora orphan staged' => sub {
    MMPve::Module::Branding->_stage_asset_locked($asset);
    my $cfg = MMPve::Core::Config->default;
    $cfg->{branding}{logo} = $asset->{filename};
    my $before = MMPve::Module::Branding->assets_hash($cfg);
    MMPve::Module::Branding->_stage_asset_locked($orphan);
    is(MMPve::Module::Branding->assets_hash($cfg), $before, 'orphan não altera integrity hash');
};

subtest 'falha de save deixa blob não referenciado para gc' => sub {
    my $cfg = MMPve::Core::Config->default;
    my $failed = eval {
        MMPve::Core::Config->save_section('branding', {
            %{$cfg->{branding}}, logo => $orphan->{filename},
        }, lock_domain => 'mm-branding', before_write => sub {
            my ($new_cfg) = @_;
            MMPve::Module::Branding->_stage_asset_locked($orphan);
            $new_cfg->{branding}{assets_hash} = MMPve::Module::Branding->assets_hash($new_cfg);
            die "falha simulada depois do stage\n";
        });
        1;
    };
    ok(!$failed, 'save falhou depois do stage');
    my ($loaded) = MMPve::Core::Config->load;
    isnt($loaded->{branding}{logo}, $orphan->{filename}, 'asset não ficou referenciado');
    utime(time - 901, time - 901, MMPve::Module::Branding->branding_dir . '/' . $orphan->{filename});
    my $deleted = MMPve::Module::Branding->gc(now => time);
    ok(grep { $_ eq $orphan->{filename} } @{$deleted}, 'gc remove orphan antigo');
};

subtest 'save_section preserva as outras seções' => sub {
    my $base = MMPve::Core::Config->default;
    $base->{restore}{max_sessions} = 77;
    MMPve::Core::Config->save($base);
    my ($saved) = MMPve::Core::Config->save_section('branding', {
        %{$base->{branding}}, title => 'Rock 6',
    });
    is($saved->{branding}{title}, 'Rock 6', 'branding mudou');
    is($saved->{restore}{max_sessions}, 77, 'restore não mudou');
    is($saved->{vmid_scheme}[0], undef, 'demais seções permanecem intactas');
};

subtest 'upload e gc concorrentes serializam no domínio mm-branding' => sub {
    pipe(my $read, my $write) or die "pipe: $!";
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        close $read;
        my $cfg = MMPve::Core::Config->load;
        my $ok = eval {
            MMPve::Core::Config->save_section('branding', {
                %{$cfg->{branding}}, logo => $asset->{filename},
            }, lock_domain => 'mm-branding', before_write => sub {
                my ($new_cfg) = @_;
                MMPve::Module::Branding->_stage_asset_locked($asset);
                syswrite($write, "1");
                select undef, undef, undef, 0.1;
                $new_cfg->{branding}{assets_hash} = MMPve::Module::Branding->assets_hash($new_cfg);
            });
            1;
        };
        close $write;
        exit($ok ? 0 : 1);
    }
    close $write;
    read($read, my $signal, 1);
    close $read;
    MMPve::Module::Branding->gc(now => time);
    waitpid($pid, 0);
    is($? >> 8, 0, 'upload concorrente terminou');
    my ($cfg) = MMPve::Core::Config->load;
    is($cfg->{branding}{logo}, $asset->{filename}, 'config referencia o asset staged');
    ok(-f MMPve::Core::Config->branding_dir . '/' . $asset->{filename}, 'gc não removeu upload referenciado');
};

subtest 'clear seguido de apply remove em todos os nodes' => sub {
    my $cfg = MMPve::Core::Config->load;
    $cfg->{branding}{logo} = $asset->{filename};
    $cfg->{branding}{assets_hash} = MMPve::Module::Branding->assets_hash($cfg);
    MMPve::Core::Config->save_section('branding', $cfg->{branding});
    for my $node (qw(node-a node-b)) {
        $ENV{MM_PVE_ROOT} = "$tmp/$node";
        ok(MMPve::Module::Branding->apply($cfg)->{ok}, "$node serve branding");
    }
    my $empty = { title => '', header_text => '', login_text => '', logo => '', favicon => '', assets_hash => '' };
    MMPve::Core::Config->save_section('branding', $empty, lock_domain => 'mm-branding');
    my $cleared = MMPve::Core::Config->load;
    for my $node (qw(node-a node-b)) {
        $ENV{MM_PVE_ROOT} = "$tmp/$node";
        MMPve::Module::Branding->apply($cleared);
        ok(!MMPve::Module::Branding->check($cleared)->{serves_asset}, "$node não serve asset após clear");
        ok(!-f "$tmp/$node/usr/share/pve-manager/images/mm-branding/$asset->{filename}", "$node removeu arquivo");
    }
};

done_testing();
