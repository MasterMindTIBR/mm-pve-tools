#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Encode qw(decode encode FB_CROAK);
use File::Find qw(find);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib', 'perl';
use MMPve::Core::Util qw(read_file json_encode);

sub raw_file {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "$path: $!";
    local $/;
    return <$fh>;
}

subtest 'backend message literals are ASCII' => sub {
    my @roots = qw(bin lib perl gateway scripts systemd debian);
    my @files;
    for my $root (@roots) {
        next unless -d $root;
        find({
            wanted => sub {
                return unless -f $_;
                return if $File::Find::name eq 'debian/changelog';
                return unless $File::Find::name =~ m{\.(?:pm|py|service|timer|conf|postinst|prerm|sh)\z}
                    || $File::Find::name =~ m{(?:^|/)bin/mm-pve\z}
                    || $File::Find::name =~ m{(?:^|/)lib/mm-pve-tools/apply-patches\z}
                    || $File::Find::name =~ m{(?:^|/)gateway/gw-restore\z};
                push @files, $File::Find::name;
            },
            no_chdir => 1,
        }, $root);
    }

    my @bad;
    for my $file (@files) {
        open(my $fh, '<:raw', $file) or die "$file: $!";
        my $pod = 0;
        my $doc = 0;
        my $line_no = 0;
        while (my $raw = <$fh>) {
            $line_no++;
            my $line = decode('UTF-8', $raw, FB_CROAK);
            $pod = 1 if $line =~ /^__END__\s*$/;
            next if $pod;
            if ($file =~ m{gateway/gw-restore\z} && $line =~ /(?:\"\"\"|''')/) {
                $doc = !$doc;
                next;
            }
            next if $doc;
            next unless $line =~ /[^\x00-\x7F]/;
            $line =~ s/#.*//;
            next unless $line =~ /[^\x00-\x7F]/ && $line =~ /\S/;
            push @bad, "$file:$line_no";
        }
        close($fh);
    }
    is_deeply(\@bad, [], 'no non-ASCII backend message/code literals') or diag join("\n", @bad);
};

subtest 'state, worker log, and API JSON preserve UTF-8 once' => sub {
    my $tmp = tempdir('mm-pve-rock4-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    local $ENV{MM_PVE_ROOT} = $tmp;
    local $ENV{MM_PVE_CONFIG_DIR} = "$tmp/etc/pve/mm-tools";

    require MMPve::Module::Updates;
    my $state_path = "$tmp/state.json";
    my $state = {
        vm_name => 'VM-ação',
        pool => 'produção',
        requested_by => 'joão@pve',
        message => 'already absent',
    };
    MMPve::Module::Updates::_write_json($state_path, $state);
    my $state_raw = read_file($state_path);
    unlike($state_raw, qr/jÃ|pÃ|invÃ/, 'state has no mojibake prefix')
        or diag unpack('H*', $state_raw);
    my $state_back = decode_json($state_raw);
    is($state_back->{vm_name}, 'VM-ação', 'state VM name round-trips');
    is($state_back->{pool}, 'produção', 'state pool round-trips');
    is($state_back->{requested_by}, 'joão@pve', 'state user round-trips');

    my $log_path = "$tmp/worker.log";
    MMPve::Module::Updates::_append_log($log_path,
        "gw-restore failed: saída for VM-ação pool=produção user=joão\@pve\n");
    my $log_raw = raw_file($log_path);
    my $expected_log = encode('UTF-8',
        "gw-restore failed: saída for VM-ação pool=produção user=joão\@pve\n\n");
    is($log_raw, $expected_log, 'worker log keeps gateway data encoded once');
    unlike($log_raw, qr/sa\xC3\x83|\xC3\x83\xC2/, 'worker log has no double encoding');

    my $api_wire = json_encode({
        vm => 'VM-ação', pool => 'produção', user => 'joão@pve',
    });
    my $api_back = decode_json($api_wire);
    is($api_back->{vm}, 'VM-ação', 'API VM name round-trips');
    is($api_back->{pool}, 'produção', 'API pool round-trips');
    is($api_back->{user}, 'joão@pve', 'API user round-trips');
    unlike($api_wire, qr/jÃ|pÃ|invÃ/, 'API wire has no double encoding');
};

subtest 'json_encode preserves scalar types' => sub {
    my $decoded_number = decode_json('{"from":1000,"ratio":1.5}');
    my $raw_bytes = encode('UTF-8', 'VM-ação');
    my $wire = json_encode({
        integer => 42,
        float => 3.25,
        from_json => $decoded_number->{from},
        ratio_from_json => $decoded_number->{ratio},
        true => JSON::PP::true,
        false => JSON::PP::false,
        numeric_text => '42',
        bytes_text => $raw_bytes,
    });

    like($wire, qr/"integer":42\b/, 'integer remains a JSON number');
    like($wire, qr/"float":3\.25\b/, 'float remains a JSON number');
    like($wire, qr/"from_json":1000\b/, 'decoded integer remains a JSON number');
    like($wire, qr/"ratio_from_json":1\.5\b/, 'decoded float remains a JSON number');
    like($wire, qr/"true":true\b/, 'JSON true remains a boolean');
    like($wire, qr/"false":false\b/, 'JSON false remains a boolean');
    like($wire, qr/"numeric_text":"42"/, 'numeric text remains text');
    ok(index($wire, '"bytes_text":"' . $raw_bytes . '"') >= 0,
        'UTF-8 bytes are encoded once');

    my $back = decode_json($wire);
    is($back->{integer}, 42, 'integer round-trips as a number');
    is($back->{float}, 3.25, 'float round-trips as a number');
    ok($back->{true}, 'true round-trips');
    ok(!$back->{false}, 'false round-trips');
    is($back->{numeric_text}, '42', 'numeric text round-trips as text');
    is($back->{bytes_text}, 'VM-ação', 'UTF-8 bytes round-trip once');
};

done_testing();
