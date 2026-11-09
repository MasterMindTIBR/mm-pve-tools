#!/usr/bin/env bash
# Smoke de GUI no navegador contra o pveproxy real do lab (Rock 7): aba Limites
# do pool (admin edita, auditor só lê), erro de limite do servidor no hardware
# edit e dashboard de updates com um node offline (corosync parado por alguns
# segundos). Usuários e tickets de teste são criados como root no node, sem
# senha, e apagados no fim; os tickets ficam num diretório 0700 local montado
# só-leitura no container e nunca são impressos.
# shellcheck disable=SC2016  # $ARGV do perl vai literal para o node
set -euo pipefail
shopt -s inherit_errexit

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_NODE1 LAB_NODE2 LAB_NODE3 LAB_API_SCHEME LAB_API_PORT LAB_EVIDENCE_DIR
lab_init_evidence

repo=$(cd -- "${script_dir}/../.." && pwd -P)
image=mm-pve-tools-gui:playwright-1.49.1
ctl=$LAB_NODE1
off=${LAB_GUI_OFFLINE_NODE:-$LAB_NODE3}
nodes=("$LAB_NODE1" "$LAB_NODE2" "$LAB_NODE3")
vmid=${LAB_GUI_VMID:-9530}
pool=mm-gui-pool
admin_user=mm-gui-admin@pve
audit_user=mm-gui-audit@pve
audit_role=MMGuiPoolAudit
secrets=$(mktemp -d)
chmod 700 "$secrets"
corosync_stopped=0
old_pl='' old_up=''

flag() {
    lab_ssh "$ctl" python3 -c "import json; print(1 if (json.load(open('/etc/pve/mm-tools/config.json')).get('modules') or {}).get('$1') else 0)"
}

wait_quorum() {
    local n all
    for _ in $(seq 1 60); do
        all=1
        for n in "${nodes[@]}"; do
            timeout 20 ssh -F "$LAB_SSH_CONFIG" -o ConnectTimeout=5 "$n" \
                "pvecm status 2>/dev/null | grep -q '^Quorate:.*Yes' && systemctl is-active --quiet pveproxy pvedaemon" \
                2>/dev/null || all=0
        done
        (( all )) && return 0
        sleep 5
    done
    return 1
}

node_online() {   # node_online NODE -> 1/0 segundo o /cluster/status visto do controle
    lab_ssh "$ctl" pvesh get /cluster/status --output-format json \
        | python3 -c 'import json,sys; m=[x for x in json.load(sys.stdin) if x.get("type")=="node" and x.get("name")==sys.argv[1]]; print(m[0].get("online", 0) if m else 0)' "$1"
}

gui() {
    local ip
    ip=$(ssh -G -F "$LAB_SSH_CONFIG" "$ctl" | awk '/^hostname / {print $2}')
    docker run --rm --init --add-host "${ctl}:${ip}" --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "${repo}:/repo:ro" -v "${secrets}:/secrets:ro" "$image" \
        node /repo/t/lab/gui-smoke.js "$1" "${LAB_API_SCHEME}://${ctl}:${LAB_API_PORT}/" "$pool" "$vmid" "$ctl" "$off"
}

cleanup() {
    local rc=$?
    set +e
    printf 'PASSO: gui-smoke: limpeza\n'
    if (( corosync_stopped )); then lab_ssh "$off" systemctl start corosync; fi
    wait_quorum || printf 'FALHA: cluster sem quórum depois da limpeza\n'
    lab_ssh "$ctl" bash -c "qm stop $vmid --skiplock 1 >/dev/null 2>&1; qm destroy $vmid --purge 1 >/dev/null 2>&1" || true
    lab_ssh "$ctl" mm-pve poollimits set "$pool" --mode allocated --cpu-off --memory-off \
        --disk-total-off --disk-storage-off >/dev/null 2>&1 || true
    lab_ssh "$ctl" pvesh delete "/pools/${pool}" >/dev/null 2>&1 || true
    lab_ssh "$ctl" pveum user delete "$admin_user" >/dev/null 2>&1 || true
    lab_ssh "$ctl" pveum user delete "$audit_user" >/dev/null 2>&1 || true
    lab_ssh "$ctl" pveum role delete "$audit_role" >/dev/null 2>&1 || true
    [[ $old_pl == 0 ]] && lab_ssh "$ctl" mm-pve config set-module poollimits --disable >/dev/null 2>&1
    [[ $old_up == 0 ]] && lab_ssh "$ctl" mm-pve config set-module updates --disable >/dev/null 2>&1
    lab_kick_apply "${nodes[@]}" >/dev/null 2>&1
    rm -rf -- "$secrets"
    printf 'OK: gui-smoke limpo (poollimits=%s updates=%s restaurados)\n' "${old_pl:-?}" "${old_up:-?}"
    exit "$rc"
}
trap cleanup EXIT

lab_step 'gui-smoke: pool, VM, limites e usuários de teste'
wait_quorum || lab_fail 'cluster sem quórum antes do smoke'
old_pl=$(flag poollimits)
old_up=$(flag updates)
lab_ssh "$ctl" bash -c "qm destroy $vmid --purge 1 >/dev/null 2>&1; pvesh delete /pools/$pool >/dev/null 2>&1; pveum user delete $admin_user >/dev/null 2>&1; pveum user delete $audit_user >/dev/null 2>&1; pveum role delete $audit_role >/dev/null 2>&1; true"
lab_ssh "$ctl" pvesh create /pools --poolid "$pool" >/dev/null
lab_ssh "$ctl" qm create "$vmid" --name mm-gui-smoke --cores 1 --memory 256 --scsi0 local-lvm:1 --pool "$pool" >/dev/null
lab_ssh "$ctl" mm-pve config set-module updates --enable >/dev/null
lab_ssh "$ctl" mm-pve config set-module poollimits --enable >/dev/null
lab_kick_apply "$ctl"
for _ in $(seq 1 60); do
    lab_ssh "$ctl" mm-pve status | grep -Eq '^patch abstract_config_write: applied( |$)' && break
    sleep 5
done
lab_ssh "$ctl" mm-pve status | grep -Eq '^patch abstract_config_write: applied( |$)' || lab_fail 'poollimits não aplicou'
lab_ssh "$ctl" mm-pve poollimits set "$pool" --mode allocated --cpu-max 2 --memory-max 512 >/dev/null
lab_ssh "$ctl" pveum user add "$admin_user" --comment 'Rock 7 gui-smoke' >/dev/null
lab_ssh "$ctl" pveum acl modify / --users "$admin_user" --roles Administrator >/dev/null
lab_ssh "$ctl" pveum user add "$audit_user" --comment 'Rock 7 gui-smoke' >/dev/null
lab_ssh "$ctl" pveum role add "$audit_role" --privs Pool.Audit,VM.Audit >/dev/null
lab_ssh "$ctl" pveum acl modify "/pool/${pool}" --users "$audit_user" --roles "$audit_role" >/dev/null
( umask 077
  lab_ssh "$ctl" perl -MPVE::AccessControl -e 'print PVE::AccessControl::assemble_ticket($ARGV[0])' "$admin_user" > "$secrets/admin.ticket"
  lab_ssh "$ctl" perl -MPVE::AccessControl -e 'print PVE::AccessControl::assemble_ticket($ARGV[0])' "$audit_user" > "$secrets/audit.ticket" )
[[ -s $secrets/admin.ticket && -s $secrets/audit.ticket ]] || lab_fail 'tickets de teste não foram gerados'
lab_pass "pool $pool com a VM $vmid (1 vCPU, 256 MiB), limites 2 vCPU/512 MiB, admin e auditor criados"

lab_step 'gui-smoke: aba Limites e erro de limite no navegador'
gui pool
lab_ssh "$ctl" qm config "$vmid" | grep -q '^memory: 256$' || lab_fail 'memória da VM mudou apesar da recusa'
lab_pass 'aba Limites real (admin edita, auditor só lê) e erro de RAM do servidor no hardware edit; config intacta'

lab_step "gui-smoke: dashboard de updates com ${off} offline"
lab_ssh "$off" systemctl stop corosync
corosync_stopped=1
for _ in $(seq 1 30); do [[ $(node_online "$off") == 0 ]] && break; sleep 2; done
[[ $(node_online "$off") == 0 ]] || lab_fail "${off} não ficou offline no cluster"
gui offline
lab_ssh "$off" systemctl start corosync
corosync_stopped=0
wait_quorum || lab_fail "cluster não voltou ao quórum depois de religar o corosync em ${off}"
lab_pass "dashboard mostra ${off} offline; corosync religado e cluster de volta ao quórum"

lab_pass 'gui-smoke concluído'
