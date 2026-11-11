#!/bin/sh
# Smoke estático dos símbolos que o override de UI reconhece. O bundle gerado
# nunca é inserido nos bundles upstream; estes arquivos são somente leitura.
set -u

[ "$#" -eq 2 ] || [ "$#" -eq 4 ] || { echo "usage: $0 PVE PWT [NEWEST_PVE NEWEST_PWT]" >&2; exit 2; }

check_bundle() {
    path=$1
    label=$2
[ -f "$path" ] || { echo "UI anchor check failed: $label missing: $path" >&2; return 1; }
    shift 2
    for marker in "$@"; do
        grep -Fq -- "$marker" "$path" || {
            echo "UI anchor check failed: $label does not contain '$marker'" >&2
            return 1
        }
    done
    echo "UI anchors OK: $label ($path)"
    return 0
}

rc=0
check_pair() { # check_pair PVE PWT LABEL
    check_bundle "$1" "$3 pve-manager" \
        defaultViewer openDefaultConsoleWindow openConsoleWindow pveNoVncConsole pveConsoleButton \
        "Ext.define('PVE.pool.Config'" "alias: 'widget.pvePoolConfig'" || rc=1
    check_bundle "$2" "$3 proxmoxlib" \
        checked_command 'No valid subscription' || rc=1
}
if [ "$#" -eq 2 ]; then
    check_pair "$1" "$2" bundle
else
    check_pair "$1" "$2" pinned
    check_pair "$3" "$4" newest
fi

[ "$rc" -eq 0 ] || exit 1
echo 'UI bundle anchors OK'
