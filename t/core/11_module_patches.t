#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);

use lib "$Bin/../../lib", "$Bin/../lib";
use MMPve::Core::Patch;
use MMPve::Core::Modules;
require "$Bin/../lib/TestPatchFixture.pm";

{
    package MMPve::Module::OtherPatchFixture;
    use strict;
    use warnings;
    sub name { return 'otherpatchfixture' }
}

{
    package MMPve::Module::ThirdPatchFixture;
    use strict;
    use warnings;
    sub name { return 'thirdpatchfixture' }
}

my $tmp = tempdir('mm-pve-module-patch-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $fixture = MMPve::Module::TestPatchFixture->patch_targets;
MMPve::Core::Patch->register_module('MMPve::Module::TestPatchFixture');

sub files_for {
    my ($root) = @_;
    return (
        "$root/usr/share/perl5/PVE/GuestHelpers.pm" => "package PVE::GuestHelpers;\nsub exec_hookscript { return; }\n1;\n",
        "$root/usr/share/perl5/PVE/AccessControl.pm" => "package PVE::AccessControl;\nsub add_vm_to_pool { return; }\n1;\n",
        "$root/usr/share/perl5/PVE/AbstractConfig.pm" => "package PVE::AbstractConfig;\nsub write_config { return; }\n1;\n",
        "$root/usr/share/perl5/PVE/Storage.pm" => "package PVE::Storage;\nsub vdisk_alloc { return; }\n1;\n",
        "$root/usr/share/perl5/PVE/API2/Pool.pm" => "package PVE::API2::Pool;\nsub register_method { return; }\n1;\n",
    );
}

sub fresh_root {
    my ($name) = @_;
    my $root = "$tmp/$name";
    my %files = files_for($root);
    for my $path (keys %files) {
        $path =~ s{/[^/]+\z}{};
        make_path($path);
    }
    my %contents = files_for($root);
    for my $path (keys %contents) {
        open(my $fh, '>', $path) or die "abrir $path: $!";
        print {$fh} $contents{$path};
        close($fh) or die "fechar $path: $!";
    }
    return $root;
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "ler $path: $!";
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

sub snapshots {
    my ($root) = @_;
    return map { $_ => slurp($_) } keys %{ { files_for($root) } };
}

subtest 'fixture de teste não entra no registro produtivo nem instala autostub' => sub {
    unlike(join(',', MMPve::Core::Modules->names), qr/testpatchfixture/,
        'fixture não está no registro produtivo');
    unlike(slurp("$Bin/../../debian/mm-pve-tools.install"), qr{lib-autostub|MMAutoStub},
        'stubs de compilação não são instalados');
    unlike(slurp("$Bin/../../debian/rules"), qr{lib-autostub|MMAutoStub},
        'regras de pacote não instalam stubs');
};

subtest 'módulo desligado não deixa patch; ligado aplica os quatro owners' => sub {
    my $root = fresh_root('on-off');
    local $ENV{MM_PVE_ROOT} = $root;
    my $off = MMPve::Core::Patch->apply(core => 0, active_modules => {}, no_restart => 1, syntax_check => 'never');
    ok($off->{ok}, 'desligado ok');
    my $on = MMPve::Core::Patch->apply(core => 0,
        active_modules => { testpatchfixture => 1 }, no_restart => 1, syntax_check => 'never');
    ok($on->{ok}, 'ligado ok') or diag explain $on;
    is($on->{modules}{'MMPve::Module::TestPatchFixture'}{changed}, 1, 'grupo mudou');
    is_deeply($on->{modules}{'MMPve::Module::TestPatchFixture'}{daemons},
        [qw(pve-ha-crm pve-ha-lrm pvedaemon pveproxy pvescheduler)], 'daemons declarados');
    my $status = MMPve::Core::Patch->check(core => 0);
    is($status->{abstract_config}{status}, 'applied', 'status do target de módulo');
    is($status->{abstract_config}{module}, 'MMPve::Module::TestPatchFixture', 'módulo no status');
    is($status->{abstract_config}{owner}, 'libpve-guest-common-perl', 'owner no status');
    for my $target (@{$fixture}) {
        like(slurp($root . $target->{path}), qr/\Q$target->{line}\E/, "$target->{id} aplicado");
    }
    my $off_again = MMPve::Core::Patch->apply(core => 0, active_modules => {}, no_restart => 1, syntax_check => 'never');
    ok($off_again->{ok}, 'desligar reverte');
    for my $target (@{$fixture}) {
        unlike(slurp($root . $target->{path}), qr/\Q$target->{line}\E/, "$target->{id} revertido");
    }
};

subtest 'upstream atualizado reaplica e âncora ausente não muda nada' => sub {
    my $root = fresh_root('upstream');
    local $ENV{MM_PVE_ROOT} = $root;
    my $first = MMPve::Core::Patch->apply(core => 0, active_modules => { testpatchfixture => 1 },
        no_restart => 1, syntax_check => 'never');
    ok($first->{ok}, 'primeiro apply');
    MMPve::Core::Patch->apply(core => 0, active_modules => {}, no_restart => 1, syntax_check => 'never');
    open(my $fh, '>>', $root . '/usr/share/perl5/PVE/GuestHelpers.pm') or die $!;
    print {$fh} "# upstream update\n";
    close($fh);
    my $reapply = MMPve::Core::Patch->apply(core => 0,
        active_modules => { testpatchfixture => 1 }, no_restart => 1, syntax_check => 'never');
    ok($reapply->{ok}, 'reaplica depois de update');
    like(slurp($root . '/usr/share/perl5/PVE/GuestHelpers.pm'), qr/upstream update/,
        'conteúdo upstream preservado');

    my $broken = fresh_root('missing-anchor');
    local $ENV{MM_PVE_ROOT} = $broken;
    my %before = snapshots($broken);
    my $path = $broken . '/usr/share/perl5/PVE/AccessControl.pm';
    my $raw = slurp($path);
    $raw =~ s/sub add_vm_to_pool/sub removed_anchor/;
    open($fh, '>', $path) or die $!;
    print {$fh} $raw;
    close($fh);
    my %changed_before = snapshots($broken);
    my $missing = MMPve::Core::Patch->apply(core => 0,
        active_modules => { testpatchfixture => 1 }, no_restart => 1, syntax_check => 'never');
    ok(!$missing->{ok}, 'âncora ausente é falha explícita');
    is_deeply({ snapshots($broken) }, { %changed_before }, 'nenhum arquivo muda com âncora ausente');
    ok($before{$path} ne slurp($path), 'fixture realmente ficou sem âncora');
};

subtest 'falha de perl -c reverte a transação' => sub {
    my $root = fresh_root('syntax-failure');
    local $ENV{MM_PVE_ROOT} = $root;
    my %before = snapshots($root);
    no warnings 'redefine';
    local *MMPve::Core::Patch::_perl_c = sub { return { ok => 0, rc => 1, err => 'falha perl -c simulada' } };
    my $result = MMPve::Core::Patch->apply(core => 0,
        active_modules => { testpatchfixture => 1 }, no_restart => 1, syntax_check => 'always');
    ok(!$result->{ok}, 'perl -c falha');
    is_deeply({ snapshots($root) }, { %before }, 'todos os arquivos voltam');
    my $status = MMPve::Core::Patch->check(core => 0);
    is($status->{guest_helpers}{status}, 'previous_failure', 'status mostra previous_failure');
};

subtest 'owner duplicado é recusado e o reload que falha reverte só o módulo' => sub {
    my $different_file = eval {
        MMPve::Core::Patch->register_targets('MMPve::Module::OtherPatchFixture', [{
            id => 'different_file', owner => 'libpve-guest-common-perl',
            path => '/usr/share/perl5/PVE/Other.pm', anchor => qr/^package /,
            line => '# different file', daemons => ['pvedaemon'], processes => ['pvedaemon'],
        }]);
        1;
    };
    ok($different_file, 'mesmo owner em arquivo diferente aceito');
    my $duplicate = eval {
        MMPve::Core::Patch->register_targets('MMPve::Module::ThirdPatchFixture', [{
            id => 'duplicate_file', owner => 'libpve-guest-common-perl',
            path => '/usr/share/perl5/PVE/Other.pm', anchor => qr/^package /,
            line => '# duplicate file', daemons => ['pvedaemon'], processes => ['pvedaemon'],
        }]);
        1;
    };
    ok(!$duplicate, 'arquivo duplicado recusado');
    like($@, qr/arquivo/, 'diagnóstico do arquivo duplicado');
    MMPve::Core::Patch->unregister_module('MMPve::Module::OtherPatchFixture');

    my $root = fresh_root('reload-failure');
    local $ENV{MM_PVE_ROOT} = $root;
    my @reloads;
    no warnings 'redefine';
    local *MMPve::Core::Patch::_restart_and_verify = sub {
        my ($class, $daemons) = @_;
        push @reloads, [@{$daemons}];
        return { ok => @reloads > 1 ? 1 : 0, daemons => [@{$daemons}]} ;
    };
    my $result = MMPve::Core::Patch->apply(core => 0,
        active_modules => { testpatchfixture => 1 }, no_restart => 0, syntax_check => 'never');
    ok(!$result->{ok}, 'daemon inativo falha o grupo');
    ok($result->{modules}{'MMPve::Module::TestPatchFixture'}{reverted}, 'grupo revertido');
    is(scalar(@reloads), 2, 'reload original e reload de recuperação');
    is_deeply($reloads[0], [qw(pve-ha-crm pve-ha-lrm pvedaemon pveproxy pvescheduler)],
        'reload cobre todos os daemons dos alvos');
    for my $target (@{$fixture}) {
        unlike(slurp($root . $target->{path}), qr/\Q$target->{line}\E/, "$target->{id} revertido após falha");
    }
};

subtest 'manifesto persistido permite remover pacote sem classe do módulo' => sub {
    my $root = fresh_root('package-removed');
    local $ENV{MM_PVE_ROOT} = $root;
    my $on = MMPve::Core::Patch->apply(core => 0,
        active_modules => { testpatchfixture => 1 }, no_restart => 1, syntax_check => 'never');
    ok($on->{ok}, 'aplicado antes da remoção');
    MMPve::Core::Patch->unregister_module('MMPve::Module::TestPatchFixture');
    my $removed = MMPve::Core::Patch->revert(core => 0, no_restart => 1, syntax_check => 'never');
    ok($removed->{ok}, 'revert sem classe do módulo');
    for my $target (@{$fixture}) {
        unlike(slurp($root . $target->{path}), qr/\Q$target->{line}\E/, "$target->{id} saiu na remoção");
    }
};

subtest 'reload pós-worker usa apenas daemons pendentes e recupera falha' => sub {
    MMPve::Core::Patch->register_module('MMPve::Module::TestPatchFixture');
    my $root = fresh_root('deferred-reload');
    local $ENV{MM_PVE_ROOT} = $root;
    my $applied = MMPve::Core::Patch->apply(core => 0,
        active_modules => { testpatchfixture => 1 }, no_restart => 1, syntax_check => 'never');
    ok($applied->{ok}, 'apply sem reload deixa pendência');
    my @reloads;
    no warnings 'redefine';
    local *MMPve::Core::Patch::_restart_and_verify = sub {
        my ($class, $daemons) = @_;
        push @reloads, [@{$daemons}];
        return { ok => @reloads > 1 ? 1 : 0, daemons => [@{$daemons}] };
    };
    my $verified = MMPve::Core::Patch->reload_verify;
    ok(!$verified->{ok}, 'falha do daemon chega ao comando pós-worker');
    ok($verified->{groups}[0]{reverted}, 'módulo pendente revertido');
    is(scalar(@reloads), 2, 'reload inicial e recuperação');
    is_deeply($reloads[0], [qw(pve-ha-crm pve-ha-lrm pvedaemon pveproxy pvescheduler)],
        'só os daemons declarados pelos alvos mudaram');
};

done_testing();
