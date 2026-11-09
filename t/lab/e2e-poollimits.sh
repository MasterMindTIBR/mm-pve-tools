#!/usr/bin/env bash
# Prova do módulo poollimits no cluster do lab (Rock 7). Cria seus próprios
# guests numa faixa reservada de VMIDs e dois pools, liga o módulo e prova cada
# linha de docs/poollimits-coverage.md que o lab consegue exercitar: vCPU/RAM
# nos modos alocado e ligado (API, CLI, HA, starts concorrentes), entrada no
# pool, disco total e por storage, rollback que reanexa volume, migração no
# limite, backup com fleecing, permissões e desligamento. Toda recusa confere
# que a config e os volumes do guest ficaram iguais. O trap apaga tudo o que
# foi criado e devolve o módulo ao estado em que estava.
# shellcheck disable=SC2016,SC2015  # ${...} literais vão para comandos remotos; A && B || falha
set -euo pipefail
shopt -s inherit_errexit

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_NODE1 LAB_NODE2 LAB_NODE3 LAB_API_CA_FILE \
    LAB_ALLOWED_TOKEN_ID LAB_ALLOWED_TOKEN_SECRET_FILE \
    LAB_FORBIDDEN_TOKEN_ID LAB_FORBIDDEN_TOKEN_SECRET_FILE \
    LAB_API_SCHEME LAB_API_PORT LAB_EVIDENCE_DIR
lab_init_evidence

ctl=$LAB_NODE1
nodes=("$LAB_NODE1" "$LAB_NODE2" "$LAB_NODE3")
base=${LAB_POOL_VMID_BASE:-9500}
count=20
pool=${LAB_POOL_NAME:-mm-e2e-pool}
epool=${pool}-entry
lvm=${LAB_POOL_DISK_STORAGE:-local-lvm}
dir=${LAB_POOL_MOVE_STORAGE:-dir-lab1}
# Destino do mapping offline: precisa de formato de exportação comum com o
# lvmthin (o PVE recusa lvmthin -> zfspool: "cannot migrate from storage type").
map_store=${LAB_POOL_MIGRATION_STORAGE:-dir-lab1}
backup_store=${LAB_POOL_BACKUP_STORAGE:-local}
tpl_store=${LAB_POOL_TEMPLATE_STORAGE:-local}
mig_node=$LAB_NODE3
sched_job=mm-e2e-sched-$base
audit_user=mm-e2e-audit-$base@pve
audit_role=MMe2ePoolAudit$base
audit_token=pl
audit_secret=/run/mm-e2e-poollimits-audit.secret
# Admin próprio do teste: o token "permitido" do lab só tem Sys.Audit/Sys.Modify
# em / e não lê pool nem mexe em VM. Criado e apagado aqui.
admin_user=mm-e2e-admin-$base@pve
admin_token=pl
admin_secret=/run/mm-e2e-poollimits-admin.secret
GIB=$((1024 ** 3))

[[ $base =~ ^[0-9]+$ ]] && (( base >= 100 )) || lab_fail 'LAB_POOL_VMID_BASE inválido'
qmain=$base        # VM no pool: cores 1, 256 MiB, 1 GiB
qsecond=$((base + 1))  # VM fora do pool no início
qentry=$((base + 2))   # VM para entrada no pool
qapi=$((base + 3))     # fonte de backup/restore: cores 2, 512 MiB
qtpl=$((base + 4))     # template QEMU (linked clone)
qfleece=$((base + 5))  # VM no pool de entrada (allow-move)
qclone=$((base + 6))
qrestore=$((base + 7))
lmain=$((base + 8))    # CT no pool: cores 1, 128 MiB, 1 GiB
lsecond=$((base + 9))  # CT sem cores/cpulimit
ltpl=$((base + 10))    # template LXC
lsrc=$((base + 11))    # fonte de backup LXC: cores 2
lclone=$((base + 12))
lrestore=$((base + 13))

patches=(abstract_config_write guest_helpers_start access_control_pool qemu_create_pool qemu_clone_pool
    lxc_create_pool lxc_clone_pool pool_update storage_vdisk_alloc storage_vdisk_clone
    storage_volume_resize storage_volume_import)
daemons=(pvedaemon pveproxy pvescheduler pve-ha-lrm pve-ha-crm)
old_flag=''

# ---------------------------------------------------------------- helpers

# api [--as ID SECRETFILE] METHOD PATH [curl args...]: chamada HTTPS a partir do
# node de controle (token admin do teste por padrão). 1ª linha "HTTP <código>", depois o corpo.
api() {
    local id="${admin_user}!${admin_token}" file=$admin_secret
    if [[ $1 == --as ]]; then id=$2; file=$3; shift 3; fi
    lab_ssh "$ctl" bash -s -- "$(lab_node_url "$ctl")" "$LAB_API_CA_FILE" "$id" "$file" "$@" <<'REMOTE'
set -euo pipefail
base=$1 ca=$2 id=$3 file=$4 method=$5 path=$6
shift 6
secret=$(tr -d '\r\n' < "$file")
out=$(mktemp)
trap 'rm -f -- "$out"' EXIT
code=$(curl --silent --show-error --cacert "$ca" --header "Authorization: PVEAPIToken=${id}=${secret}" \
    -X "$method" "$@" -o "$out" -w '%{http_code}' "${base}/api2/json/${path}")
printf 'HTTP %s\n' "$code"
cat "$out"
printf '\n'
REMOTE
}
http_code() { sed -n '1s/^HTTP //p' <<<"$1"; }
http_body() { sed -n '2,$p' <<<"$1"; }
jget() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

api_ok() {
    local out
    out=$(api "$@")
    [[ $(http_code "$out") == 200 ]] || { printf '%s\n' "$out"; lab_fail "API $*: HTTP $(http_code "$out")"; return 1; }
    http_body "$out"
}

node_of() {
    lab_ssh "$ctl" pvesh get /cluster/resources --type vm --output-format json \
        | python3 -c 'import json,sys; m=[r["node"] for r in json.load(sys.stdin) if r.get("vmid")==int(sys.argv[1])]; print(m[0] if m else "")' "$1"
}

conf() {   # conf qemu|lxc ID -> config atual (vazio se não existe)
    local n
    n=$(node_of "$2")
    [[ -n $n ]] || return 0
    if [[ $1 == qemu ]]; then lab_ssh "$n" qm config "$2" 2>/dev/null || true
    else lab_ssh "$n" pct config "$2" 2>/dev/null || true; fi
}

vols() {   # vols ID -> volids do guest em todo storage de imagens de todos os nodes
    local n
    for n in "${nodes[@]}"; do
        lab_ssh "$n" bash -s -- "$1" <<'REMOTE'
set -euo pipefail
for s in $(pvesm status --content images,rootdir --enabled 1 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'); do
    pvesm list "$s" --vmid "$1" 2>/dev/null | awk 'NR>1 {print $1, $4}'
done
REMOTE
    done | sort -u
}

exists() { [[ -n $(node_of "$1") ]]; }

# refuse LABEL REGEX NODE cmd...: o comando tem de falhar com saída casando REGEX.
refuse() {
    local label=$1 regex=$2 node=$3 out rc=0
    shift 3
    out=$(lab_ssh "$node" "$@" 2>&1) || rc=$?
    printf '%s\n' "$out" | tail -6
    if grep -Eq "$regex" <<<"$out"; then
        # Comandos que rodam como task (qm resize, qm disk move) saem 0 mesmo
        # quando a task falha; é do PVE (provado no lab com erro nativo). O que
        # garante a recusa é a mensagem e, no refuse_same, config/volumes iguais.
        (( rc != 0 )) || printf '(CLI do PVE saiu 0: o erro veio de dentro da task)\n'
        printf 'recusa ok: %s\n' "$label"
        return 0
    fi
    (( rc != 0 )) || { lab_fail "$label: aceito (esperava recusa)"; return 1; }
    lab_fail "$label: recusado sem a mensagem esperada ($regex)"
    return 1
}

# refuse_same LABEL KIND ID REGEX NODE cmd...: recusa e config/volumes do guest iguais.
refuse_same() {
    local label=$1 kind=$2 id=$3 regex=$4 node=$5 c0 v0 c1 v1
    shift 5
    c0=$(conf "$kind" "$id"); v0=$(vols "$id")
    refuse "$label" "$regex" "$node" "$@"
    c1=$(conf "$kind" "$id"); v1=$(vols "$id")
    [[ $c0 == "$c1" ]] || { diff <(printf '%s\n' "$c0") <(printf '%s\n' "$c1") || true; lab_fail "$label: config mudou"; return 1; }
    [[ $v0 == "$v1" ]] || { printf 'antes:\n%s\ndepois:\n%s\n' "$v0" "$v1"; lab_fail "$label: volumes mudaram"; return 1; }
}

limit_re() { printf "pool '%s': limite de %s excedido \\\\(uso atual [0-9]+, pedido [0-9]+, limite [0-9]+\\\\)" "$1" "$2"; }

# limits POOL MODE CPU MEM TOTAL STORES: CPU/MEM/TOTAL número ou off; STORES
# "s1=N,s2=M" ou off. O CLI mescla storages, então zera antes de gravar.
limits() {
    local p=$1 mode=$2 cpu=$3 mem=$4 total=$5 stores=$6 s
    local -a args=(mm-pve poollimits set "$p" --mode "$mode")
    if [[ $cpu == off ]]; then args+=(--cpu-off); else args+=(--cpu-max "$cpu"); fi
    if [[ $mem == off ]]; then args+=(--memory-off); else args+=(--memory-max "$mem"); fi
    if [[ $total == off ]]; then args+=(--disk-total-off); else args+=(--disk-total-max "$total"); fi
    lab_ssh "$ctl" "${args[@]}" --disk-storage-off >/dev/null
    if [[ $stores != off ]]; then
        local -a sargs=(mm-pve poollimits set "$p" --mode "$mode")
        IFS=, read -r -a list <<<"$stores"
        for s in "${list[@]}"; do sargs+=(--disk-storage-max "$s"); done
        lab_ssh "$ctl" "${sargs[@]}" >/dev/null
    fi
    printf 'limites %s: modo=%s cpu=%s ram=%s total=%s storages=%s\n' "$p" "$mode" "$cpu" "$mem" "$total" "$stores"
}

pool_usage() {
    local body
    body=$(api_ok GET "nodes/${ctl}/mm-tools/poollimits/${1}")
    jget "$body" "'uso: cpu=%s ram=%s disco_total=%.2fGiB por_storage=%s erros=%s' % (d['data']['usage']['cpu'], d['data']['usage']['memory_mib'], d['data']['usage']['disk_total_bytes']/$GIB, {k: round(v/$GIB, 2) for k, v in d['data']['usage']['disk_storage_bytes'].items()}, d['data'].get('errors', []) + d['data'].get('disk_errors', []))"
}

# O uso de disco só é calculado com algum limite de disco ligado: quem chama
# deixa um limite total folgado ligado antes de ler.
# Reserva de alocação vale 120 s e redução não a libera (a gravação sem
# aumento sai antes do lock, de propósito): para ler o uso exato, espera vencer.
wait_reservations() { printf 'esperando reservas vencerem (TTL 120 s)\n'; sleep 125; }

disk_total_gib() {   # uso total de disco do pool em GiB inteiros (arredonda para cima)
    local body
    body=$(api_ok GET "nodes/${ctl}/mm-tools/poollimits/${1}")
    jget "$body" "-(-d['data']['usage']['disk_total_bytes'] // $GIB)"
}

patch_state_ok() {   # patch_state_ok NODE applied|not_applied
    local out id
    out=$(lab_ssh "$1" mm-pve status)
    for id in "${patches[@]}"; do grep -Eq "^patch ${id}: $2( |$)" <<<"$out" || return 1; done
}

wait_patches() {
    local n
    for _ in $(seq 1 60); do
        local all=1
        for n in "${nodes[@]}"; do patch_state_ok "$n" "$1" || all=0; done
        (( all )) && return 0
        sleep 5
    done
    for n in "${nodes[@]}"; do printf -- '--- %s\n' "$n"; lab_ssh "$n" mm-pve status | grep -E '^patch ' || true; done
    return 1
}

module_flag() {
    lab_ssh "$ctl" python3 -c "import json; print(1 if (json.load(open('/etc/pve/mm-tools/config.json')).get('modules') or {}).get('poollimits') else 0)"
}

wait_task() {   # wait_task NODE UPID -> exitstatus
    local enc body
    enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$2")
    for _ in $(seq 1 90); do
        body=$(api_ok GET "nodes/$1/tasks/${enc}/status")
        if [[ $(jget "$body" "d['data'].get('status')") == stopped ]]; then
            jget "$body" "d['data'].get('exitstatus')"; return 0
        fi
        sleep 2
    done
    lab_fail "task $2 não terminou"
}

destroy_guest() {
    local id=$1 n
    n=$(node_of "$id")
    [[ -n $n ]] || return 0
    lab_ssh "$ctl" ha-manager remove "vm:$id" >/dev/null 2>&1 || true
    lab_ssh "$ctl" ha-manager remove "ct:$id" >/dev/null 2>&1 || true
    lab_ssh "$n" bash -s -- "$id" <<'REMOTE' >/dev/null 2>&1 || true
id=$1
if qm config "$id" >/dev/null 2>&1; then
    qm unlock "$id"; qm stop "$id" --skiplock 1
    for s in $(qm listsnapshot "$id" 2>/dev/null | awk '{print $2}' | grep -v '^current$'); do qm delsnapshot "$id" "$s" --force 1; done
    qm destroy "$id" --purge 1 --destroy-unreferenced-disks 1 --skiplock 1
else
    pct unlock "$id"; pct stop "$id"
    for s in $(pct listsnapshot "$id" 2>/dev/null | awk '{print $2}' | grep -v '^current$'); do pct delsnapshot "$id" "$s" --force 1; done
    pct destroy "$id" --purge 1 --force 1
fi
REMOTE
}

leftovers() {   # volumes e backups da faixa em qualquer node
    local n
    for n in "${nodes[@]}"; do
        lab_ssh "$n" bash -s -- "$base" "$count" <<'REMOTE'
set -euo pipefail
b=$1 c=$2
for s in $(pvesm status --enabled 1 2>/dev/null | awk 'NR>1 && $3=="active" && $2!="pbs" {print $1}'); do
    pvesm list "$s" 2>/dev/null | awk 'NR>1 {print $1}' | python3 -c '
import re, sys
b, c = int(sys.argv[1]), int(sys.argv[2])
for v in sys.stdin.read().split():
    m = re.search(r"(?:[:/](?:vm|base|subvol)-|vzdump-(?:qemu|lxc)-)(\d+)-", v)
    if m and b <= int(m.group(1)) < b + c:
        print(v)' "$b" "$c"
done
REMOTE
    done | sort -u
}

free_leftovers() {
    local v n
    for n in "${nodes[@]}"; do
        lab_ssh "$n" bash -s -- "$base" "$count" <<'REMOTE' || true
set -uo pipefail
b=$1 c=$2
for s in $(pvesm status --enabled 1 2>/dev/null | awk 'NR>1 && $3=="active" && $2!="pbs" {print $1}'); do
    for v in $(pvesm list "$s" 2>/dev/null | awk 'NR>1 {print $1}'); do
        if python3 -c '
import re, sys
m = re.search(r"(?:[:/](?:vm|base|subvol)-|vzdump-(?:qemu|lxc)-)(\d+)-", sys.argv[1])
sys.exit(0 if m and int(sys.argv[2]) <= int(m.group(1)) < int(sys.argv[2]) + int(sys.argv[3]) else 1)' "$v" "$b" "$c"; then
            echo "liberando $v"; pvesm free "$v" >/dev/null 2>&1 || true
        fi
    done
done
REMOTE
    done
    v=$(leftovers)
    [[ -z $v ]]
}

clean_all() {
    local id
    lab_ssh "$ctl" pvesh delete "/cluster/backup/${sched_job}" >/dev/null 2>&1 || true
    for ((id = base; id < base + count; id++)); do destroy_guest "$id"; done
    lab_ssh "$ctl" mm-pve poollimits set "$pool" --mode allocated --cpu-off --memory-off \
        --disk-total-off --disk-storage-off >/dev/null 2>&1 || true
    lab_ssh "$ctl" pvesh delete "/pools/${pool}" >/dev/null 2>&1 || true
    lab_ssh "$ctl" pvesh delete "/pools/${epool}" >/dev/null 2>&1 || true
    lab_ssh "$ctl" pveum user delete "$audit_user" >/dev/null 2>&1 || true
    lab_ssh "$ctl" pveum user delete "$admin_user" >/dev/null 2>&1 || true
    lab_ssh "$ctl" pveum role delete "$audit_role" >/dev/null 2>&1 || true
    lab_ssh "$ctl" rm -f -- "$audit_secret" "$admin_secret" /var/tmp/mm-e2e-import.raw >/dev/null 2>&1 || true
    free_leftovers
}

on_exit() {
    local rc=$?
    set +e
    printf 'PASSO: poollimits: limpeza da faixa %s-%s\n' "$base" "$((base + count - 1))"
    clean_all
    local left
    left=$(leftovers)
    if [[ -n $left ]]; then printf 'FALHA: volumes da faixa sobraram:\n%s\n' "$left"; rc=1; fi
    if [[ -n $old_flag && $(module_flag) != "$old_flag" ]]; then
        if [[ $old_flag == 0 ]]; then lab_ssh "$ctl" mm-pve config set-module poollimits --disable >/dev/null
        else lab_ssh "$ctl" mm-pve config set-module poollimits --enable >/dev/null; fi
    fi
    # Espera o apply terminar: a próxima rodada não pode ligar com patches ainda aplicados.
    if [[ $old_flag == 0 ]]; then wait_patches not_applied >/dev/null || printf 'FALHA: patches não reverteram na limpeza\n'; fi
    printf 'OK: limpeza feita; módulo poollimits de volta a %s\n' "${old_flag:-?}"
    exit "$rc"
}

# ---------------------------------------------------------------- preparação

lab_step 'poollimits: pré-limpeza da faixa reservada'
old_flag=$(module_flag)
if [[ $old_flag == 1 ]]; then lab_ssh "$ctl" mm-pve config set-module poollimits --disable >/dev/null; fi
trap on_exit EXIT
wait_patches not_applied || lab_fail 'patches do poollimits ainda aplicados antes de ligar o módulo'
clean_all || lab_fail 'faixa reservada não ficou limpa'
lab_pass "faixa $base-$((base + count - 1)) limpa; poollimits estava $old_flag"

lab_step 'poollimits: template de CT, pools e guests (módulo ainda desligado)'
template=$(lab_ssh "$ctl" bash -s -- "$tpl_store" <<'REMOTE'
set -euo pipefail
store=$1
have=$(pveam list "$store" 2>/dev/null | awk 'NR>1 && /alpine/ {print $1}' | sort | tail -1)
if [ -z "$have" ]; then
    pveam update >/dev/null
    name=$(pveam available --section system | awk '/alpine-.*amd64/ {print $2}' | sort -V | tail -1)
    pveam download "$store" "$name" >/dev/null
    have=$(pveam list "$store" | awk 'NR>1 && /alpine/ {print $1}' | sort | tail -1)
fi
printf '%s\n' "$have"
REMOTE
)
[[ -n $template ]] || lab_fail 'template de CT indisponível'
printf 'template: %s\n' "$template"
lab_ssh "$ctl" pveum user add "$admin_user" --comment 'Rock 7 e2e: admin do teste' >/dev/null
lab_ssh "$ctl" pveum acl modify / --users "$admin_user" --roles Administrator >/dev/null
lab_ssh "$ctl" bash -s -- "$admin_user" "$admin_token" "$admin_secret" <<'REMOTE'
set -euo pipefail
umask 077
pveum user token add "$1" "$2" --privsep 0 --output-format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])' > "$3"
REMOTE
lab_ssh "$ctl" pvesh create /pools --poolid "$pool" --comment 'Rock 7 e2e' >/dev/null
lab_ssh "$ctl" pvesh create /pools --poolid "$epool" --comment 'Rock 7 e2e entrada' >/dev/null
qcreate() { lab_ssh "$ctl" qm create "$1" --name "mm-e2e-$1" --cores "$2" --memory "$3" --scsi0 "$lvm:1" --agent 0 "${@:4}" >/dev/null; }
qcreate "$qmain" 1 256 --pool "$pool"
qcreate "$qsecond" 1 256
qcreate "$qentry" 1 256
qcreate "$qapi" 2 512
qcreate "$qtpl" 1 256
qcreate "$qfleece" 1 128 --pool "$epool"
lab_ssh "$ctl" qm template "$qtpl" >/dev/null
ccreate() { lab_ssh "$ctl" pct create "$1" "$template" --hostname "mm-e2e-$1" --memory 128 --rootfs "$lvm:1" --unprivileged 1 "${@:2}" >/dev/null; }
ccreate "$lmain" --cores 1 --pool "$pool"
ccreate "$lsecond"
ccreate "$ltpl" --cores 1
ccreate "$lsrc" --cores 2
lab_ssh "$ctl" pct template "$ltpl" >/dev/null
lab_ssh "$ctl" pvesh get "/pools/${pool}" --output-format json | python3 -c 'import json,sys; print("membros do pool:", sorted(m["vmid"] for m in json.load(sys.stdin)["members"] if "vmid" in m))'
lab_pass 'pools e guests criados'

lab_step 'poollimits: liga o módulo e espera os patches nos 3 nodes'
enable_epoch=$(lab_ssh "$ctl" date +%s)
lab_ssh "$ctl" mm-pve config set-module poollimits --enable >/dev/null
wait_patches applied || lab_fail 'patches do poollimits não aplicaram nos 3 nodes'
for n in "${nodes[@]}"; do
    for d in "${daemons[@]}"; do
        lab_ssh "$n" systemctl is-active --quiet "$d" || lab_fail "$d inativo em $n"
        hits=$(lab_ssh "$n" journalctl -u "$d" --since "@${enable_epoch}" -o cat --no-pager | grep -Eci 'reload|restart|start' || true)
        (( hits > 0 )) || lab_fail "$d não recarregou em $n depois do patch"
    done
    printf '%s: %s aplicados; daemons recarregados e ativos\n' "$n" "${#patches[@]}"
done
lab_pass 'patches aplicados e daemons recarregados nos 3 nodes'

lab_step 'poollimits: limites pela API (JSON, com digest) e leitura pela API'
body=$(api_ok GET "nodes/${ctl}/mm-tools/poollimits/${pool}")
digest=$(jget "$body" "d['data']['digest']")
payload=$(python3 -c 'import json,sys; print(json.dumps({"mode":"allocated","cpu":{"enabled":True,"max":2},"memory_mib":{"enabled":True,"max":512},"disk_total_gib":{"enabled":False},"disk_storage":{"enabled":False},"digest":sys.argv[1]}))' "$digest")
api_ok PUT "nodes/${ctl}/mm-tools/poollimits/${pool}" -H 'Content-Type: application/json' --data "$payload" >/dev/null
stale=$(api PUT "nodes/${ctl}/mm-tools/poollimits/${pool}" -H 'Content-Type: application/json' --data "$payload")
[[ $(http_code "$stale") != 200 ]] || lab_fail 'PUT com digest antigo foi aceito'
printf 'digest antigo recusado: HTTP %s\n' "$(http_code "$stale")"
body=$(api_ok GET "nodes/${ctl}/mm-tools/poollimits/${pool}")
jget "$body" "'can_edit=%s modo=%s cpu=%s ram=%s' % (d['data']['can_edit'], d['data']['mode'], d['data']['limits']['cpu'], d['data']['limits']['memory_mib'])"
pool_usage "$pool"
lab_pass 'PUT JSON com digest gravou; digest antigo recusado; GET com uso'

# ---------------------------------------------------------------- vCPU/RAM

lab_step 'poollimits: vCPU/RAM no modo alocado (CLI, API, pvesh, pending, redução)'
# uso: qmain 1 vCPU/256 + lmain 1 vCPU/128 -> 2 vCPU (no limite), 384 MiB
refuse_same 'qm cores' qemu "$qmain" "$(limit_re "$pool" vCPU)" "$ctl" qm set "$qmain" --cores 2
refuse_same 'qm memória' qemu "$qmain" "$(limit_re "$pool" 'RAM MiB')" "$ctl" qm set "$qmain" --memory 512
refuse_same 'pct cores' lxc "$lmain" "$(limit_re "$pool" vCPU)" "$ctl" pct set "$lmain" --cores 2
refuse_same 'pvesh' qemu "$qmain" "$(limit_re "$pool" vCPU)" "$ctl" pvesh set "/nodes/${ctl}/qemu/${qmain}/config" --cores 2
c0=$(conf qemu "$qmain")
out=$(api PUT "nodes/${ctl}/qemu/${qmain}/config" --data-urlencode cores=2)
[[ $(http_code "$out") != 200 ]] && grep -Eq "$(limit_re "$pool" vCPU)" <<<"$out" \
    || { printf '%s\n' "$out"; lab_fail 'API (pvedaemon) não recusou o aumento de vCPU'; }
[[ $c0 == "$(conf qemu "$qmain")" ]] || lab_fail 'API: config mudou'
printf 'API recusou: HTTP %s\n' "$(http_code "$out")"
lab_ssh "$ctl" qm start "$qmain" >/dev/null
refuse 'pending (VM ligada)' "$(limit_re "$pool" 'RAM MiB')" "$ctl" qm set "$qmain" --memory 1024
lab_ssh "$ctl" qm config "$qmain" --current 0 | grep -q '^memory: 256' || lab_fail 'pending ficou gravado'
lab_ssh "$ctl" qm stop "$qmain" >/dev/null
limits "$pool" allocated 1 256 off off   # abaixo do uso: só aumento é recusado
lab_ssh "$ctl" qm set "$qmain" --memory 200 >/dev/null || lab_fail 'redução com pool acima do limite recusada'
lab_ssh "$ctl" qm set "$qmain" --memory 256 >/dev/null 2>&1 && lab_fail 'aumento com pool acima do limite aceito'
printf 'redução aceita e aumento recusado com o pool acima do limite\n'
limits "$pool" allocated 2 512 off off
refuse_same 'CT sem cores/cpulimit entrando no pool' lxc "$lsecond" "não tem cpulimit nem cores" "$ctl" \
    pvesh set "/pools/${pool}" --vms "$lsecond"
lab_pass 'vCPU/RAM: CLI, API, pvesh, pending, redução acima do limite e CT sem cores'

lab_step 'poollimits: entrada no pool, create, clone, linked clone e restore'
# pool no limite de vCPU (2); qentry/qapi/templates fora do pool
refuse 'pvesh (Pool API antiga)' "$(limit_re "$pool" vCPU)" "$ctl" pvesh set "/pools/${pool}" --vms "$qentry"
refuse 'pveum pool modify' "$(limit_re "$pool" vCPU)" "$ctl" pveum pool modify "$pool" --vms "$qentry"
out=$(api PUT "pools" --data-urlencode "poolid=${pool}" --data-urlencode "vms=${qentry}")
[[ $(http_code "$out") != 200 ]] && grep -Eq "$(limit_re "$pool" vCPU)" <<<"$out" \
    || { printf '%s\n' "$out"; lab_fail 'Pool API nova aceitou a entrada'; }
refuse 'allow-move de outro pool' "$(limit_re "$pool" vCPU)" "$ctl" pvesh set "/pools/${pool}" --vms "$qfleece" --allow-move 1
lab_ssh "$ctl" pvesh get "/pools/${epool}" --output-format json | grep -q "\"vmid\":${qfleece}" || lab_fail 'guest saiu do pool de origem'
refuse 'qm create --pool' "$(limit_re "$pool" vCPU)" "$ctl" qm create "$qclone" --cores 1 --memory 128 --scsi0 "$lvm:1" --pool "$pool"
refuse 'pct create --pool' "$(limit_re "$pool" vCPU)" "$ctl" pct create "$lclone" "$template" --cores 1 --memory 64 --rootfs "$lvm:1" --unprivileged 1 --pool "$pool"
refuse 'qm clone full --pool' "$(limit_re "$pool" vCPU)" "$ctl" qm clone "$qapi" "$qclone" --full 1 --pool "$pool"
refuse 'qm linked clone --pool' "$(limit_re "$pool" vCPU)" "$ctl" qm clone "$qtpl" "$qclone" --pool "$pool"
refuse 'pct linked clone --pool' "$(limit_re "$pool" vCPU)" "$ctl" pct clone "$ltpl" "$lclone" --pool "$pool"
for id in "$qclone" "$lclone"; do exists "$id" && lab_fail "guest $id ficou criado depois da recusa"; done
[[ -z $(vols "$qclone")$(vols "$lclone") ]] || lab_fail 'recusa deixou volume'
lab_ssh "$ctl" vzdump "$qapi" "$lsrc" --storage "$backup_store" --mode stop --compress zstd >/dev/null
qbackup=$(lab_ssh "$ctl" pvesm list "$backup_store" --content backup --vmid "$qapi" | awk 'NR>1 {print $1}' | tail -1)
cbackup=$(lab_ssh "$ctl" pvesm list "$backup_store" --content backup --vmid "$lsrc" | awk 'NR>1 {print $1}' | tail -1)
[[ -n $qbackup && -n $cbackup ]] || lab_fail 'vzdump não gerou os backups de origem'
refuse 'qmrestore --pool' "$(limit_re "$pool" vCPU)" "$ctl" qmrestore "$qbackup" "$qrestore" --pool "$pool"
refuse 'pct restore --pool' "$(limit_re "$pool" vCPU)" "$ctl" pct restore "$lrestore" "$cbackup" --pool "$pool" --unprivileged 1 --storage "$lvm"
for id in "$qrestore" "$lrestore"; do exists "$id" && lab_fail "restore recusado deixou $id"; done
refuse_same 'qmrestore por cima de guest do pool' qemu "$qmain" "$(limit_re "$pool" vCPU)" "$ctl" qmrestore "$qbackup" "$qmain" --force 1
refuse_same 'pct restore por cima de CT do pool' lxc "$lmain" "$(limit_re "$pool" vCPU)" "$ctl" pct restore "$lmain" "$cbackup" --force 1 --unprivileged 1 --storage "$lvm"
lab_ssh "$ctl" pvesh set "/pools/${pool}" --vms "$qtpl" >/dev/null || lab_fail 'template entrando no pool no limite de vCPU foi recusado'
lab_ssh "$ctl" pvesh set "/pools/${pool}" --vms "$qtpl" --delete 1 >/dev/null
lab_pass 'entrada (pvesh, pveum, Pool API, allow-move), create, clone, linked clone e restore recusados; template não conta'

lab_step 'poollimits: modo ligado — start pela CLI, API e HA; dois starts concorrentes'
limits "$pool" running 1 1024 off off
lab_ssh "$ctl" pvesh set "/pools/${pool}" --vms "$qsecond" >/dev/null   # desligado não conta no modo ligado
lab_ssh "$ctl" qm start "$qmain" >/dev/null
refuse 'qm start' "$(limit_re "$pool" vCPU)" "$ctl" qm start "$qsecond"
out=$(api_ok POST "nodes/${ctl}/qemu/${qsecond}/status/start")
exitstatus=$(wait_task "$ctl" "$(jget "$out" "d['data']")")
grep -Eq "$(limit_re "$pool" vCPU)" <<<"$exitstatus" || lab_fail "start pela API: task terminou com '$exitstatus'"
printf 'start pela API: task falhou com a mensagem do limite\n'
ha_epoch=$(lab_ssh "$ctl" date +%s)
lab_ssh "$ctl" ha-manager add "vm:${qsecond}" --state started --max_restart 0 --max_relocate 0 >/dev/null
ha_state=''
for _ in $(seq 1 30); do
    ha_state=$(lab_ssh "$ctl" ha-manager status | awk -v s="vm:${qsecond}" '$2==s {print $NF}')
    [[ $ha_state == *error* ]] && break
    sleep 4
done
lab_ssh "$ctl" ha-manager status | grep -E "vm:${qsecond}" || true
lab_ssh "$ctl" qm status "$qsecond" | grep -q stopped || lab_fail 'HA ligou a VM acima do limite'
[[ $ha_state == *error* ]] || lab_fail "HA não terminou em error (estado: ${ha_state:-?})"
ha_task=$(lab_ssh "$ctl" pvesh get "/nodes/${ctl}/tasks" --typefilter qmstart --vmid "$qsecond" --since "$ha_epoch" \
    --output-format json | python3 -c 'import json,sys; t=[x.get("status","") for x in json.load(sys.stdin)]; print(t[0] if t else "")')
printf 'task de start disparada pelo HA: %s\n' "${ha_task:-nenhuma}"
grep -Eq "$(limit_re "$pool" vCPU)" <<<"$ha_task" || lab_fail 'start do HA não falhou com a mensagem do limite'
lab_ssh "$ctl" ha-manager remove "vm:${qsecond}" >/dev/null
lab_ssh "$ctl" qm stop "$qmain" >/dev/null
race=$(lab_ssh "$ctl" bash -s -- "$qmain" "$qsecond" <<'REMOTE'
set -uo pipefail
qm start "$1" >/run/mm-e2e-race-a 2>&1 & a=$!
qm start "$2" >/run/mm-e2e-race-b 2>&1 & b=$!
wait "$a"; ra=$?
wait "$b"; rb=$?
printf 'start %s rc=%s; start %s rc=%s\n' "$1" "$ra" "$2" "$rb"
cat /run/mm-e2e-race-a /run/mm-e2e-race-b | tail -4
rm -f /run/mm-e2e-race-a /run/mm-e2e-race-b
echo "ok=$(( (ra == 0) + (rb == 0) ))"
REMOTE
)
printf '%s\n' "$race"
grep -q '^ok=1$' <<<"$race" || lab_fail 'dois starts concorrentes: não foi exatamente um'
lab_ssh "$ctl" qm stop "$qmain" >/dev/null 2>&1 || true
lab_ssh "$ctl" qm stop "$qsecond" >/dev/null 2>&1 || true
lab_pass 'modo ligado: CLI, API (task), HA (error, journal do LRM) e só um de dois starts concorrentes'

# ---------------------------------------------------------------- disco

lab_step 'poollimits: disco total no limite (add, resize, import, alloc, cloud-init, EFI, TPM, LXC)'
limits "$pool" allocated off off 3 off   # uso: qmain 1 + lmain 1 + qsecond 1 = 3 GiB
pool_usage "$pool"
dre=$(limit_re "$pool" 'disco total')
refuse_same 'add disk' qemu "$qmain" "$dre" "$ctl" qm set "$qmain" --scsi1 "$lvm:1"
refuse_same 'resize' qemu "$qmain" "$dre" "$ctl" qm resize "$qmain" scsi0 +1G
lab_ssh "$ctl" truncate -s 1G /var/tmp/mm-e2e-import.raw
refuse_same 'qm disk import' qemu "$qmain" "$dre" "$ctl" qm disk import "$qmain" /var/tmp/mm-e2e-import.raw "$lvm"
refuse_same 'pvesm alloc --vmid' qemu "$qmain" "$dre" "$ctl" pvesm alloc "$lvm" "$qmain" "vm-${qmain}-disk-9" 1G
refuse_same 'cloud-init' qemu "$qmain" "$dre" "$ctl" qm set "$qmain" --ide2 "$lvm:cloudinit"
refuse_same 'EFI disk' qemu "$qmain" "$dre" "$ctl" qm set "$qmain" --efidisk0 "$lvm:1,efitype=4m"
refuse_same 'TPM state' qemu "$qmain" "$dre" "$ctl" qm set "$qmain" --tpmstate0 "$lvm:1,version=v2.0"
refuse_same 'pct mpN' lxc "$lmain" "$dre" "$ctl" pct set "$lmain" --mp0 "$lvm:1,mp=/mnt/e2e"
refuse_same 'pct resize' lxc "$lmain" "$dre" "$ctl" pct resize "$lmain" rootfs +1G
lab_ssh "$ctl" qm set "$qmain" --ide2 none,media=cdrom >/dev/null || lab_fail 'CD-ROM sem volume recusado'
lab_ssh "$ctl" pct set "$lmain" --mp1 /var/tmp,mp=/mnt/bind >/dev/null || lab_fail 'bind mount recusado'
lab_ssh "$ctl" pct set "$lmain" --delete mp1 >/dev/null
lab_ssh "$ctl" qm set "$qmain" --delete ide2 >/dev/null
lab_pass 'disco total: add, resize, import, pvesm alloc, cloud-init, EFI, TPM e LXC recusados sem volume novo; CD-ROM e bind mount não contam'

lab_step 'poollimits: unusedN conta; limite por storage (add e move)'
limits "$pool" allocated off off 4 off
lab_ssh "$ctl" qm set "$qmain" --scsi1 "$lvm:1" >/dev/null || lab_fail 'add disk dentro do limite recusado'
lab_ssh "$ctl" qm set "$qmain" --delete scsi1 >/dev/null
lab_ssh "$ctl" qm config "$qmain" | grep -q '^unused0:' || lab_fail 'disco não virou unused0'
refuse_same 'add com unused0 contado' qemu "$qmain" "$(limit_re "$pool" 'disco total')" "$ctl" qm set "$qmain" --scsi2 "$lvm:1"
limits "$pool" allocated off off off "${lvm}=4,${dir}=1"
refuse_same "add por storage ($lvm)" qemu "$qmain" "$(limit_re "$pool" "disco em ${lvm}")" "$ctl" qm set "$qmain" --scsi2 "$lvm:1"
lab_ssh "$ctl" qm disk move "$qmain" scsi0 "$dir" --delete 1 >/dev/null || lab_fail "move para $dir dentro do limite recusado"
refuse_same "move por storage ($dir)" qemu "$qsecond" "$(limit_re "$pool" "disco em ${dir}")" "$ctl" qm disk move "$qsecond" scsi0 "$dir" --delete 1
lab_ssh "$ctl" qm disk move "$qmain" scsi0 "$lvm" --delete 1 >/dev/null || lab_fail "move de volta para $lvm recusado"
pool_usage "$pool"
lab_pass "unusedN contado; limite por storage recusa add em $lvm e move para $dir; movimentos dentro do limite passam"

lab_step 'poollimits: rollback que reanexa volume fora da conta é recusado'
limits "$pool" allocated off off 100 off
lab_ssh "$ctl" qm set "$qmain" --scsi3 "$lvm:1" >/dev/null
lab_ssh "$ctl" qm snapshot "$qmain" mme2e >/dev/null
lab_ssh "$ctl" qm set "$qmain" --delete scsi3 >/dev/null
# O PVE não deixa tirar da config um volume que um snapshot ainda usa
# ("volume is still in use"); o estado "só no snapshot, fora da conta" só
# aparece com a config mexida por fora. Simula isso tirando a linha unusedN
# da seção principal do arquivo, para provar a defesa do hook no rollback.
lab_ssh "$ctl" python3 - "/etc/pve/qemu-server/${qmain}.conf" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
head, sep, rest = text.partition('\n[')
lines = head.split('\n')
unused = [l for l in lines if re.match(r'unused\d+: .*disk-', l)]
if not unused:
    sys.exit('sem unusedN na seção principal')
lines.remove(unused[-1])
open(path, 'w').write('\n'.join(lines) + sep + rest)
print('removido da config principal:', unused[-1])
PY
lab_ssh "$ctl" qm config "$qmain" --snapshot mme2e | grep -q '^scsi3:' || lab_fail 'snapshot perdeu o scsi3'
wait_reservations
used=$(disk_total_gib "$pool")
limits "$pool" allocated off off "$used" off
c0=$(conf qemu "$qmain" | grep -v '^lock:')
refuse 'rollback reanexando volume' "$(limit_re "$pool" 'disco total')" "$ctl" qm rollback "$qmain" mme2e
lab_ssh "$ctl" qm unlock "$qmain" >/dev/null 2>&1 || true
[[ $c0 == "$(conf qemu "$qmain" | grep -v '^lock:')" ]] || lab_fail 'rollback recusado mudou a config'
limits "$pool" allocated off off off off
lab_ssh "$ctl" qm rollback "$qmain" mme2e >/dev/null || lab_fail 'rollback sem limite recusado'
lab_ssh "$ctl" qm delsnapshot "$qmain" mme2e >/dev/null
lab_ssh "$ctl" qm set "$qmain" --delete scsi3 >/dev/null
lab_ssh "$ctl" bash -c "for u in \$(qm config $qmain | awk -F: '/^unused[0-9]+:/ {print \$1}'); do qm set $qmain --delete \$u >/dev/null; done"
lab_pass 'rollback que reanexa volume não contado recusado com a config intacta; sem limite passa'

lab_step 'poollimits: migração no limite (NBD, storage tunnel, mapping) e backup com fleecing'
limits "$pool" allocated off off 100 off
wait_reservations
used=$(disk_total_gib "$pool")
limits "$pool" allocated off off "$used" "${lvm}=${used}"
pool_usage "$pool"
lab_ssh "$ctl" qm start "$qmain" >/dev/null
lab_ssh "$ctl" qm migrate "$qmain" "$mig_node" --online 1 --with-local-disks 1 >/dev/null \
    || lab_fail 'migração online com disco local (NBD) recusada no limite'
[[ $(node_of "$qmain") == "$mig_node" ]] || lab_fail 'VM não foi para o destino'
lab_ssh "$mig_node" qm stop "$qmain" >/dev/null
lab_ssh "$mig_node" qm migrate "$qmain" "$ctl" --targetstorage "${lvm}:${map_store}" >/dev/null \
    || lab_fail "migração offline com mapping ${lvm}:${map_store} recusada"
lab_ssh "$ctl" qm config "$qmain" | grep -q "^scsi0: ${map_store}:" || lab_fail "mapping não levou o disco para ${map_store}"
lab_ssh "$ctl" pct migrate "$lmain" "$mig_node" >/dev/null || lab_fail 'migração do CT (storage tunnel, mesmo volid) recusada'
lab_ssh "$mig_node" pct migrate "$lmain" "$ctl" >/dev/null || lab_fail 'migração de volta do CT recusada'
printf 'NÃO PROVADO: mapping de CT (sem storage de CT de outro tipo compatível com lvmthin neste lab)\n'
printf 'depois do mapping (efeito por datastore documentado): '
pool_usage "$pool"
used=$(disk_total_gib "$pool")
limits "$pool" allocated off off "$used" off
lab_ssh "$ctl" qm start "$qmain" >/dev/null
lab_ssh "$ctl" vzdump "$qmain" --storage "$backup_store" --mode snapshot --compress zstd \
    --fleecing "enabled=1,storage=${lvm}" >/dev/null || lab_fail 'backup com fleecing de VM no limite falhou'
lab_ssh "$ctl" qm stop "$qmain" >/dev/null
[[ -z $(vols "$qmain" | grep -- '-fleece-' || true) ]] || lab_fail 'sobrou volume -fleece-'
lab_pass "NBD, storage tunnel (CT) e mapping ${lvm}:${map_store} (VM) concluídos no limite; fleecing sem volume sobrando"

lab_step 'poollimits: pvescheduler roda backup agendado de guest do pool limitado'
limits "$pool" allocated 1 256 1 off   # tudo acima do limite: backup não é aumento
sched_epoch=$(lab_ssh "$ctl" date +%s)
lab_ssh "$ctl" pvesh create /cluster/backup --id "$sched_job" --schedule '*:0/1' --vmid "$qsecond" \
    --storage "$backup_store" --mode stop --compress zstd --enabled 1 >/dev/null
sched=''
for _ in $(seq 1 30); do
    sched=$(lab_ssh "$ctl" pvesh get "/nodes/${ctl}/tasks" --typefilter vzdump --since "$sched_epoch" --output-format json \
        | python3 -c 'import json,sys; t=[x for x in json.load(sys.stdin) if x.get("status")]; print(t[0]["status"] if t else "")')
    [[ -n $sched ]] && break
    sleep 10
done
lab_ssh "$ctl" pvesh delete "/cluster/backup/${sched_job}" >/dev/null
[[ $sched == OK ]] || lab_fail "backup agendado: '${sched:-não rodou}'"
lab_pass 'pvescheduler (patch carregado) rodou o backup agendado sem recusa falsa'

lab_step 'poollimits: permissões (token proibido, Pool.Audit)'
digest=$(jget "$(api_ok GET "nodes/${ctl}/mm-tools/poollimits/${pool}")" "d['data']['digest']")
payload=$(python3 -c 'import json,sys; print(json.dumps({"mode":"allocated","digest":sys.argv[1]}))' "$digest")
out=$(api --as "$LAB_FORBIDDEN_TOKEN_ID" "$LAB_FORBIDDEN_TOKEN_SECRET_FILE" PUT \
    "nodes/${ctl}/mm-tools/poollimits/${pool}" -H 'Content-Type: application/json' --data "$payload")
[[ $(http_code "$out") == 403 ]] || lab_fail "token proibido: HTTP $(http_code "$out")"
lab_ssh "$ctl" pveum user add "$audit_user" --comment 'Rock 7 e2e: Pool.Audit' >/dev/null
lab_ssh "$ctl" pveum role add "$audit_role" --privs Pool.Audit >/dev/null
lab_ssh "$ctl" pveum acl modify "/pool/${pool}" --users "$audit_user" --roles "$audit_role" >/dev/null
lab_ssh "$ctl" bash -s -- "$audit_user" "$audit_token" "$audit_secret" <<'REMOTE'
set -euo pipefail
umask 077
pveum user token add "$1" "$2" --privsep 0 --output-format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])' > "$3"
REMOTE
out=$(api --as "${audit_user}!${audit_token}" "$audit_secret" GET "nodes/${ctl}/mm-tools/poollimits/${pool}")
[[ $(http_code "$out") == 200 ]] || lab_fail "Pool.Audit GET: HTTP $(http_code "$out")"
[[ $(jget "$(http_body "$out")" "d['data']['can_edit']") == 0 ]] || lab_fail 'Pool.Audit recebeu can_edit 1'
out=$(api --as "${audit_user}!${audit_token}" "$audit_secret" PUT "nodes/${ctl}/mm-tools/poollimits/${pool}" \
    -H 'Content-Type: application/json' --data "$payload")
[[ $(http_code "$out") == 403 ]] || lab_fail "Pool.Audit PUT: HTTP $(http_code "$out")"
lab_pass 'token proibido 403; Pool.Audit lê com can_edit 0 e recebe 403 no PUT'

lab_step 'poollimits: desligar reverte os patches nos 3 nodes e libera o aumento'
limits "$pool" allocated 2 512 off off
refuse 'aumento antes de desligar' "$(limit_re "$pool" vCPU)" "$ctl" qm set "$qmain" --cores 2
lab_ssh "$ctl" mm-pve config set-module poollimits --disable >/dev/null
wait_patches not_applied || lab_fail 'patches não reverteram nos 3 nodes'
lab_ssh "$ctl" qm set "$qmain" --cores 2 >/dev/null || lab_fail 'aumento recusado com o módulo desligado'
lab_pass 'módulo desligado: patches revertidos nos 3 nodes e aumento liberado'

printf 'NÃO PROVADO: replication (sem storage replicável em dois nodes neste lab)\n'
printf 'NÃO PROVADO: OVA (sem imagem OVA no lab; import de disco provado acima)\n'
lab_pass 'e2e poollimits concluído'
