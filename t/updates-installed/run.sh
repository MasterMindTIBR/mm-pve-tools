#!/bin/sh
# Prova fora da suíte: Debian 13, systemd real, repositório APT local e um
# pacote dummy que demora no postinst para permitir testar a reserva única.
set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
IMAGE='mm-pve-tools-updates-installed:debian13'
CONTAINER="mm-pve-updates-$$"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

if ! command -v docker >/dev/null 2>&1; then
    echo 'updates-installed requer Docker no ambiente do Visionary/CI' >&2
    exit 2
fi
if ! docker info >/dev/null 2>&1; then
    echo 'updates-installed não conseguiu acessar o daemon Docker' >&2
    exit 2
fi

docker build --pull=false -t "$IMAGE" -f - "$REPO" <<'DOCKERFILE'
FROM debian:13@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    dpkg-dev perl python3 systemd systemd-sysv ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY . /src
RUN install -m 0755 /src/bin/mm-pve /usr/sbin/mm-pve \
    && cp -a /src/lib/. /usr/share/perl5/ \
    && cp -a /src/perl/. /usr/share/perl5/ \
    && mkdir -p /etc/pve/mm-tools /var/log/mm-pve-tools/updates
DOCKERFILE
build_rc=$?
[ "$build_rc" -eq 0 ] || exit "$build_rc"

docker run -d --name "$CONTAINER" --privileged --cgroupns=host \
    --tmpfs /run --tmpfs /run/lock "$IMAGE" /sbin/init >/dev/null
run_rc=$?
[ "$run_rc" -eq 0 ] || exit "$run_rc"

for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" systemctl is-system-running >/dev/null 2>&1; then break; fi
    sleep 1
done
docker exec "$CONTAINER" /src/t/updates-installed/proof-in-container.sh
