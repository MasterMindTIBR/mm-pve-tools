#!/usr/bin/env bash
# fetch-pve-debs.sh: baixa e extrai pacotes do pve-no-subscription (trixie)
# com a mesma verificação do apt, para os jobs do CI que precisam de arquivos
# reais do PVE.
#
#   scripts/fetch-pve-debs.sh DIR PACOTE=VERSÃO|PACOTE=latest|PACOTE=oldest...
#
# O espelho é acessado por HTTP, como no sources.list da documentação do PVE:
# a confiança vem da assinatura do InRelease (chave conferida pelo sha256),
# do SHA256 do Packages listado no InRelease e do SHA256 de cada .deb listado
# no Packages. Cada pacote é extraído em DIR/x/<pacote>; a saída padrão lista
# "pacote<TAB>versão" de cada um.
set -euo pipefail

readonly MIRROR=http://download.proxmox.com/debian/pve
readonly SUITE=trixie
readonly COMPONENT=pve-no-subscription
readonly KEY_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
readonly KEY_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45

die() {
    printf 'fetch-pve-debs: %s\n' "$*" >&2
    exit 1
}

# O CDN da Proxmox às vezes responde 404 ou erro de rede por alguns segundos.
fetch() {
    curl --fail --silent --show-error --location \
        --connect-timeout 20 --retry 5 --retry-delay 10 --retry-all-errors \
        -o "$2" "$1"
}

(( $# >= 2 )) || die "usage: $0 DIR PACKAGE=VERSION|PACKAGE=latest..."
dir=$1
shift
for spec in "$@"; do
    [[ $spec =~ ^[a-z0-9][a-z0-9.+-]*=(oldest|latest|[A-Za-z0-9.+:~-]+)$ ]] || die "invalid package: $spec"
done

mkdir -p "$dir/meta" "$dir/debs" "$dir/x"

fetch "$KEY_URL" "$dir/meta/keyring.gpg"
printf '%s  %s\n' "$KEY_SHA256" "$dir/meta/keyring.gpg" | sha256sum --check --quiet - \
    || die "Proxmox keyring has an unexpected sha256"
gpg --batch --quiet --dearmor < "$dir/meta/keyring.gpg" > "$dir/meta/keyring.bin"

fetch "$MIRROR/dists/$SUITE/InRelease" "$dir/meta/InRelease"
gpgv --quiet --keyring "$dir/meta/keyring.bin" --output "$dir/meta/Release" \
    "$dir/meta/InRelease" 2>/dev/null || die "invalid InRelease signature"

fetch "$MIRROR/dists/$SUITE/$COMPONENT/binary-amd64/Packages" "$dir/meta/Packages"

python3 - "$dir/meta/Release" "$dir/meta/Packages" "$COMPONENT/binary-amd64/Packages" "$@" \
    > "$dir/meta/selected.tsv" <<'PY'
import hashlib
import re
import subprocess
import sys

release_path, packages_path, packages_name, *specs = sys.argv[1:]

expected = None
in_sha256 = False
for line in open(release_path, encoding="utf-8"):
    if not line.startswith(" "):
        in_sha256 = line.startswith("SHA256:")
        continue
    if in_sha256:
        digest, _size, name = line.split()
        if name == packages_name:
            expected = digest
if expected is None:
    sys.exit(f"{packages_name} is not in InRelease")
data = open(packages_path, "rb").read()
if hashlib.sha256(data).hexdigest() != expected:
    sys.exit(f"{packages_name}: sha256 differs from InRelease")

wanted = dict(spec.split("=", 1) for spec in specs)
chosen = {}
for stanza in re.split(r"\n\s*\n", data.decode("utf-8")):
    fields = dict(
        line.split(": ", 1)
        for line in stanza.splitlines()
        if ": " in line and not line.startswith((" ", "\t"))
    )
    package = fields.get("Package")
    if package not in wanted or not {"Version", "Filename", "SHA256"} <= fields.keys():
        continue
    if wanted[package] not in ("latest", "oldest"):
        if fields["Version"] == wanted[package]:
            chosen[package] = fields
        continue
    # "oldest" is the oldest stable release: pre-releases (a "~" in the
    # version, e.g. 9.0.0~8) never satisfy the package Depends (>= 9.0).
    if wanted[package] == "oldest" and "~" in fields["Version"]:
        continue
    current = chosen.get(package)
    relation = "gt" if wanted[package] == "latest" else "lt"
    if current is None or subprocess.run(
        ["dpkg", "--compare-versions", fields["Version"], relation, current["Version"]],
        check=False,
    ).returncode == 0:
        chosen[package] = fields

missing = [f"{name}={version}" for name, version in wanted.items() if name not in chosen]
if missing:
    sys.exit("package(s) missing from Packages: " + ", ".join(missing))
for package in wanted:
    item = chosen[package]
    print(f"{package}\t{item['Version']}\t{item['Filename']}\t{item['SHA256']}")
PY

while IFS=$'\t' read -r package version filename sha256; do
    deb="$dir/debs/$package.deb"
    fetch "$MIRROR/$filename" "$deb"
    printf '%s  %s\n' "$sha256" "$deb" | sha256sum --check --quiet - \
        || die "$package $version: sha256 differs from Packages"
    rm -rf "${dir:?}/x/$package"
    dpkg-deb -x "$deb" "$dir/x/$package"
    printf '%s\t%s\n' "$package" "$version"
done < "$dir/meta/selected.tsv"
