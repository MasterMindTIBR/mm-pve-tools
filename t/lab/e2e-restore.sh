#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
# Publica, valida e revoga duas sessões de restore no laboratório.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_WINLAB_NODE LAB_WINLAB_VMID LAB_WINLAB_NAME \
    LAB_WINLAB_NIC_KEY LAB_WINLAB_NIC_MAC LAB_WINLAB_MARKER_TAG LAB_WINLAB_IP \
    LAB_RESTORE_PREFIX LAB_RESTORE_VLAN LAB_RESTORE_PATH_B64 LAB_MANIFEST_FILE \
    LAB_PBS_STORAGE LAB_API_CA_FILE LAB_ALLOWED_TOKEN_ID LAB_ALLOWED_TOKEN_SECRET_FILE \
    LAB_API_SCHEME LAB_API_PORT LAB_GATEWAY_NODE LAB_GATEWAY_VMID LAB_EVIDENCE_DIR
lab_init_evidence
[[ -r $LAB_MANIFEST_FILE ]] || lab_fail 'manifest-P.sha256 não é legível'

manifest_remote="/tmp/mm-pve-restore-${$}.manifest"
output="${LAB_EVIDENCE_RUN_DIR}/e2e-restore.log"
: >"$output"
cleanup_operator() {
    local rc=0
    lab_ssh "$LAB_WINLAB_NODE" rm -f -- "$manifest_remote" >>"$output" 2>&1 || rc=$?
    if (( rc != 0 )); then
        printf 'AVISO: não removi manifest temporário do node (rc=%s)\n' "$rc" >&2
    fi
}
trap cleanup_operator EXIT INT TERM
scp_rc=0
lab_scp_to "$LAB_MANIFEST_FILE" "$LAB_WINLAB_NODE" "$manifest_remote" >>"$output" 2>&1 || scp_rc=$?
(( scp_rc == 0 )) || lab_fail 'não transferi o manifest para o node do Windows'

lab_step 'restore: QGA, NIC VLAN e usuário/token temporário'
rc=0
lab_ssh "$LAB_WINLAB_NODE" bash -s -- \
    "$LAB_WINLAB_NODE" "$LAB_WINLAB_VMID" "$LAB_WINLAB_NAME" "$LAB_WINLAB_NIC_KEY" \
    "$LAB_WINLAB_NIC_MAC" "$LAB_WINLAB_MARKER_TAG" "$LAB_WINLAB_IP" "$LAB_RESTORE_PREFIX" \
    "$LAB_RESTORE_VLAN" "$LAB_RESTORE_PATH_B64" "$manifest_remote" "$LAB_PBS_STORAGE" \
    "$LAB_API_CA_FILE" "$LAB_ALLOWED_TOKEN_ID" "$LAB_ALLOWED_TOKEN_SECRET_FILE" \
    "$LAB_API_SCHEME" "$LAB_API_PORT" "$LAB_GATEWAY_NODE" "$LAB_GATEWAY_VMID" \
    >"$output" 2>&1 <<'REMOTE' || rc=$?
set -euo pipefail
pve_node=$1
winlab=$2
expected_name=$3
nic_key=$4
nic_mac=$5
marker_tag=$6
win_ip=$7
prefix=$8
vlan=$9
path_b64=${10}
manifest=${11}
pbs_storage=${12}
ca=${13}
allowed_id=${14}
allowed_file=${15}
api_scheme=${16}
api_port=${17}
gateway_node=${18}
gateway_vmid=${19}
api_base="${api_scheme}://${pve_node}:${api_port}"
tmp=$(mktemp -d /run/mm-pve-restore.XXXXXX)
token_file="$tmp/token.secret"
test_user="mm-lab-restore-${$}@pve"
test_token='publish'
session_one=''

session_two=''
nic_added=0
tag_added=0
api_token_id=''

qga_exec() {
    local qnode=$1 qvmid=$2
    shift 2
    local out pid status rc=0 misses=0
    local -a cmd=(pvesh create "/nodes/$qnode/qemu/$qvmid/agent/exec" --output-format json)
    local arg
    for arg in "$@"; do cmd+=(--command "$arg"); done
    if [[ -n ${QGA_INPUT_DATA:-} ]]; then cmd+=(--input-data "$QGA_INPUT_DATA"); fi
    out=$("${cmd[@]}" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
    pid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])' <<<"$out")
    while :; do
        # o agente do Windows pode engasgar (ex.: driver da placa recém-plugada);
        # tolera falhas seguidas por até ~2 min antes de desistir
        if ! status=$(pvesh get "/nodes/$qnode/qemu/$qvmid/agent/exec-status" --pid "$pid" --output-format json 2>&1); then
            misses=$((misses + 1))
            (( misses < 40 )) || { printf '%s\n' "$status" >&2; return 1; }
            sleep 3
            continue
        fi
        misses=0
        if [[ $(python3 -c 'import json,sys; print(int(json.load(sys.stdin).get("exited",0)))' <<<"$status") == 1 ]]; then
            rc=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("exitcode",0))' <<<"$status")
            python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data", ""), end="")' <<<"$status"
            if (( rc != 0 )); then
                python3 -c 'import json,sys; print(json.load(sys.stdin).get("err-data", ""), end="")' \
                    <<<"$status" >&2
                printf 'comando na VM %s falhou (rc=%s): %s\n' "$qvmid" "$rc" "$1" >&2
                return "$rc"
            fi
            return 0
        fi
        sleep 2
    done
}

ps_encoded() {
    printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0
}

api_request() {
    local method=$1 path=$2 body=$3 code=$4
    shift 4
    local secret
    secret=$(tr -d '\r\n' < "$token_file")
    curl --silent --show-error --cacert "$ca" \
        -H "Authorization: PVEAPIToken=${api_token_id}=${secret}" \
        -X "$method" -o "$body" -w '%{http_code}' "$@" "${api_base}${path}" >"$code"
}

# Confere o código HTTP de uma chamada api_request e, se não for o esperado,
# mostra a resposta (o corpo da API não traz o segredo do token).
expect_code() {
    local base=$1 expected=$2 got
    got=$(<"$base.code")
    [[ $got == "$expected" ]] && return 0
    printf 'API %s: HTTP %s (esperado %s): %s\n' "${base##*/}" "$got" "$expected" \
        "$(head -c 400 "$base" 2>/dev/null)" >&2
    return 1
}

task_wait() {
    local upid=$1 encoded status exit_status
    encoded=$(python3 - "$upid" <<'PY'
from urllib.parse import quote
import sys
print(quote(sys.argv[1], safe=''))
PY
)
    for _ in $(seq 1 180); do
        api_request GET "/api2/json/nodes/${pve_node}/tasks/${encoded}/status" "$tmp/task" "$tmp/task.code"
        status=$(python3 - "$tmp/task" <<'PY'
import json
from pathlib import Path
import sys
print(json.loads(Path(sys.argv[1]).read_text()).get("data", {}).get("status", ""))
PY
)
        if [[ $status == stopped ]]; then
            exit_status=$(python3 - "$tmp/task" <<'PY'
import json
from pathlib import Path
import sys
print(json.loads(Path(sys.argv[1]).read_text()).get("data", {}).get("exitstatus", ""))
PY
)
            if [[ $exit_status != OK ]]; then
                # o Task Log não traz a senha da sessão (vai só no resultado)
                printf 'tarefa PVE terminou com falha: %s\n' "$exit_status" >&2
                pvesh get "/nodes/${pve_node}/tasks/${upid}/log" --limit 40 --output-format json \
                    | python3 -c 'import json,sys; [print("  " + l.get("t", "")) for l in json.load(sys.stdin)]' >&2 || true
                return 1
            fi
            return 0
        fi
        sleep 2
    done
    printf 'timeout aguardando tarefa PVE\n' >&2
    return 1
}

revoke_session() {
    local sid=$1
    [[ -n $sid ]] || return 0
    api_request POST "/api2/json/nodes/${pve_node}/mm-tools/restore/revoke" "$tmp/revoke-$sid" "$tmp/revoke-$sid.code" \
        --data-urlencode "id=$sid"
    expect_code "$tmp/revoke-$sid" 200
    local upid
    upid=$(python3 - "$tmp/revoke-$sid" <<'PY'
import json
from pathlib import Path
import sys
print(json.loads(Path(sys.argv[1]).read_text()).get("data", ""))
PY
)
    task_wait "$upid"
}

# Tira o IP de teste da placa marcada antes de removê-la da VM.
win_ip_remove() {
    local script
    script="\$ProgressPreference='SilentlyContinue'; \$mac='$(tr ':' '-' <<<"$nic_mac")'; \$a=Get-NetAdapter | Where-Object { \$_.MacAddress -eq \$mac }; if (\$a) { Remove-NetIPAddress -InterfaceIndex \$a.ifIndex -IPAddress '$win_ip' -Confirm:\$false -ErrorAction SilentlyContinue }; exit 0"
    qga_exec "$pve_node" "$winlab" powershell.exe -NoProfile -NonInteractive \
        -EncodedCommand "$(ps_encoded "$script")" >/dev/null
}

cleanup() {
    local cleanup_rc=0 current_tags new_tags
    if [[ -n $session_two ]]; then revoke_session "$session_two" || cleanup_rc=1; fi
    if [[ -n $session_one ]]; then revoke_session "$session_one" || cleanup_rc=1; fi
    if (( nic_added )) && qm config "$winlab" 2>/dev/null | grep -Fq "$nic_mac"; then
        win_ip_remove || true
        qm set "$winlab" --delete "$nic_key" >/dev/null 2>&1 || cleanup_rc=1
    fi
    if (( tag_added )); then
        current_tags=$(qm config "$winlab" 2>/dev/null | sed -n 's/^tags: //p' || true)
        new_tags=$(tr ';' '\n' <<<"$current_tags" | grep -Fvx "$marker_tag" | paste -sd ';' - || true)
        qm set "$winlab" --tags "$new_tags" >/dev/null 2>&1 || cleanup_rc=1
    fi
    pveum user token remove "$test_user" "$test_token" >/dev/null 2>&1 || true
    pveum acl delete / --users "$test_user" >/dev/null 2>&1 || true
    pveum acl delete "/storage/$pbs_storage" --users "$test_user" >/dev/null 2>&1 || true
    pveum acl delete "/vms/$winlab" --users "$test_user" >/dev/null 2>&1 || true
    pveum user delete "$test_user" >/dev/null 2>&1 || true
    rm -rf -- "$tmp"
    return "$cleanup_rc"
}
trap cleanup EXIT INT TERM

config=$(qm config "$winlab")
[[ $config == *"name: $expected_name"* ]] || {
    printf 'VMID %s não corresponde ao nome esperado; recusando tocar nela\n' "$winlab" >&2
    exit 1
}
if [[ $config == *"${nic_mac}"* ]]; then
    [[ $config == *"${nic_key}:"* && $config == *"tag=${vlan}"* ]] || {
        printf 'NIC marcada existe com configuração inesperada; recusando tocar nela\n' >&2
        exit 1
    }
    nic_added=1
else
    [[ $config != *"${nic_key}:"* ]] || {
        printf '%s já está ocupado no winlab; recusando tocar NIC alheia\n' "$nic_key" >&2
        exit 1
    }
    bridge=$(sed -n 's/^net0: .*bridge=\([^,]*\).*/\1/p' <<<"$config")
    [[ -n $bridge ]] || { printf 'net0 do winlab não tem bridge\n' >&2; exit 1; }
    qm set "$winlab" --"$nic_key" "virtio=${nic_mac},bridge=${bridge},tag=${vlan}"
    nic_added=1
fi
current_tags=$(sed -n 's/^tags: //p' <<<"$config" || true)
if ! tr ';' '\n' <<<"$current_tags" | grep -Fqx "$marker_tag"; then
    new_tags=$(printf '%s\n%s\n' "$current_tags" "$marker_tag" | tr ';' '\n' | sed '/^$/d' | sort -u | paste -sd ';' -)
    qm set "$winlab" --tags "$new_tags" >/dev/null
    tag_added=1
fi

# O Windows guarda o IP do adaptador (mesmo MAC) entre execuções: só cria se
# ainda não existir, e qualquer outro erro aparece.
static_ip_script="\$ProgressPreference='SilentlyContinue'; \$mac='$(tr ':' '-' <<<"$nic_mac")'; \$a=Get-NetAdapter | Where-Object { \$_.MacAddress -eq \$mac }; if (-not \$a) { throw 'NIC marcada ausente' }; if (-not (Get-NetIPAddress -InterfaceIndex \$a.ifIndex -IPAddress '$win_ip' -ErrorAction SilentlyContinue)) { New-NetIPAddress -InterfaceIndex \$a.ifIndex -IPAddress '$win_ip' -PrefixLength $prefix -AddressFamily IPv4 -ErrorAction Stop | Out-Null }; exit 0"
qga_exec "$pve_node" "$winlab" powershell.exe -NoProfile -NonInteractive -EncodedCommand "$(ps_encoded "$static_ip_script")"

backup_json=$(pvesh get "/nodes/$pve_node/storage/$pbs_storage/content" --content backup --vmid "$winlab" --output-format json)
backup=$(python3 - "$backup_json" <<'PY'
import json
import sys
items = json.loads(sys.argv[1])
if isinstance(items, dict):
    items = items.get("data", [])
items = [item for item in items if isinstance(item, dict) and item.get("volid")]
if not items:
    raise SystemExit("nenhum backup PBS encontrado para winlab")
print(sorted(items, key=lambda item: item["volid"])[-1]["volid"])
PY
)

pveum user add "$test_user" --comment 'mm-pve-tools Rock 7 restore lab' >/dev/null
pveum acl modify / --users "$test_user" --roles PVEAuditor >/dev/null
# O publish exige o mesmo que o File Restore do PVE (check_volume_access
# 'backup'): Datastore.AllocateSpace no storage e VM.Backup na VM dona.
pveum acl modify "/storage/$pbs_storage" --users "$test_user" --roles PVEDatastoreUser >/dev/null
pveum acl modify "/vms/$winlab" --users "$test_user" --roles PVEVMUser >/dev/null
token_json="$tmp/token.json"
pveum user token add "$test_user" "$test_token" --privsep 0 --output-format json >"$token_json"
token_secret=$(python3 - "$token_json" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text())
if isinstance(data, dict):
    data = data.get("data", data)
value = data.get("value")
if not value:
    raise SystemExit("pveum não devolveu o segredo do token")
print(value)
PY
)
printf '%s\n' "$token_secret" >"$token_file"
chmod 0600 "$token_file"
api_token_id="${test_user}!${test_token}"

publish_once() {
    local label=$1 key upid result_file meta_file
    api_request POST "/api2/json/nodes/${pve_node}/mm-tools/restore/publish" "$tmp/publish-$label" "$tmp/publish-$label.code" \
        --data-urlencode "backup=$backup" --data-urlencode "path_b64=$path_b64" \
        --data-urlencode "vmid=$winlab" --data-urlencode "hours=1" \
        --data-urlencode "vm_ip=$win_ip" --data-urlencode "ticket=GLPI-7"
    expect_code "$tmp/publish-$label" 200
    upid=$(python3 - "$tmp/publish-$label" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text()).get("data", {})
print(data.get("upid", ""))
PY
)
    key=$(python3 - "$tmp/publish-$label" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text()).get("data", {})
print(data.get("result_key", ""))
PY
)
    [[ -n $upid && -n $key ]]
    task_wait "$upid"
    result_file="$tmp/result-$label"
    meta_file="$tmp/result-$label.meta"
    api_request GET "/api2/json/nodes/${pve_node}/mm-tools/restore/results/${key}" "$result_file" "$tmp/result-$label.code"
    expect_code "$tmp/result-$label" 200
    python3 - "$result_file" "$meta_file" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text()).get("data", {})
for field in ("unc", "user", "password", "expires_at"):
    if not data.get(field):
        raise SystemExit(f"resultado sem {field}")
Path(sys.argv[2]).write_text(json.dumps(data, separators=(",", ":")))
PY
    printf -v "SESSION_${label^^}_UNC" '%s' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["unc"])' "$meta_file")"
    printf -v "SESSION_${label^^}_USER" '%s' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user"])' "$meta_file")"
    printf -v "SESSION_${label^^}_PASSWORD" '%s' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["password"])' "$meta_file")"
    session_id=$(python3 - "$meta_file" <<'PY'
import json
import re
import sys
value = json.load(open(sys.argv[1]))["unc"]
match = re.search(r"\\r-([A-Za-z0-9._-]+)$", value)
print(match.group(1) if match else "")
PY
)
    printf -v "SESSION_${label^^}_ID" '%s' "$session_id"
}

publish_once one
session_one=${SESSION_ONE_ID:-}
[[ -n $session_one ]] || { printf 'primeira sessão sem id\n' >&2; exit 1; }

manifest_ps=$(python3 - "$manifest" <<'PY'
import json
from pathlib import Path
import sys
items = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line.strip():
        digest, path = line.split(None, 1)
        items.append({"hash": digest.lower(), "path": path.replace("/", "\\")})
print(json.dumps(items, separators=(",", ":")))
PY
)
unc_b64=$(printf '%s' "$SESSION_ONE_UNC" | base64 -w0)
password_b64=$(printf '%s' "$SESSION_ONE_PASSWORD" | base64 -w0)
# O Windows recusa (erro 1219) duas credenciais no mesmo servidor: conexões de
# uma execução anterior ao gateway são removidas antes e o share sai no fim.
hash_script=$(printf '%s\n' "[Console]::OutputEncoding=[Text.Encoding]::UTF8; \$ProgressPreference='SilentlyContinue'; \$unc=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$unc_b64')); \$server=(\$unc -split '\\\\')[2]; Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { \$_.RemotePath -like ('\\\\' + \$server + '\\*') } | Remove-SmbMapping -Force -ErrorAction SilentlyContinue; cmd.exe /c ('net use \\\\' + \$server + '\\IPC\$ /delete /y') 2>&1 | Out-Null; \$pw=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$password_b64')); \$sec=ConvertTo-SecureString \$pw -AsPlainText -Force; \$cred=[PSCredential]::new('$SESSION_ONE_USER',\$sec); New-PSDrive -Name R -PSProvider FileSystem -Root \$unc -Credential \$cred -ErrorAction Stop | Out-Null; \$items=@'")
hash_script+=$'\n'"$manifest_ps"$'\n'
hash_script+=$(printf '%s\n' "'@ | ConvertFrom-Json; \$out=@(); foreach (\$item in \$items) { \$file=Join-Path 'R:\\' \$item.path; \$hash=(Get-FileHash -Algorithm SHA256 -LiteralPath \$file -ErrorAction Stop).Hash.ToLower(); \$out += [PSCustomObject]@{path=\$item.path; hash=\$hash} }; Remove-PSDrive R -ErrorAction SilentlyContinue; cmd.exe /c ('net use ' + \$unc + ' /delete /y') 2>&1 | Out-Null; \$out | ConvertTo-Json -Compress")
qga_output=$(qga_exec "$pve_node" "$winlab" powershell.exe -NoProfile -NonInteractive -EncodedCommand "$(ps_encoded "$hash_script")")
python3 - "$manifest" "$qga_output" <<'PY'
import json
from pathlib import Path
import sys
expected = {}
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line.strip():
        digest, path = line.split(None, 1)
        expected[path.replace("/", "\\")] = digest.lower()
actual = json.loads(sys.argv[2])
if isinstance(actual, dict):
    actual = [actual]
got = {item.get("path"): item.get("hash") for item in actual}
problems = []
for path in sorted(set(expected) | set(got)):
    if expected.get(path) != got.get(path):
        problems.append("%r: esperado %s, obtido %s" % (path, expected.get(path), got.get(path)))
if problems:
    print("hashes divergentes (%d de %d):" % (len(problems), len(expected)), file=sys.stderr)
    for line in problems[:20]:
        print("  " + line, file=sys.stderr)
    raise SystemExit("hashes do restore não conferem com o manifest")
print(f"Get-FileHash: {len(actual)} arquivos conferidos")
PY

publish_once two
session_two=${SESSION_TWO_ID:-}
[[ -n $session_two && $session_two != "$session_one" ]] || {
    printf 'segunda publicação não gerou sessão distinta\n' >&2
    exit 1
}
revoke_session "$session_two"
session_two=''
revoke_session "$session_one"
session_one=''

api_request GET "/api2/json/nodes/${pve_node}/mm-tools/restore/sessions" "$tmp/sessions" "$tmp/sessions.code"
expect_code "$tmp/sessions" 200
python3 - "$tmp/sessions" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text()).get("data", [])
if data:
    raise SystemExit("sessões de restore ainda ativas")
print("API sessions: 0 após revoke")
PY

gateway_list=$(qga_exec "$gateway_node" "$gateway_vmid" gw-restore list --json)
python3 - "$gateway_list" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
if data.get("sessions"):
    raise SystemExit("gateway ainda tem sessões")
print("gateway sessions: 0")
PY
qga_exec "$gateway_node" "$gateway_vmid" bash -lc "set -e; nft list table inet gw_restore; test -z \"\$(ip -d link show type vlan | grep -E '(^|@)${vlan}([ :@]|$)' || true)\""
win_ip_remove
qm set "$winlab" --delete "$nic_key" >/dev/null
nic_added=0
config=$(qm config "$winlab")
[[ $config != *"${nic_mac}"* ]] || { printf 'NIC marcada não foi removida\n' >&2; exit 1; }
printf 'e2e-restore: PASS (%s arquivos; duas sessões; revoke e limpeza OK)\n' "$(wc -l < "$manifest")"
REMOTE
cat "$output"
(( rc == 0 )) || lab_fail "e2e-restore falhou (consulte $output)"
lab_pass 'restore end-to-end concluído; cleanup executado'
