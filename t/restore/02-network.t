#!/usr/bin/env perl
# Escolha de VLAN (tag de NIC com entrada em restore.vlans) e IP da VM
# (guest agent, IPv4 dentro do prefixo do gateway; sem agent → undef).
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json);

BEGIN { use_ok('MMPve::Module::Restore') }

my $R = 'MMPve::Module::Restore';
my $vlans = { 120 => { gw_ip => '10.20.120.250', prefix => 24 } };

# ---- pick_vlan
my $conf = {
    net0 => 'virtio=AA:BB,bridge=vmbr0',                 # sem tag
    net1 => 'virtio=CC:DD,bridge=vmbr1,tag=999',          # tag sem entrada
    net2 => 'virtio=EE:FF,bridge=vmbr1,tag=120',
};
is($R->pick_vlan($conf, $vlans), 120, 'tag com entrada em vlans');

# ordem numérica de NIC: net1 (999) não vale, net2 (120) sim
$conf = {
    net2 => 'virtio=EE,bridge=vmbr1,tag=120',
    net1 => 'bridge=vmbr1,tag=999',
};
is($R->pick_vlan($conf, $vlans), 120, 'ignora tag sem entrada');

eval { $R->pick_vlan({ net0 => 'bridge=vmbr0' }, $vlans) };
like($@, qr/nenhuma NIC/, 'sem NIC casada → erro');

# ---- ip_in_prefix
ok($R->ip_in_prefix('10.20.120.10', '10.20.120.250', 24), 'ip no prefixo /24');
ok(!$R->ip_in_prefix('10.20.121.10', '10.20.120.250', 24), 'ip fora do /24');
ok(!$R->ip_in_prefix('192.168.1.1', '10.20.120.250', 8), 'fora do /8');
ok(!$R->ip_in_prefix('não-ip', '10.20.120.250', 24), 'não-ip');

# ---- pick_vm_ip (formato do qga)
my $ifaces = { result => [
    { name => 'lo', 'ip-addresses' => [
        { 'ip-address-type' => 'ipv4', 'ip-address' => '127.0.0.1' }] },
    { name => 'eth0', 'ip-addresses' => [
        { 'ip-address-type' => 'ipv6', 'ip-address' => 'fe80::1' },
        { 'ip-address-type' => 'ipv4', 'ip-address' => '192.168.1.5' },
        { 'ip-address-type' => 'ipv4', 'ip-address' => '10.20.120.77' }] },
] };
is($R->pick_vm_ip($ifaces, '10.20.120.250', 24), '10.20.120.77',
    'escolhe IPv4 dentro do prefixo, ignora v6/loopback/outra rede');

# sem agent / sem IP válido
is($R->pick_vm_ip(undef, '10.20.120.250', 24), undef, 'sem agent → undef');
is($R->pick_vm_ip({ result => [] }, '10.20.120.250', 24), undef, 'sem interfaces → undef');
is($R->pick_vm_ip({ result => [
    { name => 'eth0', 'ip-addresses' => [
        { 'ip-address-type' => 'ipv4', 'ip-address' => '172.16.0.9' }] },
] }, '10.20.120.250', 24), undef, 'nenhum IPv4 no prefixo → undef');

done_testing();
