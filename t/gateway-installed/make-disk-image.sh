#!/usr/bin/env bash
# Gera uma imagem GPT+NTFS sem depender de PBS. Executado dentro do gateway
# privilegiado, depois que ntfs-3g/iproute2/util-linux foram instalados.
set -Eeuo pipefail

output=${1:?uso: make-disk-image.sh /caminho/disk.img}
mount_dir=$(mktemp -d /tmp/gw-restore-image.XXXXXX)
loop=''

create_partition_nodes() {
    local loop_name=${1##*/}
    local dev_file partition dev major minor node
    for dev_file in /sys/block/"$loop_name"/"$loop_name"p*/dev; do
        [ -f "$dev_file" ] || continue
        partition=$(dirname "$dev_file")
        partition=${partition##*/}
        dev=$(cat "$dev_file")
        major=${dev%%:*}
        minor=${dev#*:}
        node="/dev/$partition"
        # Loop partition minors are reassigned when a loop device is reused;
        # without udev an old node would point at the wrong device.
        if [ "$(stat -c '%t:%T' "$node" 2>/dev/null)" != "$(printf '%x:%x' "$major" "$minor")" ]; then
            rm -f "$node"
            mknod "$node" b "$major" "$minor"
        fi
    done
}

cleanup() {
    set +e
    if mountpoint -q "$mount_dir"; then
        umount "$mount_dir"
    fi
    if [ -n "$loop" ]; then
        losetup --detach "$loop" >/dev/null 2>&1 || true
    fi
    rmdir "$mount_dir" >/dev/null 2>&1 || true
}
trap cleanup EXIT

install -d -m 0755 "$(dirname "$output")"
rm -f "$output"
truncate -s 128M "$output"
printf 'label: gpt\n,96M,L\n' | sfdisk "$output" >/dev/null
loop=$(losetup --find --show --partscan "$output")
part="${loop}p1"
for _ in $(seq 1 20); do
    create_partition_nodes "$loop"
    [ -b "$part" ] && break
    udevadm settle >/dev/null 2>&1 || true
    sleep 0.1
done
[ -b "$part" ] || { echo "partição não apareceu: $part" >&2; exit 1; }
mkntfs --force --quick --label GWRESTORE "$part" >/dev/null
mount -t ntfs-3g "$part" "$mount_dir"
install -d -m 0755 "$mount_dir/Dados/ClienteA" "$mount_dir/Dados/ClienteB"
printf 'conteudo do cliente A\n' > "$mount_dir/Dados/ClienteA/a.txt"
printf 'conteudo do cliente B\n' > "$mount_dir/Dados/ClienteB/b.txt"
sync
umount "$mount_dir"
losetup --detach "$loop"
loop=''
