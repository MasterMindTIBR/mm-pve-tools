#!/bin/sh
# Harness GUI localhost-only. It deliberately runs in Playwright's pinned
# image; no PVE package or browser dependency is installed on the host.
set -u

IMAGE='mm-pve-tools-gui:playwright-1.49.1'
REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
ASSETS="$REPO/refs/upstream/pve-9.2.24"
EXPECT_FAIL=''

while [ "$#" -gt 0 ]; do
    case "$1" in
        --assets)
            [ "$#" -ge 2 ] || { echo 'uso: --assets DIR' >&2; exit 2; }
            ASSETS=$2
            shift 2
            ;;
        --expect-fail-with)
            [ "$#" -ge 2 ] || { echo 'uso: --expect-fail-with JS' >&2; exit 2; }
            EXPECT_FAIL=$2
            shift 2
            ;;
        *)
            echo "opção desconhecida: $1" >&2
            exit 2
            ;;
    esac
done

ASSETS=$(realpath -- "$ASSETS" 2>/dev/null) || {
    echo "assets ausentes: $ASSETS" >&2
    exit 2
}
if [ -n "$EXPECT_FAIL" ]; then
    EXPECT_FAIL=$(realpath -- "$EXPECT_FAIL" 2>/dev/null) || {
        echo "JS antigo ausente: $EXPECT_FAIL" >&2
        exit 2
    }
fi

[ -d "$ASSETS" ] || { echo "assets ausentes: $ASSETS" >&2; exit 2; }
[ -z "$EXPECT_FAIL" ] || [ -f "$EXPECT_FAIL" ] || {
    echo "JS antigo ausente: $EXPECT_FAIL" >&2
    exit 2
}

echo "GUI: building $IMAGE"
docker build --progress=plain -t "$IMAGE" -f "$REPO/t/gui/Dockerfile" "$REPO/t/gui" || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mm-pve-gui.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
OLD_JS_CONTAINER=''
if [ -n "$EXPECT_FAIL" ]; then
    cp "$EXPECT_FAIL" "$WORK/old-mm-tools.js" || exit 1
    OLD_JS_CONTAINER=/work/old-mm-tools.js
fi

set +e
echo 'GUI: starting isolated container (timeout 240s)'
timeout --foreground 240s docker run --rm --init --network=none --ipc=host \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e MM_GUI_ASSETS=/assets \
    -e MM_GUI_OLD_JS="$OLD_JS_CONTAINER" \
    -v "$REPO:/repo:ro" \
    -v "$ASSETS:/assets:ro" \
    -v "$WORK:/work" \
    "$IMAGE" python3 /repo/t/gui/harness.py
RC=$?
set -e

if [ -n "$EXPECT_FAIL" ]; then
    if [ "$RC" -eq 0 ]; then
        echo 'NEGATIVE FAIL: o JS antigo passou no harness' >&2
        exit 1
    fi
    echo "NEGATIVE OK: o JS antigo falhou como esperado (image $IMAGE)"
    exit 0
fi
exit "$RC"
