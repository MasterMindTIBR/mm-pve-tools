#!/usr/bin/env bash
# Prova do módulo updates no cluster do lab: status e refresh pela API, job
# avulso que traz de volta um pacote alvo rebaixado (triggers, patches e
# daemons), segundo job recusado com o worker rodando, log, bulk sequencial e
# paralelo com nodes remotos, lost simulado, recusas de reboot e o reboot real
# pelo endpoint num node com kernel mais novo instalado.
# shellcheck disable=SC2016  # ${Version} vai literal para o dpkg-query remoto
set -euo pipefail
# Falha dentro de $(...) também interrompe (o bash não herda -e sem isto).
shopt -s inherit_errexit

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_NODE1 LAB_NODE2 LAB_NODE3 LAB_API_CA_FILE \
    LAB_ALLOWED_TOKEN_ID LAB_ALLOWED_TOKEN_SECRET_FILE LAB_API_SCHEME LAB_API_PORT LAB_EVIDENCE_DIR
lab_init_evidence

nodes=("$LAB_NODE1" "$LAB_NODE2" "$LAB_NODE3")
state_dir=/etc/pve/mm-tools/updates
job_node=${LAB_UPDATES_JOB_NODE:-$LAB_NODE3}
lost_node=${LAB_UPDATES_LOST_NODE:-$LAB_NODE2}
reboot_node=${LAB_UPDATES_REBOOT_NODE:-$LAB_NODE3}
target_pkg=${LAB_UPDATES_TARGET_PACKAGE:-pve-manager}
lost_backup=/run/mm-pve-e2e-updates-lost.json
module_was_on=''

jget() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

# api METHOD PATH [curl args...]: chamada com o token permitido a partir do
# node de controle; imprime "HTTP <código>" na 1ª linha e o corpo na 2ª.
api() {
    lab_ssh "$LAB_NODE1" bash -s -- "$(lab_node_url "$LAB_NODE1")" "$LAB_API_CA_FILE" \
        "$LAB_ALLOWED_TOKEN_ID" "$LAB_ALLOWED_TOKEN_SECRET_FILE" "$@" <<'REMOTE'
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

# api_ok METHOD PATH [...]: exige HTTP 200 e devolve só o corpo.
api_ok() {
    local out code
    out=$(api "$@")
    code=$(sed -n '1s/^HTTP //p' <<<"$out")
    [[ $code == 200 ]] || { lab_fail "$1 $2: HTTP $code $(sed -n '2p' <<<"$out" | head -c 300)"; return 1; }
    sed -n '2,$p' <<<"$out"
}

node_job() {
    local node=$1
    lab_ssh "$node" python3 -c "
import json, os
p = '$state_dir/$node.json'
s = json.load(open(p)) if os.path.exists(p) else {}
print(s.get('id') or '-', s.get('state') or '-', 'launching' if s.get('launching') else 'ready')"
}

wait_job_done() {
    local node=$1 id=$2 line state
    for _ in $(seq 1 270); do
        line=$(node_job "$node")
        state=$(awk '{print $2}' <<<"$line")
        if [[ $(awk '{print $1}' <<<"$line") == "$id" ]]; then
            case $state in succeeded|failed|lost) printf '%s\n' "$state"; return 0 ;; esac
        fi
        sleep 10
    done
    lab_fail "job $id em $node não terminou em 45 min"
}

wait_task() {
    local node=$1 upid=$2 body status
    for _ in $(seq 1 60); do
        body=$(api_ok GET "nodes/${node}/tasks/$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$upid")/status")
        status=$(jget "$body" "d['data'].get('status')")
        if [[ $status == stopped ]]; then jget "$body" "d['data'].get('exitstatus')"; return 0; fi
        sleep 2
    done
    lab_fail "task $upid não terminou"
}

wait_bulk() {
    local id=$1 state
    for _ in $(seq 1 360); do
        state=$(lab_ssh "$LAB_NODE1" python3 -c "import json; print(json.load(open('$state_dir/bulk-$id.json')).get('state'))")
        case $state in succeeded|failed) break ;; esac
        sleep 10
    done
    lab_ssh "$LAB_NODE1" python3 -c "
import json
d = json.load(open('$state_dir/bulk-$id.json'))
print('estado', d['state'], 'modo', d.get('mode'), 'pedido_por', d.get('requested_by'))
for n, r in sorted((d.get('results') or {}).items()):
    print(' ', n, 'iniciado' if r.get('ok') else 'erro=' + str(r.get('error')).strip(),
          'upid' if r.get('upid') else 'local', (r.get('result') or {}).get('state'))
"
}

# Com o node desligando o ssh pode travar: sempre com timeout.
boot_id() { timeout 20 ssh -F "$LAB_SSH_CONFIG" -o ConnectTimeout=5 "$1" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; }

restore_state() {
    if [[ -n $module_was_on && $module_was_on == 0 ]]; then
        lab_ssh "$LAB_NODE1" mm-pve config set-module updates --disable >/dev/null 2>&1 || true
    fi
    lab_ssh "$lost_node" bash -c "if [ -f $lost_backup ]; then cp $lost_backup $state_dir/$lost_node.json && rm -f $lost_backup; fi" \
        >/dev/null 2>&1 || true
}
trap restore_state EXIT

lab_step 'updates: liga o módulo'
module_was_on=$(lab_ssh "$LAB_NODE1" python3 -c "import json; print(1 if (json.load(open('/etc/pve/mm-tools/config.json')).get('modules') or {}).get('updates') else 0)")
lab_ssh "$LAB_NODE1" mm-pve config set-module updates --enable >/dev/null
lab_pass "módulo updates ligado (antes: $module_was_on)"

lab_step 'updates: status dos 3 nodes pela API'
for n in "${nodes[@]}"; do
    body=$(api_ok GET "nodes/${n}/mm-tools/updates/status")
    jget "$body" "'%s: pendentes=%d kernel=%s mais_novo=%s reboot=%s dpkg_lock=%s' % (d['data']['node'], len(d['data']['pending']), d['data']['kernel']['running'], (d['data']['kernel'].get('newest_installed') or {}).get('release'), d['data']['kernel']['reboot_suggested'], d['data']['dpkg_locked'])"
done
lab_pass 'status responde nos 3 nodes'

lab_step "updates: refresh no $LAB_NODE2"
api_ok POST "nodes/${LAB_NODE2}/mm-tools/updates/refresh" >/dev/null
lab_pass 'refresh aceito'

lab_step "updates: rebaixa $target_pkg no $job_node"
read -r installed older < <(lab_ssh "$job_node" bash -s -- "$target_pkg" <<'REMOTE'
set -euo pipefail
pkg=$1
installed=$(dpkg-query -W -f='${Version}' "$pkg")
older=$(apt-cache madison "$pkg" | awk '{print $3}' | sort -u | while read -r v; do
    if dpkg --compare-versions "$v" lt "$installed"; then echo "$v"; fi; done | sort -V | tail -1)
printf '%s %s\n' "$installed" "${older:-}"
REMOTE
)
[[ -n ${older:-} ]] || lab_fail "não há versão anterior de $target_pkg no repositório"
lab_ssh "$job_node" env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
    -o Dpkg::Options::=--force-confold "${target_pkg}=${older}" >/dev/null
now=$(lab_ssh "$job_node" dpkg-query -W -f='${Version}' "$target_pkg")
[[ $now == "$older" ]] || lab_fail "$target_pkg ficou em $now, esperado $older"
lab_ssh "$job_node" mm-pve status | grep -E '^patch (index_tpl|nodes_pm): applied' >/dev/null \
    || lab_fail 'patches do núcleo não ficaram aplicados depois do downgrade'
lab_pass "$target_pkg $installed -> $older; trigger reaplicou os patches"

lab_step "updates: job avulso no $job_node pela API, segundo job recusado"
job_start=$(lab_ssh "$job_node" date +%s)
api_ok POST "nodes/${job_node}/mm-tools/updates/run" >/dev/null
job_id=''
for _ in $(seq 1 60); do
    read -r jid jstate jlaunch < <(node_job "$job_node")
    if [[ $jstate == running && $jlaunch == ready ]]; then job_id=$jid; break; fi
    sleep 1
done
[[ -n $job_id ]] || lab_fail 'o worker do job não começou a rodar'
unit_state=$(lab_ssh "$job_node" systemctl show -p ActiveState --value "mm-pve-update-${job_id}")
second=$(api_ok POST "nodes/${job_node}/mm-tools/updates/run")
second_exit=$(wait_task "$job_node" "$(jget "$second" "d['data']")")
[[ $second_exit != OK ]] || lab_fail 'segundo job foi aceito com o primeiro rodando'
read -r still _ < <(node_job "$job_node")
[[ $still == "$job_id" ]] || lab_fail 'o segundo pedido trocou o job atual'
printf 'unit do job: %s; segundo pedido: %s\n' "$unit_state" "$second_exit"
final=$(wait_job_done "$job_node" "$job_id")
[[ $final == succeeded ]] || lab_fail "job terminou em $final"
back=$(lab_ssh "$job_node" dpkg-query -W -f='${Version}' "$target_pkg")
[[ $back == "$installed" ]] || lab_fail "$target_pkg voltou para $back, esperado $installed"
lab_ssh "$job_node" mm-pve status | grep -E '^patch (index_tpl|nodes_pm): applied' >/dev/null \
    || lab_fail 'patches do núcleo não ficaram aplicados depois do job'
# O postinst do pve-manager faz reload (o timestamp da unit não muda): o
# journal do pveproxy desde o início do job mostra o restart do servidor.
lab_ssh "$job_node" journalctl -u pveproxy --since "@${job_start}" -o cat --no-pager \
    | grep -Eiq 'restart|reload' || lab_fail 'pveproxy não foi recarregado pelo upgrade'
lab_ssh "$job_node" systemctl is-active --quiet pveproxy pvedaemon || lab_fail 'pveproxy/pvedaemon inativos'
log_body=$(api_ok GET "nodes/${job_node}/mm-tools/updates/log?job=${job_id}&start=0&limit=1000")
jget "$log_body" "any('$target_pkg' in l for l in d['data']['lines'])" | grep -qx True \
    || lab_fail "log do job não cita $target_pkg"
lab_pass "job $final; $target_pkg $older -> $back; patches aplicados; pveproxy recarregado; log pela API"

lab_step "updates: bulk sequencial $LAB_NODE1,$job_node (remoto) pela API"
body=$(api_ok POST "nodes/${LAB_NODE1}/mm-tools/updates/bulk" \
    --data-urlencode "nodes=${LAB_NODE1},${job_node}" --data-urlencode mode=sequential)
jget "$body" "'preflight: ' + str(d['data']['preflight'])"
summary=$(wait_bulk "$(jget "$body" "d['data']['bulk_id']")")
printf '%s\n' "$summary"
grep -q '^estado succeeded' <<<"$summary" || lab_fail 'bulk sequencial não terminou em succeeded'
lab_pass 'bulk sequencial com node remoto'

lab_step 'updates: bulk paralelo nos 3 nodes pela API'
body=$(api_ok POST "nodes/${LAB_NODE1}/mm-tools/updates/bulk" \
    --data-urlencode "nodes=${LAB_NODE1},${LAB_NODE2},${LAB_NODE3}" --data-urlencode mode=parallel)
summary=$(wait_bulk "$(jget "$body" "d['data']['bulk_id']")")
printf '%s\n' "$summary"
grep -q '^estado succeeded' <<<"$summary" || lab_fail 'bulk paralelo não terminou em succeeded'
(( $(grep -c ' succeeded$' <<<"$summary") == 3 )) || lab_fail 'algum node do bulk paralelo não terminou'
lab_pass 'bulk paralelo nos 3 nodes'

lab_step "updates: job perdido simulado no $lost_node"
lab_ssh "$lost_node" bash -s -- "$state_dir" "$lost_node" "$lost_backup" <<'REMOTE'
set -euo pipefail
dir=$1 node=$2 backup=$3
[ -f "$dir/$node.json" ] && cp "$dir/$node.json" "$backup"
python3 - "$dir/$node.json" <<'PY'
import json, sys, uuid
jid = str(uuid.uuid4())
json.dump({'id': jid, 'node': sys.argv[1].rsplit('/', 1)[1][:-5], 'state': 'running',
           'requested_by': 'root@pam', 'created': 'e2e', 'unit': 'mm-pve-update-' + jid,
           'log': '/var/log/mm-pve-tools/updates/' + jid + '.log'}, open(sys.argv[1], 'w'))
print(jid)
PY
REMOTE
lost=$(lab_ssh "$lost_node" mm-pve --json updates status --node "$lost_node" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["state"])')
[[ $lost == lost ]] || lab_fail "job sem unit ficou em $lost"
lab_ssh "$lost_node" bash -c "rm -f $state_dir/$lost_node-\$(python3 -c \"import json; print(json.load(open('$state_dir/$lost_node.json'))['id'])\").json; if [ -f $lost_backup ]; then cp $lost_backup $state_dir/$lost_node.json && rm -f $lost_backup; else rm -f $state_dir/$lost_node.json; fi"
lab_pass 'unit inexistente vira lost'

lab_step "updates: recusas de reboot no $reboot_node"
out=$(api POST "nodes/${reboot_node}/mm-tools/updates/reboot" --data-urlencode "confirm=${reboot_node}")
[[ $(sed -n '1s/^HTTP //p' <<<"$out") == 403 ]] || lab_fail "token sem Sys.PowerMgmt não recebeu 403: $(head -c 200 <<<"$out")"
if lab_ssh "$reboot_node" mm-pve updates reboot --node "$reboot_node" >/dev/null 2>&1; then lab_fail 'CLI aceitou reboot sem confirm'; fi
if lab_ssh "$reboot_node" mm-pve updates reboot --node "$reboot_node" --confirm nome-errado >/dev/null 2>&1; then
    lab_fail 'CLI aceitou reboot com confirm errado'
fi
lab_pass 'API sem Sys.PowerMgmt = 403; CLI sem confirm e com confirm errado recusam'

lab_step "updates: reboot real pelo endpoint no $reboot_node"
kernel=$(lab_ssh "$reboot_node" mm-pve --json updates status --node "$reboot_node" \
    | python3 -c 'import json,sys; k=json.load(sys.stdin)["kernel"]; print(k["reboot_suggested"], (k.get("newest_installed") or {}).get("release"), k["running"])')
read -r suggested newest running <<<"$kernel"
if [[ $suggested != 1 ]]; then
    # Sem kernel novo pendente: sobe uma vez no kernel anterior (pin só no
    # próximo boot) para o mais novo instalado voltar a ser sugestão.
    previous=$(lab_ssh "$reboot_node" bash -c "ls /boot/vmlinuz-*-pve | sed 's|/boot/vmlinuz-||' | sort -V | grep -vx '$running' | tail -1")
    [[ -n $previous ]] || lab_fail 'só há um kernel instalado; instale outro para provar o reboot'
    before=$(boot_id "$reboot_node")
    lab_ssh "$reboot_node" proxmox-boot-tool kernel pin "$previous" --next-boot >/dev/null
    lab_ssh "$reboot_node" systemctl reboot >/dev/null 2>&1 || true
    for _ in $(seq 1 90); do sleep 10; now_id=$(boot_id "$reboot_node"); [[ -n $now_id && $now_id != "$before" ]] && break; done
    kernel=$(lab_ssh "$reboot_node" mm-pve --json updates status --node "$reboot_node" \
        | python3 -c 'import json,sys; k=json.load(sys.stdin)["kernel"]; print(k["reboot_suggested"], (k.get("newest_installed") or {}).get("release"), k["running"])')
    read -r suggested newest running <<<"$kernel"
    [[ $suggested == 1 ]] || lab_fail "sugestão de reboot não apareceu (rodando $running, mais novo $newest)"
fi
printf 'antes: rodando %s, mais novo instalado %s, sugestão %s\n' "$running" "$newest" "$suggested"
before=$(boot_id "$reboot_node")
# A resposta pode se perder com o node desligando; a prova é o boot_id novo.
lab_ssh "$LAB_NODE1" pvesh create "/nodes/${reboot_node}/mm-tools/updates/reboot" --confirm "$reboot_node" \
    --output-format json >/dev/null 2>&1 || true
back_id=''
for _ in $(seq 1 90); do
    sleep 10
    back_id=$(boot_id "$reboot_node")
    [[ -n $back_id && $back_id != "$before" ]] && break
done
[[ -n $back_id && $back_id != "$before" ]] || lab_fail "$reboot_node não voltou em 15 min"
for _ in $(seq 1 30); do
    lab_ssh "$reboot_node" pvecm status 2>/dev/null | grep -q '^Quorate:.*Yes' && break
    sleep 5
done
kernel=$(lab_ssh "$reboot_node" mm-pve --json updates status --node "$reboot_node" \
    | python3 -c 'import json,sys; k=json.load(sys.stdin)["kernel"]; print(k["reboot_suggested"], k["running"])')
read -r suggested running <<<"$kernel"
[[ $running == "$newest" ]] || lab_fail "voltou no kernel $running, esperado $newest"
[[ $suggested == 0 ]] || lab_fail 'sugestão de reboot continua depois do reboot'
lab_ssh "$reboot_node" systemctl is-active --quiet pveproxy pvedaemon || lab_fail 'serviços do PVE inativos depois do reboot'
lab_pass "reboot real: voltou no kernel $running, quorum ok, sugestão sumiu"

lab_pass 'e2e updates concluído'
