#!/bin/sh
# Smoke estático dos símbolos que o override de UI reconhece. O bundle gerado
# nunca é inserido nos bundles upstream; estes arquivos são somente leitura.
set -u

[ "$#" -eq 4 ] || { echo "uso: $0 PINNED_PVE PINNED_PWT NEWEST_PVE NEWEST_PWT" >&2; exit 2; }

check_bundle() {
    path=$1
    label=$2
    [ -f "$path" ] || { echo "UI âncora falhou: $label ausente: $path" >&2; return 1; }
    shift 2
    for marker in "$@"; do
        grep -Fq -- "$marker" "$path" || {
            echo "UI âncora falhou: $label não contém '$marker'" >&2
            return 1
        }
    done
    echo "UI âncoras OK: $label ($path)"
    return 0
}

rc=0
check_bundle "$1" 'pinned pve-manager' \
    defaultViewer openDefaultConsoleWindow openConsoleWindow pveNoVncConsole pveConsoleButton \
    "Ext.define('PVE.pool.Config'" "alias: 'widget.pvePoolConfig'" || rc=1
check_bundle "$2" 'pinned proxmoxlib' \
    checked_command 'No valid subscription' || rc=1
check_bundle "$3" 'newest pve-manager' \
    defaultViewer openDefaultConsoleWindow openConsoleWindow pveNoVncConsole pveConsoleButton \
    "Ext.define('PVE.pool.Config'" "alias: 'widget.pvePoolConfig'" || rc=1
check_bundle "$4" 'newest proxmoxlib' \
    checked_command 'No valid subscription' || rc=1

[ "$rc" -eq 0 ] || exit 1
echo 'UI bundle anchors: pinned + newest OK'
