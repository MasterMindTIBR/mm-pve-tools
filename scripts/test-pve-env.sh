#!/bin/bash
# Executa t/api dentro de Debian 13 com as bibliotecas Perl reais do PVE 9.2.
# O sandbox de desenvolvimento não tem Docker/rede; este script é a prova do
# Visionary/CI e não grava nada no checkout.
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
image='debian:13@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308'
key_url='https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg'
key_sha256='136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45'
tag="mm-pve-tools-api:${key_sha256:0:12}"

if ! command -v docker >/dev/null 2>&1; then
    echo 'test-api requer Docker no ambiente do Visionary/CI' >&2
    exit 2
fi
if ! docker info >/dev/null 2>&1; then
    echo 'test-api não conseguiu acessar o daemon Docker do Visionary/CI' >&2
    exit 2
fi

docker build --pull=false -t "$tag" - <<EOF
FROM $image
RUN apt-get update -qq && apt-get install -y --no-install-recommends ca-certificates curl
RUN curl -fsSL '$key_url' -o /tmp/proxmox-archive-keyring-trixie.gpg \\
    && echo '$key_sha256  /tmp/proxmox-archive-keyring-trixie.gpg' | sha256sum -c - \\
    && install -m 0644 /tmp/proxmox-archive-keyring-trixie.gpg /usr/share/keyrings/proxmox-archive-keyring-trixie.gpg \\
    && printf '%s\\n' 'deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring-trixie.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription' > /etc/apt/sources.list.d/pve.list
RUN apt-get update -qq && apt-get install -y --no-install-recommends perl make \\
    libpve-common-perl=9.2.5 libpve-access-control=9.1.2 libpve-cluster-perl=9.1.7 \\
    libpve-rs-perl=0.15.3 libpve-storage-perl=9.1.13 && rm -rf /var/lib/apt/lists/*
EOF

run_rc=0
docker run --rm -i -v "$repo_dir:/src:ro" "$tag" bash -s <<'CONTAINER' || run_rc=$?
set -euo pipefail
cd /src
perl -MPVE::RESTHandler -MPVE::RPCEnvironment -MPVE::JSONSchema -e '
for my $m (qw(PVE::RESTHandler PVE::RPCEnvironment PVE::JSONSchema)) {
    (my $f = $m) =~ s{::}{/}g;
    $f .= q{.pm};
    die "$m veio de stub\n" if ($INC{$f} // q{}) =~ m{/t/lib-stubs/};
}'
PERL5LIB=/src/lib:/src/perl prove -v -r t/api | tee /tmp/mm-pve-tools-api.tap
if grep -Eqi 'skipped|skip:' /tmp/mm-pve-tools-api.tap; then
    echo 't/api foi pulado; o ambiente real do PVE não foi validado' >&2
    exit 3
fi
files=$(sed -n 's/^Files=\([0-9][0-9]*\), Tests=\([0-9][0-9]*\).*/\1/p' /tmp/mm-pve-tools-api.tap)
tests=$(sed -n 's/^Files=\([0-9][0-9]*\), Tests=\([0-9][0-9]*\).*/\2/p' /tmp/mm-pve-tools-api.tap)
if [[ $files != 4 || -z $tests || $tests -eq 0 ]] || ! grep -qx 'All tests successful\.' /tmp/mm-pve-tools-api.tap; then
    echo 't/api não executou exatamente 4 arquivos com testes bem-sucedidos' >&2
    exit 4
fi
CONTAINER
docker image rm "$tag" >/dev/null 2>&1 || true
exit "$run_rc"
