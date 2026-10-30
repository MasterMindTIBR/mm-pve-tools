#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

my $tmp = tempdir('mm-pve-release-preflight-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $fake_gh = "$tmp/gh";
open(my $fh, '>', $fake_gh) or die "abrir fake gh: $!";
print {$fh} <<'SH';
#!/bin/sh
set -eu
endpoint=${2:-}
case "$FAKE_MODE:$endpoint" in
    missing:*) exit 1 ;;
    no-review:*/deployment-branch-policies)
        printf '%s\n' '{"branch_policies":[{"name":"master"}]}' ;;
    no-review:*/environments/production)
        printf '%s\n' '{"protection_rules":[]}' ;;
    no-master:*/deployment-branch-policies)
        printf '%s\n' '{"branch_policies":[{"name":"main"}]}' ;;
    no-master:*/environments/production)
        printf '%s\n' '{"protection_rules":[{"type":"required_reviewers","reviewers":[{"login":"reviewer"}]}]}' ;;
    correct:*/deployment-branch-policies)
        printf '%s\n' '{"branch_policies":[{"name":"master"}]}' ;;
    correct:*/environments/production)
        printf '%s\n' '{"protection_rules":[{"type":"required_reviewers","reviewers":[{"login":"reviewer"}]}]}' ;;
    *) exit 1 ;;
esac
SH
close $fh or die "fechar fake gh: $!";
chmod 0755, $fake_gh or die "chmod fake gh: $!";

my $script = "$Bin/../../scripts/release-preflight.sh";
sub run_case {
    my ($mode) = @_;
    local $ENV{RELEASE_PREFLIGHT_GH} = $fake_gh;
    local $ENV{FAKE_MODE} = $mode;
    local $ENV{GITHUB_REPOSITORY} = 'MasterMindTIBR/mm-pve-tools';
    my $output = qx{"$script" 2>&1};
    return ($? >> 8, $output);
}

my ($rc, $out) = run_case('missing');
is($rc, 1, 'ambiente ausente falha');
like($out, qr/ambiente production não existe/, 'ambiente ausente explica');

($rc, $out) = run_case('no-review');
is($rc, 1, 'ambiente sem reviewer falha');
like($out, qr/não possui required reviewer/, 'reviewer ausente explica');

($rc, $out) = run_case('no-master');
is($rc, 1, 'ambiente sem restrição master falha');
like($out, qr/não está restrito à branch master/, 'restrição ausente explica');

($rc, $out) = run_case('correct');
is($rc, 0, 'ambiente correto passa');
like($out, qr/preflight de release OK/, 'preflight correto confirma');

done_testing();
