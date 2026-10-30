#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin";
use TestAPI;
use Test::More;

TestAPI::setup_inc();
my ($real, $why) = TestAPI::real_pve();
plan skip_all => "PVE real não disponível: $why" unless $real;

ok(eval { require PVE::API2::MMTools; 1 }, 'API MasterMind carrega com PVE real')
    or BAIL_OUT($@);
PVE::RESTHandler->validate_method_schemas();

my @classes = qw(
    PVE::API2::MMTools
    PVE::API2::MMTools::Renumber
    PVE::API2::MMTools::Restore
    PVE::API2::MMTools::Branding
);
my %methods;
for my $class (@classes) {
    my $attrs = $class->method_attributes;
    ok($attrs && @$attrs, "$class registrou métodos no RESTHandler real");
    for my $info (@$attrs) {
        next if $info->{subclass};
        my $name = "$class/$info->{path} [$info->{method}]";
        $methods{$name} = $info;
        my $check = $info->{permissions}{check};
        ok($check && $check->[0] eq 'perm' && $check->[1] eq '/',
            "$name usa perm real em /") or diag explain $info->{permissions};
        ok(!$info->{permissions}{user} || $info->{permissions}{user} ne 'all',
            "$name não usa user=all") or diag explain $info->{permissions};
        if ($info->{name} eq 'set' || $info->{name} eq 'upload') {
            ok($info->{parameters}{properties}{digest}{optional},
                "$name aceita digest ausente no primeiro write");
        }
    }
}

my ($publish) = grep { $_->{name} eq 'publish' } values %methods;
ok($publish->{returns}{properties}{result_key}, 'publish devolve result_key');
ok($publish->{returns}{properties}{upid}, 'publish ainda devolve UPID para TaskViewer');
my ($result) = grep { $_->{name} eq 'result' } values %methods;
is($result->{path}, 'results/{result_key}', 'rota usa results/{result_key}');
ok(!$result->{parameters}{properties}{upid}, 'rota não aceita upid');
like($result->{parameters}{properties}{result_key}{pattern}, qr/64/, 'result_key é hex opaco');

done_testing();
