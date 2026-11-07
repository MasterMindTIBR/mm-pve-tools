#!/usr/bin/env bash
# Liga o módulo ui, prova o padrão de console do cluster servido por cada node,
# a preferência por usuário (token conta como o usuário dono), a recusa do
# padrão do cluster sem Sys.Modify e o desligamento, que remove o JSON.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_NODE1 LAB_NODE2 LAB_NODE3 LAB_API_CA_FILE \
    LAB_ALLOWED_TOKEN_ID LAB_ALLOWED_TOKEN_SECRET_FILE \
    LAB_FORBIDDEN_TOKEN_ID LAB_FORBIDDEN_TOKEN_SECRET_FILE \
    LAB_API_SCHEME LAB_API_PORT LAB_EVIDENCE_DIR
lab_init_evidence

control_log="${LAB_EVIDENCE_RUN_DIR}/e2e-ui.log"
: >"$control_log"
nodes=("$LAB_NODE1" "$LAB_NODE2" "$LAB_NODE3")
saved_state="/run/mm-pve-ui-e2e-state.json"
restore_pending=0

# Executa um bloco no node de controle com os dois tokens disponíveis.
# Uso: remote <modo> [args...]; o modo escolhe o trecho do script remoto.
remote() {
    lab_ssh "$LAB_NODE1" bash -s -- "$LAB_NODE1" "$(lab_node_url "$LAB_NODE1")" \
        "$LAB_API_CA_FILE" "$LAB_ALLOWED_TOKEN_ID" "$LAB_ALLOWED_TOKEN_SECRET_FILE" \
        "$LAB_FORBIDDEN_TOKEN_ID" "$LAB_FORBIDDEN_TOKEN_SECRET_FILE" "$saved_state" "$@" <<'REMOTE'
set -euo pipefail
node=$1 api_base=$2 ca=$3 allowed_id=$4 allowed_file=$5 forbidden_id=$6 forbidden_file=$7 saved=$8
mode=$9
shift 9
allowed_secret=$(tr -d '\r\n' < "$allowed_file")
forbidden_secret=$(tr -d '\r\n' < "$forbidden_file")
# usados por nameref em api()
# shellcheck disable=SC2034
allowed=(--header "Authorization: PVEAPIToken=${allowed_id}=${allowed_secret}")
# shellcheck disable=SC2034
forbidden=(--header "Authorization: PVEAPIToken=${forbidden_id}=${forbidden_secret}")
base="${api_base}/api2/json/nodes/${node}/mm-tools"
tmp=$(mktemp -d /run/mm-pve-ui-e2e.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT

# api <auth-array-name> <method> <path> [curl data args...] -> grava $tmp/body, devolve o HTTP
api() {
    local -n auth=$1
    local method=$2 path=$3
    shift 3
    curl --silent --show-error --cacert "$ca" "${auth[@]}" -X "$method" "$@" \
        -o "$tmp/body" -w '%{http_code}' "${base}/${path}"
}

json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['data']; print(eval(sys.argv[2]))" "$tmp/body" "$1"; }

put_section() {
    local section=$1 value=$2 code
    code=$(api allowed GET config)
    [[ $code == 200 ]] || { printf 'config: HTTP %s\n' "$code" >&2; return 1; }
    local digest
    digest=$(json "d['digest']")
    code=$(api allowed PUT "config/${section}" --data-urlencode "digest=${digest}" \
        --data-urlencode "value=${value}")
    [[ $code == 200 ]] || { printf 'PUT config/%s: HTTP %s %s\n' "$section" "$code" "$(cat "$tmp/body")" >&2; return 1; }
}

case $mode in
save)
    # Guarda modules.ui e a seção ui para devolver depois.
    code=$(api allowed GET config)
    [[ $code == 200 ]] || { printf 'config: HTTP %s\n' "$code" >&2; exit 1; }
    python3 - "$tmp/body" "$saved" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))["data"]["config"]
state = {"modules": data.get("modules") or {}, "ui": data.get("ui")}
with open(sys.argv[2], "w") as fh:
    json.dump(state, fh)
PY
    printf 'estado anterior guardado\n'
    ;;
enable)
    modules=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["modules"]; m["ui"]=1; print(json.dumps(m))' "$saved")
    put_section modules "$modules"
    put_section ui '{"console":{"qemu":"html5","lxc":"xtermjs"},"hide_subscription_popup":1}'
    code=$(api allowed GET config)
    revision=$(json "d['config']['revision']")
    printf 'ui ligado; revision %s\n' "$revision"
    printf '%s\n' "$revision" > "${saved}.revision"
    ;;
static)
    # O JSON servido pelo pveproxy de cada node reflete o padrão do cluster.
    revision=$(cat "${saved}.revision")
    for target in "$@"; do
        url="${api_base/${node}/${target}}/pve2/js/mm-ui.json?v=$$"
        code=$(curl --silent --show-error --cacert "$ca" -o "$tmp/static" -w '%{http_code}' "$url")
        [[ $code == 200 ]] || { printf '%s: mm-ui.json HTTP %s\n' "$target" "$code" >&2; exit 1; }
        python3 - "$tmp/static" "$revision" "$target" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["console"] == {"qemu": "html5", "lxc": "xtermjs"}, d
assert d["hide_subscription_popup"] == 1, d
assert int(d["revision"]) == int(sys.argv[2]), (d["revision"], sys.argv[2])
print(f"{sys.argv[3]}: mm-ui.json OK (revision {d['revision']})")
PY
    done
    ;;
preference)
    owner=${allowed_id%%!*}
    code=$(api allowed PUT ui/preference --data-urlencode qemu=vv)
    [[ $code == 200 ]] || { printf 'PUT preferência: HTTP %s %s\n' "$code" "$(cat "$tmp/body")" >&2; exit 1; }
    code=$(api allowed GET ui)
    [[ $code == 200 ]]
    [[ $(json "d['preference']['qemu']") == vv ]] || { printf 'preferência não gravada\n' >&2; exit 1; }
    [[ $(json "d['effective']['qemu']") == vv ]]
    [[ $(json "d['effective']['lxc']") == xtermjs ]]
    [[ $(json "d['user']") == "$owner" ]] || { printf 'principal não é o dono do token\n' >&2; exit 1; }
    python3 - /etc/pve/mm-tools/ui-users.json "$owner" <<'PY'
import json, sys
users = json.load(open(sys.argv[1]))
assert sys.argv[2] in users, users.keys()
assert not any("!" in key for key in users), users.keys()
print("ui-users.json grava o usuário dono, sem o id do token")
PY
    # Token sem permissão de cluster: grava a própria preferência, mas não o padrão.
    code=$(api forbidden PUT ui/preference --data-urlencode lxc=html5)
    [[ $code == 200 ]] || { printf 'token sem Sys.Modify não gravou a própria preferência: HTTP %s\n' "$code" >&2; exit 1; }
    code=$(api forbidden PUT config/ui --data-urlencode 'value={"console":{"qemu":"vv","lxc":"vv"}}')
    [[ $code == 403 ]] || { printf 'token sem Sys.Modify mudou o padrão do cluster: HTTP %s\n' "$code" >&2; exit 1; }
    code=$(api allowed GET ui)
    [[ $(json "d['preference']['lxc']") == cluster ]] || { printf 'preferência de outro usuário vazou\n' >&2; exit 1; }
    # "cluster" volta a seguir o padrão do cluster.
    code=$(api allowed PUT ui/preference --data-urlencode qemu=cluster)
    [[ $code == 200 ]]
    code=$(api allowed GET ui)
    [[ $(json "d['preference']['qemu']") == cluster ]]
    [[ $(json "d['effective']['qemu']") == html5 ]]
    printf 'preferência por usuário OK\n'
    ;;
disable)
    modules=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["modules"]; m["ui"]=0; print(json.dumps(m))' "$saved")
    put_section modules "$modules"
    printf 'módulo ui desligado\n'
    ;;
cleanup-prefs)
    api allowed PUT ui/preference --data-urlencode qemu=cluster --data-urlencode lxc=cluster >/dev/null || true
    api forbidden PUT ui/preference --data-urlencode qemu=cluster --data-urlencode lxc=cluster >/dev/null || true
    printf 'preferências de teste removidas\n'
    ;;
restore)
    python3 - "$saved" "$tmp/modules" "$tmp/ui" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
json.dump(state["modules"], open(sys.argv[2], "w"))
json.dump(state["ui"] or {"console": {"qemu": "default", "lxc": "default"}, "hide_subscription_popup": 0},
          open(sys.argv[3], "w"))
PY
    put_section ui "$(cat "$tmp/ui")"
    put_section modules "$(cat "$tmp/modules")"
    rm -f -- "$saved" "${saved}.revision"
    printf 'módulo ui e seção ui de volta ao estado anterior\n'
    ;;
absent)
    for target in "$@"; do
        url="${api_base/${node}/${target}}/pve2/js/mm-ui.json?v=$$"
        code=$(curl --silent --cacert "$ca" -o /dev/null -w '%{http_code}' "$url" || true)
        [[ $code != 200 ]] || { printf '%s: mm-ui.json ainda servido depois de desligar\n' "$target" >&2; exit 1; }
        printf '%s: mm-ui.json ausente (HTTP %s)\n' "$target" "$code"
    done
    ;;
*)
    printf 'modo remoto desconhecido: %s\n' "$mode" >&2
    exit 2
    ;;
esac
REMOTE
}

apply_all() {
    local node
    for node in "${nodes[@]}"; do
        lab_ssh "$node" mm-pve apply --no-patches >>"$control_log" 2>&1 \
            || lab_fail "apply falhou em $node"
    done
}

cleanup() {
    if (( restore_pending )); then
        printf 'AVISO: teste interrompido; devolvendo o módulo ui ao estado anterior\n' >&2
        remote cleanup-prefs >>"$control_log" 2>&1 || true
        remote restore >>"$control_log" 2>&1 || printf 'AVISO: não consegui devolver a config do ui\n' >&2
        local node
        for node in "${nodes[@]}"; do
            lab_ssh "$node" mm-pve apply --no-patches >>"$control_log" 2>&1 \
                || printf 'AVISO: apply de limpeza falhou em %s\n' "$node" >&2
        done
    fi
}
trap cleanup EXIT INT TERM

lab_step 'ui: guarda o estado e liga o módulo com padrão por tipo'
remote save >>"$control_log" 2>&1 || lab_fail 'não guardei o estado anterior do ui'
restore_pending=1
remote enable >>"$control_log" 2>&1 || lab_fail 'não liguei o módulo ui'
apply_all

lab_step 'ui: JSON estático servido pelos 3 nodes'
remote static "${nodes[@]}" >>"$control_log" 2>&1 || lab_fail 'mm-ui.json não reflete o padrão do cluster'
for node in "${nodes[@]}"; do
    lab_ssh "$node" mm-pve --json status >"${LAB_EVIDENCE_RUN_DIR}/e2e-ui-status-${node}.json" 2>>"$control_log" \
        || lab_fail "mm-pve status falhou em $node"
    python3 - "${LAB_EVIDENCE_RUN_DIR}/e2e-ui-status-${node}.json" "$node" <<'PY' >>"$control_log" \
        || lab_fail "bundles do PVE incompatíveis com o módulo ui em $node"
import json, sys
check = json.load(open(sys.argv[1]))["modules"]["ui"]["check"]
assert check["ok"], check
print(f"{sys.argv[2]}: símbolos dos bundles compatíveis")
PY
done

lab_step 'ui: preferência por usuário e permissões'
remote preference >>"$control_log" 2>&1 || lab_fail 'preferência por usuário falhou'
remote cleanup-prefs >>"$control_log" 2>&1 || true

lab_step 'ui: desligar remove o JSON dos 3 nodes'
remote disable >>"$control_log" 2>&1 || lab_fail 'não desliguei o módulo ui'
apply_all
remote absent "${nodes[@]}" >>"$control_log" 2>&1 || lab_fail 'mm-ui.json continuou servido depois de desligar'

lab_step 'ui: devolve o estado anterior'
remote restore >>"$control_log" 2>&1 || lab_fail 'não devolvi a config do ui'
apply_all
restore_pending=0

lab_pass 'ui: padrão do cluster, preferência por usuário, permissões e desligamento'
