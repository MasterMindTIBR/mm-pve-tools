#!/usr/bin/env bash
# Build the two Debian packages in the pinned Debian 13 environment.
set -euo pipefail

readonly DEBIAN_IMAGE="debian:13@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO_ROOT

lintian=0
in_container=0
for arg in "$@"; do
    case "$arg" in
        --lintian) lintian=1 ;;
        --in-container) in_container=1 ;;
        *)
            printf 'uso: %s [--lintian] [--in-container]\n' "$0" >&2
            exit 2
            ;;
    esac
done

if (( ! in_container )); then
    command -v docker >/dev/null 2>&1 || {
        printf 'docker não encontrado; use --in-container dentro de Debian 13\n' >&2
        exit 127
    }

    docker_args=(
        run --rm
        --user 0:0
        --volume "${REPO_ROOT}:/src"
        --workdir /src
        --env DEBIAN_FRONTEND=noninteractive
        --env "MM_PVE_BUILD_OWNER=$(id -u):$(id -g)"
        "${DEBIAN_IMAGE}"
        bash /src/scripts/build-deb.sh --in-container
    )
    (( lintian )) && docker_args+=(--lintian)
    exec docker "${docker_args[@]}"
fi

build_deps=(
    build-essential
    debhelper
    devscripts
    equivs
    lintian
    make
    perl
    python3
)
if command -v apt-get >/dev/null 2>&1 && {
    ! command -v dpkg-buildpackage >/dev/null 2>&1 ||
    ! command -v mk-build-deps >/dev/null 2>&1 ||
    ! command -v pod2man >/dev/null 2>&1 ||
    ! command -v lintian >/dev/null 2>&1;
}; then
    apt-get update -qq
    apt-get install -y --no-install-recommends "${build_deps[@]}"
fi

command -v dpkg-buildpackage >/dev/null 2>&1 || {
    printf 'dpkg-buildpackage não encontrado; instale as dependências Debian de build\n' >&2
    exit 127
}
command -v mk-build-deps >/dev/null 2>&1 || {
    printf 'mk-build-deps não encontrado; instale devscripts/equivs\n' >&2
    exit 127
}

workspace=$(mktemp -d "${TMPDIR:-/tmp}/mm-pve-build.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT
build_root="$workspace/source"
mkdir -p -- "$build_root"
tar --create --file=- --directory="$REPO_ROOT" \
    --exclude='./.git' \
    --exclude='./dist' \
    --exclude='./build' \
    --exclude='./debian/mm-pve-tools' \
    --exclude='./debian/mm-gw-restore' \
    --exclude='./debian/*.debhelper' \
    --exclude='./debian/*.substvars' \
    --exclude='./debian/*.debhelper.log' \
    --exclude='./debian/debhelper-build-stamp' \
    --exclude='*/__pycache__' \
    --exclude='*.pyc' \
    . | tar --extract --file=- --directory="$build_root"

rm -rf -- "${REPO_ROOT}/dist"
mkdir -p -- "${REPO_ROOT}/dist"

cd -- "$build_root"
mk-build-deps --install --remove --tool='apt-get -y --no-install-recommends' debian/control
rm -f -- ../mm-pve-tools_*.deb ../mm-gw-restore_*.deb ../mm-pve-tools_*.changes \
    ../mm-pve-tools_*.buildinfo
dpkg-buildpackage -us -uc -b

for package in mm-pve-tools mm-gw-restore; do
    deb=$(find .. -maxdepth 1 -type f -name "${package}_*.deb" -print -quit)
    if [[ -z "$deb" ]]; then
        printf 'build não produziu o pacote %s\n' "$package" >&2
        exit 1
    fi
    mv -- "$deb" "${REPO_ROOT}/dist/"
done

version=$(dpkg-parsechangelog -l debian/changelog -SVersion)
version=${version#*:}
version=${version%-*}
inspect_root="$workspace/inspect"
mkdir -p -- "$inspect_root"
for package in mm-pve-tools mm-gw-restore; do
    deb=$(find "${REPO_ROOT}/dist" -maxdepth 1 -type f -name "${package}_*.deb" -print -quit)
    dpkg-deb -x "$deb" "$inspect_root/$package"
done

leftovers=$(grep -R -a -l -F '@MM_PVE_VERSION@' "$inspect_root" || true)
if [[ -n "$leftovers" ]]; then
    printf 'placeholder de versão encontrado no pacote: %s\n' "$leftovers" >&2
    exit 1
fi
cli_version=$(awk -F"'" '/^our \$VERSION = / { print $2; exit }' \
    "$inspect_root/mm-pve-tools/usr/sbin/mm-pve")
js_version=$(sed -nE "s/.*version: '([^']+)'.*/\1/p" \
    "$inspect_root/mm-pve-tools/usr/share/pve-manager/js/mm-tools.js" | head -n 1)
if [[ "$cli_version" != "$version" || "$js_version" != "$version" ]]; then
    printf 'versão instalada divergente: changelog=%s cli=%s js=%s\n' \
        "$version" "$cli_version" "$js_version" >&2
    exit 1
fi
printf 'substituição de versão validada: %s\n' "$version"

if (( lintian )); then
    lintian --fail-on warning "${REPO_ROOT}"/dist/*.deb
fi

build_owner="${MM_PVE_BUILD_OWNER:-$(id -u):$(id -g)}"
chown -- "$build_owner" "${REPO_ROOT}/dist" \
    "${REPO_ROOT}"/dist/*.deb
printf 'pacotes gerados em %s/dist\n' "$REPO_ROOT"
