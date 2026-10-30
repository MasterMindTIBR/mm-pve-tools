#!/usr/bin/env bash
# Prova instalada do Rock 2: Debian 13 bootado, dependências reais e PBS
# substituído somente por t/gateway-installed/fake-pbs-client.
set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "$script_dir/../.." && pwd)
container_name=${GW_ROCK2_CONTAINER:-mm-gw-restore-rock2-$$}
test_image=${GW_ROCK2_IMAGE:-mm-gw-restore-rock2-image-$$}
tmp_dir=$(mktemp -d /tmp/mm-gw-restore-rock2.XXXXXX)
readonly debian_image='debian:13@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308'

die() { echo "FALHA: $*" >&2; exit 1; }
dexec() { docker exec "$container_name" "$@"; }
# Same, with stdin attached (payloads are piped in).
dexec_in() { docker exec -i "$container_name" "$@"; }

# Fake PBS endpoint for selfcheck's reachability test; a container restart
# kills it, so it is started again after every restart.
start_fake_pbs() {
    dexec sh -c 'nohup python3 -c "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((\"127.0.0.1\",8007)); s.listen(); [s.accept() for _ in iter(int,1)]" >/dev/null 2>&1 &'
}

cleanup() {
    set +e
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    docker image rm "$test_image" >/dev/null 2>&1 || true
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || die 'docker não encontrado'

cd "$repo_dir"
scripts/build-deb.sh
gw_deb=$(find "$repo_dir/dist" -maxdepth 1 -type f -name 'mm-gw-restore_*.deb' | sort | tail -n 1)
[ -n "$gw_deb" ] || die 'scripts/build-deb.sh não produziu mm-gw-restore'

docker build --tag "$test_image" - <<EOF
FROM $debian_image
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \\
    && apt-get install --yes ca-certificates curl systemd systemd-sysv samba \\
        smbclient nftables ntfs-3g iproute2 iputils-arping parted fdisk \\
        util-linux psmisc python3 \\
    && curl --fail --silent --show-error \\
        https://apt.mastermindti.cloud/mastermind-archive.gpg \\
        --output /usr/share/keyrings/mastermind-archive.gpg \\
    && printf '%s\\n' \\
        'deb [signed-by=/usr/share/keyrings/mastermind-archive.gpg] https://apt.mastermindti.cloud/debian trixie testing' \\
        > /etc/apt/sources.list.d/mastermind.list \\
    && apt-get update \\
    && apt-get install --yes ntfs-3g-plugin-dedup \\
    && rm -f /usr/sbin/policy-rc.d \\
    && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
EOF

docker run --detach --privileged --name "$container_name" \
    --hostname gw-restore-rock2 \
    --tmpfs /run --tmpfs /run/lock \
    --volume "$script_dir/fake-pbs-client:/opt/gw-rock2/fake-pbs-client:ro" \
    --volume "$script_dir/make-disk-image.sh:/opt/gw-rock2/make-disk-image.sh:ro" \
    --volume "$gw_deb:/opt/gw-rock2/mm-gw-restore.deb:ro" \
    "$test_image" /sbin/init >/dev/null

for _ in $(seq 1 60); do
    if docker exec "$container_name" systemctl is-system-running >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

dexec dpkg --install --force-depends /opt/gw-rock2/mm-gw-restore.deb >/dev/null
# Docker only creates /dev/loop0-7, but the kernel hands out higher loop
# numbers once those are busy (several maps plus crash-injection runs).
# shellcheck disable=SC2016 # expanded by the container's sh, not here
dexec sh -c 'for i in $(seq 0 63); do [ -b /dev/loop$i ] || mknod -m 0660 /dev/loop$i b 7 $i; done'
dexec install -m 0755 /opt/gw-rock2/fake-pbs-client /usr/local/bin/proxmox-backup-client
dexec install -m 0755 /opt/gw-rock2/make-disk-image.sh /usr/local/sbin/make-gw-rock2-image
dexec mkdir -p /var/lib/gw-restore-test
dexec env GW_FAKE_PBS_IMAGE=/var/lib/gw-restore-test/disk.img \
    /usr/local/sbin/make-gw-rock2-image /var/lib/gw-restore-test/disk.img
dexec sh -c 'cat > /etc/gw-restore/pbs.env <<"EOF"
PBS_SERVER=127.0.0.1:8007
PBS_USER=gw-restore@pbs!gateway
PBS_PASSWORD=rock2-test-token
PBS_FINGERPRINT=AA:BB
PBS_DATASTORES=bkp01
TRUNK=trunk0
EOF
chmod 0600 /etc/gw-restore/pbs.env'

start_fake_pbs
dexec sysctl -p /etc/sysctl.d/90-gw-restore.conf >/dev/null
dexec systemctl restart smbd.service

# Toda a topologia fica dentro do container privilegiado: veth, netns cliente,
# VLAN 120 e os dois endereços de origem usados para provar o isolamento.
dexec mkdir -p /run/netns
dexec ip link add trunk0 type veth peer name client0
dexec ip link set trunk0 up
dexec ip netns add client
dexec ip link set client0 netns client
dexec ip netns exec client ip link set lo up
dexec ip netns exec client ip link set client0 up
dexec ip netns exec client ip link add link client0 name client0.120 type vlan id 120
dexec ip netns exec client ip link set client0.120 up
dexec ip netns exec client ip addr add 10.1.20.23/24 dev client0.120
dexec ip netns exec client ip addr add 10.1.20.24/24 dev client0.120
dexec ip netns exec client ip route replace 10.1.20.0/24 dev client0.120 src 10.1.20.23

dexec systemctl is-enabled gw-restore-nft.service gw-restore-gc-boot.service
dexec systemd-analyze verify /usr/lib/systemd/system/gw-restore-nft.service \
    /usr/lib/systemd/system/gw-restore-gc-boot.service
dexec gw-restore selfcheck --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"], d'

payload1='{"contract":1,"request_id":"rock2-a","snapshot":"vm/101/2026-10-27T10:00:00Z","datastore":"bkp01","namespace":"","archive":"drive-scsi1.img","partition":1,"subpath":"Dados/ClienteA","vlan":120,"gw_ip":"10.1.20.250","prefix":24,"vm_ip":"10.1.20.23","hours":4,"requester":"root@pam","source_vmid":101,"target_vmid":101,"ticket":"ROCK2-1"}'
payload2='{"contract":1,"request_id":"rock2-b","snapshot":"vm/101/2026-10-27T10:00:00Z","datastore":"bkp01","namespace":"","archive":"drive-scsi1.img","partition":1,"subpath":"Dados/ClienteB","vlan":120,"gw_ip":"10.1.20.250","prefix":24,"vm_ip":"10.1.20.24","hours":4,"requester":"root@pam","source_vmid":101,"target_vmid":101,"ticket":"ROCK2-2"}'
publish() { printf '%s' "$1" | dexec_in gw-restore publish; }
json_field() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
result1=$(publish "$payload1")
result2=$(publish "$payload2")
sid1=$(printf '%s' "$result1" | json_field user | sed 's/^gwr-//')
sid2=$(printf '%s' "$result2" | json_field user | sed 's/^gwr-//')
pwd1=$(printf '%s' "$result1" | json_field password)
pwd2=$(printf '%s' "$result2" | json_field password)
[ "$sid1" != "$sid2" ] || die 'duas publicações criaram a mesma sessão'
mount_count=$(dexec sh -c 'find /srv/gw-restore/mounts -mindepth 1 -maxdepth 1 -type d | wc -l')
[ "$mount_count" -eq 1 ] || die 'duas sessões não compartilharam um mount'

# Executa smbclient real no namespace do cliente, dentro do próprio container.
client_smb() {
    dexec ip netns exec client smbclient "$@"
}
client_route_source() {
    dexec ip netns exec client ip route replace 10.1.20.0/24 dev client0.120 src "$1"
}
client_smb -L //10.1.20.250 -U "gwr-$sid1%$pwd1" -I 10.1.20.250 \
    --option='client min protocol=SMB3' > "$tmp_dir/list1"
grep -q "r-$sid1" "$tmp_dir/list1"
if grep -q "r-$sid2" "$tmp_dir/list1"; then
    die 'a listagem da sessão 1 expôs a sessão 2'
fi
client_smb //10.1.20.250/r-"$sid1" -U "gwr-$sid1%$pwd1" -I 10.1.20.250 -c ls >/dev/null
if client_smb //10.1.20.250/r-"$sid2" -U "gwr-$sid1%$pwd1" -I 10.1.20.250 -c ls >/dev/null 2>&1; then
    die 'a credencial da sessão 1 acessou a sessão 2'
fi
client_route_source 10.1.20.24
client_smb -L //10.1.20.250 -U "gwr-$sid2%$pwd2" -I 10.1.20.250 \
    --option='client min protocol=SMB3' > "$tmp_dir/list2"
grep -q "r-$sid2" "$tmp_dir/list2"
if grep -q "r-$sid1" "$tmp_dir/list2"; then
    die 'a listagem da sessão 2 expôs a sessão 1'
fi
client_smb //10.1.20.250/r-"$sid2" -U "gwr-$sid2%$pwd2" -I 10.1.20.250 -c ls >/dev/null
if client_smb //10.1.20.250/r-"$sid1" -U "gwr-$sid2%$pwd2" -I 10.1.20.250 -c ls >/dev/null 2>&1; then
    die 'a credencial da sessão 2 acessou a sessão 1'
fi
client_route_source 10.1.20.23
if client_smb //10.1.20.250/r-"$sid1" -U "gwr-$sid2%$pwd2" -I 10.1.20.250 -c ls >/dev/null 2>&1; then
    die 'a credencial da sessão 2 acessou a sessão 1 pelo IP da sessão 1'
fi

# Same request_id: exactly one session, new password, old credential invalid.
old_pwd=$pwd1
retry=$(publish "$payload1")
new_pwd=$(printf '%s' "$retry" | json_field password)
[ "$(printf '%s' "$retry" | json_field user)" = "gwr-$sid1" ]
[ "$old_pwd" != "$new_pwd" ]
if client_smb //10.1.20.250/r-"$sid1" -U "gwr-$sid1%$old_pwd" -I 10.1.20.250 -c ls >/dev/null 2>&1; then
    die 'a senha antiga continuou válida após retry'
fi
client_smb //10.1.20.250/r-"$sid1" -U "gwr-$sid1%$new_pwd" -I 10.1.20.250 -c ls >/dev/null

for step in map mount vlan nft samba state; do
    # Start every case from an empty gateway, so map/mount/VLAN/nft are real
    # side effects here (a VLAN left by an earlier session would skip "vlan").
    dexec gw-restore revoke --all >/dev/null
    crash_payload=${payload1/rock2-a/rock2-crash-$step}
    crash_payload=${crash_payload/drive-scsi1.img/drive-$step.img}
    if docker exec -e GW_RESTORE_FAIL_AFTER="$step" -i "$container_name" \
        sh -c 'printf "%s" "$1" | gw-restore publish >/dev/null' sh "$crash_payload"; then
        die "falha injetada $step não falhou"
    fi
    recovered=$(publish "$crash_payload")
    recovered_id=$(printf '%s' "$recovered" | json_field request_id)
    [ "$recovered_id" = "rock2-crash-$step" ]
    dexec gw-restore list --json | python3 -c \
        'import json,sys; d=json.load(sys.stdin); assert sum(s.get("request_id") == sys.argv[1] for s in d["sessions"]) == 1, d' \
        "rock2-crash-$step"
done

dexec gw-restore revoke --all >/dev/null
unclean_payload=${payload1/rock2-a/rock2-unclean}
docker exec -e GW_RESTORE_FAIL_AFTER=state -i "$container_name" \
    sh -c 'printf "%s" "$1" | gw-restore publish >/dev/null' sh "$unclean_payload" \
    >/dev/null 2>&1 &
publish_pid=$!
sleep 0.2
docker kill "$container_name" >/dev/null
wait "$publish_pid" || true
docker start "$container_name" >/dev/null
for _ in $(seq 1 60); do
    if docker exec "$container_name" systemctl is-system-running >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
[ "$(dexec find /var/lib/gw-restore/intents -type f | wc -l)" -eq 0 ]
[ "$(dexec find /srv/gw-restore/sessions -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 0 ]
gone_status=0
printf '%s' "$payload1" | dexec_in gw-restore publish >/dev/null 2>"$tmp_dir/gone" || gone_status=$?
[ "$gone_status" -ne 0 ]
grep -q '"error": "session_gone"' "$tmp_dir/gone"
[ "$(dexec find /var/lib/gw-restore/intents -type f | wc -l)" -eq 0 ]
[ "$(dexec find /srv/gw-restore/sessions -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 0 ]
mgmt_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name")
if timeout 5 bash -c "exec 3<>/dev/tcp/$mgmt_ip/445" 2>/dev/null; then
    die 'SMB acessível pela interface de gerência'
fi
dexec nft list table inet gw_restore | grep -qF 'dport { 139, 445 }'
if dexec testparm -s 2>/dev/null | grep -Eiq '^\[(homes|printers|print\$)\]'; then
    die 'o smb.conf manteve shares padrão'
fi
if dexec ip link show vl120 >/dev/null 2>&1; then
    die 'a VLAN da sessão removida continuou presente'
fi
if dexec nft -a list chain inet gw_restore vl_policy 2>/dev/null | grep -q 'dport 445'; then
    die 'a regra nft da sessão removida continuou presente'
fi

# A container restart is the installed-proof approximation of boot here;
# Rock 7 performs the real gateway VM reboot.
docker restart "$container_name" >/dev/null
for _ in $(seq 1 60); do
    if docker exec "$container_name" systemctl is-system-running >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
start_fake_pbs
dexec systemctl is-active gw-restore-nft.service >/dev/null
dexec systemctl is-enabled gw-restore-gc-boot.service >/dev/null
dexec gw-restore selfcheck --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"], d'
[ "$(dexec find /var/lib/gw-restore/intents -type f | wc -l)" -eq 0 ]
[ "$(dexec find /srv/gw-restore/sessions -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 0 ]
echo 'Rock 2 installed gateway proof: PASS'
