#!/usr/bin/env bash
# Cria/configura o gateway Debian 13 e prova o boot real da VM.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_GATEWAY_NODE LAB_GATEWAY_VMID LAB_GATEWAY_STORAGE \
    LAB_GATEWAY_MARKER LAB_GATEWAY_IMAGE_URL LAB_GATEWAY_SHA512_URL LAB_GATEWAY_IMAGE_FILE \
    LAB_GATEWAY_KEY_FILE LAB_GATEWAY_TMP_PACKAGE LAB_GATEWAY_TRUNK_IFACE LAB_BRIDGE \
    LAB_PBS_IP LAB_PBS_USER LAB_PBS_TOKEN_FILE LAB_PBS_FINGERPRINT_FILE LAB_PBS_DATASTORE \
    LAB_PBS_REPO_URL LAB_PBS_KEY_URL LAB_PBS_KEY_SHA256 LAB_MASTERMIND_APT \
    LAB_MASTERMIND_KEY_URL LAB_RESTORE_VLAN LAB_SECOND_VLAN LAB_RESTORE_GATEWAY_IP \
    LAB_RESTORE_PREFIX LAB_GATEWAY_NODE LAB_NODE1 LAB_NODE2 LAB_NODE3 LAB_EVIDENCE_DIR
LAB_GATEWAY_SNIPPET_STORAGE=${LAB_GATEWAY_SNIPPET_STORAGE:-local}
lab_init_evidence
repo_root=$(cd -- "${script_dir}/../.." && pwd -P)
package=$(find "${repo_root}/dist" -maxdepth 1 -type f -name 'mm-gw-restore_*.deb' -print -quit)
[[ -s $package ]] || lab_fail 'dist não contém mm-gw-restore; execute deploy.sh antes'
[[ -r $LAB_GATEWAY_KEY_FILE ]] || lab_fail 'chave pública do cloud-init não é legível'
[[ -r $LAB_PBS_TOKEN_FILE && -r $LAB_PBS_FINGERPRINT_FILE ]] || \
    lab_fail 'segredos PBS devem ser arquivos legíveis no workstation'

remote_tmp="/tmp/mm-pve-gateway-${$}"
output="${LAB_EVIDENCE_RUN_DIR}/gateway-vm.log"
: >"$output"
cleanup() {
    local rc=0
    lab_ssh "$LAB_GATEWAY_NODE" rm -rf -- "$remote_tmp" >>"$output" 2>&1 || rc=$?
    if (( rc != 0 )); then
        printf 'AVISO: limpeza remota do gateway retornou rc=%s\n' "$rc" >&2
    fi
}
trap cleanup EXIT INT TERM

lab_step 'gateway: transferir pacote, chave e arquivos de confiança para o node PVE'
mkdir -p -- "${LAB_EVIDENCE_RUN_DIR}/gateway-transfer"
mkdir_rc=0
lab_ssh "$LAB_GATEWAY_NODE" mkdir -m 0700 -p -- "$remote_tmp" >"${LAB_EVIDENCE_RUN_DIR}/gateway-transfer/mkdir.log" 2>&1 || mkdir_rc=$?
(( mkdir_rc == 0 )) || lab_fail 'não criei diretório temporário no node do gateway'
for source in "$package" "$LAB_GATEWAY_KEY_FILE" "$LAB_PBS_FINGERPRINT_FILE"; do
    base=$(basename -- "$source")
    scp_rc=0
    lab_scp_to "$source" "$LAB_GATEWAY_NODE" "$remote_tmp/$base" \
        >>"${LAB_EVIDENCE_RUN_DIR}/gateway-transfer/scp.log" 2>&1 || scp_rc=$?
    (( scp_rc == 0 )) || lab_fail "não transferi $base para o node do gateway"
done
secret_rc=0
lab_ssh "$LAB_GATEWAY_NODE" install -m 0600 /dev/stdin "$remote_tmp/pbs-token" \
    >"${LAB_EVIDENCE_RUN_DIR}/gateway-transfer/secret.log" 2>&1 \
    <"$LAB_PBS_TOKEN_FILE" || secret_rc=$?
(( secret_rc == 0 )) || lab_fail 'não transferi o segredo PBS para o node de forma protegida'

lab_step 'gateway: criar VM marcada e configurar cloud-image/rede'
rc=0
lab_ssh "$LAB_GATEWAY_NODE" bash -s -- \
    "$LAB_GATEWAY_VMID" "$LAB_GATEWAY_STORAGE" "$LAB_GATEWAY_MARKER" \
    "$LAB_GATEWAY_IMAGE_URL" "$LAB_GATEWAY_SHA512_URL" "$LAB_GATEWAY_IMAGE_FILE" \
    "$remote_tmp/$(basename -- "$LAB_GATEWAY_KEY_FILE")" "$LAB_BRIDGE" \
    "$LAB_RESTORE_VLAN" "$LAB_SECOND_VLAN" "$remote_tmp/pbs-token" \
    "$remote_tmp/$(basename -- "$LAB_PBS_FINGERPRINT_FILE")" \
    "$LAB_PBS_IP" "$LAB_PBS_USER" "$LAB_PBS_DATASTORE" "$remote_tmp/$(basename -- "$package")" \
    "$LAB_GATEWAY_TRUNK_IFACE" "$LAB_PBS_REPO_URL" "$LAB_PBS_KEY_URL" "$LAB_PBS_KEY_SHA256" \
    "$LAB_MASTERMIND_APT" "$LAB_MASTERMIND_KEY_URL" "$LAB_RESTORE_GATEWAY_IP" \
    "$LAB_RESTORE_PREFIX" "$LAB_GATEWAY_NODE" "$LAB_GATEWAY_TMP_PACKAGE" \
    "$LAB_GATEWAY_SNIPPET_STORAGE" >"$output" 2>&1 <<'REMOTE' || rc=$?
set -euo pipefail
vmid=$1
storage=$2
marker=$3
image_url=$4
sha_url=$5
image=$6
ssh_key=$7
bridge=$8
restore_vlan=$9
second_vlan=${10}
pbs_secret_file=${11}
pbs_fingerprint_file=${12}
pbs_ip=${13}
pbs_user=${14}
pbs_datastore=${15}
package_path=${16}
trunk_iface=${17}
pbs_repo=${18}
pbs_key_url=${19}
pbs_key_sha=${20}
mastermind_apt=${21}
mastermind_key_url=${22}
restore_gw_ip=${23}
restore_prefix=${24}
pve_node=${25}
package_destination=${26}
snippet_storage=${27}
marker_tag='mm-pve-tools-lab-gateway-rebooted'
tmp=/run/mm-pve-gateway
mkdir -m 0700 -p "$tmp"
cleanup() { rm -f -- "$tmp"/SHA512SUMS "$tmp"/mastermind.list "$tmp"/pbs.list "$tmp"/pbs-key.gpg "$image.part"; }
trap cleanup EXIT

# A cloud image genérica do Debian não traz o qemu-guest-agent, e o resto
# deste script fala com a VM pelo agente: o cloud-init instala no 1º boot.
if ! pvesm status --content snippets | awk 'NR > 1 { print $1 }' | grep -qxF -- "$snippet_storage"; then
    printf 'storage %s não aceita snippets; habilite com pvesm set %s --content <atual>,snippets\n' \
        "$snippet_storage" "$snippet_storage" >&2
    exit 1
fi
snippet_volid="$snippet_storage:snippets/mm-gw-restore-lab-vendor.yaml"
snippet_path=$(pvesm path "$snippet_volid")
mkdir -p -- "$(dirname -- "$snippet_path")"
cat >"$snippet_path" <<'VENDOR'
#cloud-config
packages:
  - qemu-guest-agent
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
VENDOR

if qm status "$vmid" >/dev/null 2>&1; then
    config=$(qm config "$vmid")
    [[ $config == *"description: $marker"* ]] || {
        printf 'VMID %s já existe sem o marcador do gateway; recusando tocar nela\n' "$vmid" >&2
        exit 1
    }
else
    mkdir -p -- "$(dirname -- "$image")"
    curl --fail --silent --show-error --location "$sha_url" -o "$tmp/SHA512SUMS"
    # SHA512SUMS traz só o nome do arquivo: confere dentro do diretório da
    # imagem. A URL é "latest", então um cache antigo deixa de bater e é
    # baixado de novo uma vez.
    image_ok() {
        (cd -- "$(dirname -- "$image")" \
            && grep -E "[ *]$(basename -- "$image")$" "$tmp/SHA512SUMS" | sha512sum -c --quiet -)
    }
    if [[ ! -s $image ]] || ! image_ok; then
        curl --fail --silent --show-error --location "$image_url" -o "$image.part"
        mv -- "$image.part" "$image"
        image_ok
    fi
    qm create "$vmid" --name mm-gw-restore-lab --memory 2048 --cores 2 \
        --ostype l26 --scsihw virtio-scsi-single --description "$marker" \
        --scsi0 "$storage:0,import-from=$image" --ide2 "$storage:cloudinit" \
        --boot order=scsi0 --agent enabled=1,fstrim_cloned_disks=1 \
        --net0 "virtio,bridge=$bridge" \
        --net1 "virtio,bridge=$bridge,trunks=${restore_vlan};${second_vlan}" \
        --ipconfig0 ip=dhcp
    qm set "$vmid" --sshkeys "$ssh_key" --ciuser debian
fi

# As placas de rede só são definidas no qm create: repetir --net0/--net1 sem o
# MAC gera MACs novos, o PVE troca as placas a quente e a rede do cloud-init
# (amarrada ao MAC) deixa a VM sem endereço.
qm set "$vmid" --agent enabled=1,fstrim_cloned_disks=1 --ipconfig0 ip=dhcp --cicustom "vendor=$snippet_volid"
if ! qm status "$vmid" | grep -q '^status: running$'; then
    qm start "$vmid"
fi

guest_exec() {
    local input=${GUEST_INPUT_DATA:-}
    local out pid status rc=0
    local -a cmd=(pvesh create "/nodes/$pve_node/qemu/$vmid/agent/exec" --output-format json)
    local arg
    for arg in "$@"; do cmd+=(--command "$arg"); done
    [[ -z $input ]] || cmd+=(--input-data "$input")
    out=$("${cmd[@]}" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
    pid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])' <<<"$out")
    while :; do
        status=$(pvesh get "/nodes/$pve_node/qemu/$vmid/agent/exec-status" \
            --pid "$pid" --output-format json)
        if [[ $(python3 -c 'import json,sys; print(int(json.load(sys.stdin).get("exited",0)))' <<<"$status") == 1 ]]; then
            rc=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("exitcode",0))' <<<"$status")
            python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data", ""), end="")' <<<"$status"
            if (( rc != 0 )); then
                python3 -c 'import json,sys; print(json.load(sys.stdin).get("err-data", ""), end="")' \
                    <<<"$status" >&2
                # só argumentos (segredos vão pelo stdin), cortados em 160 caracteres
                printf 'comando na VM %s falhou (rc=%s): %s\n' "$vmid" "$rc" \
                    "$(printf '%q ' "$@" | cut -c1-160)" >&2
                return "$rc"
            fi
            return 0
        fi
        sleep 2
    done
}

wait_for_agent() {
    local attempt
    for attempt in $(seq 1 150); do
        if qm agent "$vmid" ping >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    return 1
}
wait_for_agent || {
    printf 'qemu-guest-agent da VM %s não respondeu em 300 s\n' "$vmid" >&2
    exit 1
}

send_file() {
    local source=$1 destination=$2 encoded
    encoded=$(base64 -w0 "$source")
    GUEST_INPUT_DATA="$encoded" guest_exec bash -lc "base64 -d > $(printf '%q' "$destination")"
}
send_file "$package_path" "$package_destination"

# Bootstrap só na 1ª vez: com o mastermind-apt-config instalado, a fonte
# temporária conflita com a do pacote (Signed-By diferente) e o apt recusa.
guest_exec bash -lc 'set -e; install -d -m 0755 /etc/apt/keyrings; \
    if ! dpkg-query -W -f="\${Status}" mastermind-apt-config 2>/dev/null | grep -q "ok installed"; then \
        curl --fail --silent --show-error --location "$1" -o /etc/apt/keyrings/mastermind-archive.gpg; \
        printf "deb [signed-by=/etc/apt/keyrings/mastermind-archive.gpg] %s trixie testing\\n" "$2" > /etc/apt/sources.list.d/mastermind-temporary.list; \
        apt-get update -qq; apt-get install -y --no-install-recommends mastermind-apt-config; \
    fi; \
    rm -f /etc/apt/sources.list.d/mastermind-temporary.list; \
    mastermind-apt-channel testing; \
    printf "deb [signed-by=/etc/apt/keyrings/proxmox-archive-keyring-trixie.gpg] %s trixie main\\n" "$3" > /etc/apt/sources.list.d/pbs-client.list' \
    bash "$mastermind_key_url" "$mastermind_apt" "$pbs_repo"

# A chave é binária (bytes nulos): fica em arquivo, nunca numa variável do bash.
curl --fail --silent --show-error --location "$pbs_key_url" -o "$tmp/pbs-key.gpg"
key_hash=$(sha256sum "$tmp/pbs-key.gpg" | awk '{print $1}')
[[ $key_hash == "$pbs_key_sha" ]] || { printf 'fingerprint SHA256 da chave PBS não confere\n' >&2; exit 1; }
GUEST_INPUT_DATA="$(base64 -w0 "$tmp/pbs-key.gpg")" guest_exec bash -lc \
    'set -e; base64 -d > /etc/apt/keyrings/proxmox-archive-keyring-trixie.gpg'
# --reinstall no mm-gw-restore: um build novo com a mesma versão seria ignorado
guest_exec bash -lc "set -e; apt-get update -qq; apt-get install -y --no-install-recommends \
    samba nftables ntfs-3g qemu-guest-agent ntfs-3g-plugin-dedup proxmox-backup-client; \
    apt-get install -y --no-install-recommends --reinstall '$package_destination'; \
    rm -f '$package_destination'"

pbs_password=$(tr -d '\r\n' < "$pbs_secret_file")
pbs_fingerprint=$(tr -d '\r\n' < "$pbs_fingerprint_file")
pbs_script='set -e
umask 077
# a senha chega sem quebra de linha final: o read devolve 1 no EOF mesmo lendo
IFS= read -r password || [ -n "$password" ]
install -d -m 0700 /etc/gw-restore
{
    printf "PBS_SERVER=%s\\n" "$1"
    printf "PBS_USER=%s\\n" "$2"
    printf "PBS_PASSWORD=%s\\n" "$password"
    printf "PBS_FINGERPRINT=%s\\n" "$3"
    printf "PBS_DATASTORES=%s\\n" "$4"
    printf "TRUNK=%s\\n" "$5"
} > /etc/gw-restore/pbs.env
chmod 0600 /etc/gw-restore/pbs.env'
GUEST_INPUT_DATA="$pbs_password" guest_exec bash -lc "$pbs_script" bash \
    "$pbs_ip:8007" "$pbs_user" "$pbs_fingerprint" "$pbs_datastore" "$trunk_iface"

guest_exec bash -lc 'set -e; systemctl enable --now qemu-guest-agent; gw-restore selfcheck; nft list table inet gw_restore'

config=$(qm config "$vmid")
if [[ $config != *"tags: $marker_tag"* ]]; then
    qm set "$vmid" --tags "$marker_tag"
    qm reboot "$vmid" --timeout 300
    wait_for_agent
    config=$(qm config "$vmid")
fi
guest_exec bash -lc 'set -e; gw-restore gc --boot; gw-restore selfcheck; nft list table inet gw_restore; \
    test -z "$(find /srv/gw-restore/sessions /srv/gw-restore/mounts /etc/samba/gw-restore.d \
        -mindepth 1 -maxdepth 1 -print -quit)"'

python3 - "$restore_gw_ip" "$restore_prefix" "$restore_vlan" "$vmid" <<'PY' | mm-pve config set --stdin
import json
import sys
gw_ip, prefix, vlan, vmid = sys.argv[1:]
cfg = {
    "modules": {"restore": 1},
    "restore": {
        "gateway_vmid": int(vmid),
        "vlans": {str(vlan): {"gw_ip": gw_ip, "prefix": int(prefix)}},
        "session_default_hours": 1,
        "session_max_hours": 168,
        "max_sessions": 3,
    },
}
print(json.dumps(cfg))
PY
printf 'gateway-vm: PASS\n'
REMOTE
cat "$output"
(( rc == 0 )) || lab_fail "gateway-vm falhou (consulte $output)"

for node in "$LAB_NODE1" "$LAB_NODE2" "$LAB_NODE3"; do
    lab_step "gateway: aplicar restore em ${node}"
    node_log="${LAB_EVIDENCE_RUN_DIR}/gateway-apply-${node}.log"
    apply_rc=0
    lab_ssh "$node" mm-pve apply --no-patches --no-reload >"$node_log" 2>&1 || apply_rc=$?
    cat "$node_log"
    (( apply_rc == 0 )) || lab_fail "mm-pve apply falhou em $node"
done
lab_pass 'gateway criado/configurado; reboot e selfcheck comprovados'
