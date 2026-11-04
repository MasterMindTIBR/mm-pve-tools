#!/usr/bin/env bash
# Uploada um PNG via API, aplica em todos os nodes e prova clear.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_NODE1 LAB_NODE2 LAB_NODE3 LAB_API_CA_FILE \
    LAB_ALLOWED_TOKEN_ID LAB_ALLOWED_TOKEN_SECRET_FILE LAB_API_SCHEME LAB_API_PORT \
    LAB_EVIDENCE_DIR
lab_init_evidence

png=$(mktemp "${TMPDIR:-/tmp}/mm-branding.XXXXXX.png")
trap 'rm -f -- "$png"' EXIT INT TERM
python3 - "$png" <<'PY'
import struct
import sys
import zlib

path = sys.argv[1]

def chunk(name, data):
    return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data) & 0xffffffff)

raw = b"\x00\x1d\x87\x3f\xff"
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw))
png += chunk(b"IEND", b"")
with open(path, "wb") as handle:
    handle.write(png)
PY

remote_tmp="/tmp/mm-pve-branding-${$}.png"
control_log="${LAB_EVIDENCE_RUN_DIR}/e2e-branding.log"
: >"$control_log"
previous=''
restore_pending=0

# Limpa o branding via API e devolve o módulo ao valor que tinha antes do teste.
restore_branding() {
    lab_ssh "$LAB_NODE1" bash -s -- "$LAB_NODE1" "$(lab_node_url "$LAB_NODE1")" \
        "$LAB_API_CA_FILE" "$LAB_ALLOWED_TOKEN_ID" "$LAB_ALLOWED_TOKEN_SECRET_FILE" "$previous" <<'REMOTE'
set -euo pipefail
node=$1
api_base=$2
ca=$3
token_id=$4
secret_file=$5
previous=$6
secret=$(tr -d '\r\n' < "$secret_file")
auth=(--header "Authorization: PVEAPIToken=${token_id}=${secret}")
base="${api_base}/api2/json/nodes/${node}/mm-tools"
tmp=$(mktemp -d /run/mm-pve-branding-clear.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
curl --silent --show-error --cacert "$ca" "${auth[@]}" -X PUT \
    --data-urlencode clear=1 -o "$tmp/clear" -w '%{http_code}' \
    "${base}/branding/set" >"$tmp/clear.code"
[[ $(<"$tmp/clear.code") == 200 ]] || { printf 'clear: HTTP %s\n' "$(<"$tmp/clear.code")" >&2; exit 1; }
printf 'branding clear: OK\n'
curl --silent --show-error --cacert "$ca" "${auth[@]}" -o "$tmp/config" -w '%{http_code}' \
    "${base}/config" >"$tmp/config.code"
[[ $(<"$tmp/config.code") == 200 ]]
python3 - "$tmp/config" "$tmp/modules" "$tmp/digest" "$previous" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text())["data"]
modules = dict(data["config"].get("modules") or {})
modules["branding"] = int(sys.argv[4])
Path(sys.argv[2]).write_text(json.dumps(modules, separators=(",", ":")))
Path(sys.argv[3]).write_text(data["digest"])
PY
curl --silent --show-error --cacert "$ca" "${auth[@]}" -X PUT \
    --data-urlencode "digest=$(<"$tmp/digest")" --data-urlencode value@"$tmp/modules" \
    -o "$tmp/modules.out" -w '%{http_code}' "${base}/config/modules" >"$tmp/modules.code"
[[ $(<"$tmp/modules.code") == 200 ]] || { printf 'módulo: HTTP %s\n' "$(<"$tmp/modules.code")" >&2; exit 1; }
printf 'módulo branding de volta a %s\n' "$previous"
REMOTE
}

cleanup() {
    local rc=0 node
    if (( restore_pending )); then
        printf 'AVISO: teste interrompido; desfazendo branding no lab\n' >&2
        restore_branding >>"$control_log" 2>&1 || printf 'AVISO: não consegui desfazer o branding\n' >&2
        for node in "$LAB_NODE1" "$LAB_NODE2" "$LAB_NODE3"; do
            lab_ssh "$node" mm-pve apply --no-patches >>"$control_log" 2>&1 \
                || printf 'AVISO: apply de limpeza falhou em %s\n' "$node" >&2
        done
    fi
    lab_ssh "$LAB_NODE1" rm -f -- "$remote_tmp" >>"$control_log" 2>&1 || rc=$?
    if (( rc != 0 )); then
        printf 'AVISO: não removi PNG temporário do node de controle (rc=%s)\n' "$rc" >&2
    fi
}
trap cleanup EXIT INT TERM
scp_rc=0
lab_scp_to "$png" "$LAB_NODE1" "$remote_tmp" >>"$control_log" 2>&1 || scp_rc=$?
(( scp_rc == 0 )) || lab_fail 'não transferi o PNG para o node de controle'

lab_step 'branding: upload via API'
rc=0
lab_ssh "$LAB_NODE1" bash -s -- "$LAB_NODE1" "$(lab_node_url "$LAB_NODE1")" \
    "$LAB_API_CA_FILE" "$LAB_ALLOWED_TOKEN_ID" "$LAB_ALLOWED_TOKEN_SECRET_FILE" \
    "$remote_tmp" >"$control_log" 2>&1 <<'REMOTE' || rc=$?
set -euo pipefail
node=$1
api_base=$2
ca=$3
token_id=$4
secret_file=$5
png=$6
test -r "$ca" -a -r "$secret_file" -a -r "$png"
secret=$(tr -d '\r\n' < "$secret_file")
tmp=$(mktemp -d /run/mm-pve-branding.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
auth=(--header "Authorization: PVEAPIToken=${token_id}=${secret}")
base="${api_base}/api2/json/nodes/${node}/mm-tools"
python3 - "$png" "$tmp/logo.b64" <<'PY'
import base64
from pathlib import Path
import sys
Path(sys.argv[2]).write_text(base64.b64encode(Path(sys.argv[1]).read_bytes()).decode())
PY
curl --silent --show-error --cacert "$ca" "${auth[@]}" -o "$tmp/config" -w '%{http_code}' \
    "${base}/config" >"$tmp/config.code"
[[ $(<"$tmp/config.code") == 200 ]]
python3 - "$tmp/config" "$tmp/digest" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text()).get("data", {})
digest = data.get("digest", "")
if not digest.startswith("sha256:"):
    raise SystemExit("digest de branding ausente")
Path(sys.argv[2]).write_text(digest)
PY
digest=$(<"$tmp/digest")
# O módulo vem desligado por padrão: liga pela API (como a GUI) e informa o
# valor anterior para a restauração no fim.
python3 - "$tmp/config" "$tmp/modules" "$tmp/previous" <<'PY2'
import json
from pathlib import Path
import sys
modules = dict(json.loads(Path(sys.argv[1]).read_text())["data"]["config"].get("modules") or {})
Path(sys.argv[3]).write_text(str(int(bool(modules.get("branding")))))
modules["branding"] = 1
Path(sys.argv[2]).write_text(json.dumps(modules, separators=(",", ":")))
PY2
printf 'branding-anterior=%s\n' "$(<"$tmp/previous")"
curl --silent --show-error --cacert "$ca" "${auth[@]}" -X PUT \
    --data-urlencode "digest=$digest" --data-urlencode value@"$tmp/modules" \
    -o "$tmp/modules.out" -w '%{http_code}' "${base}/config/modules" >"$tmp/modules.code"
[[ $(<"$tmp/modules.code") == 200 ]] || { printf 'ligar módulo: HTTP %s\n' "$(<"$tmp/modules.code")" >&2; exit 1; }
digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["digest"])' "$tmp/modules.out")
curl --silent --show-error --cacert "$ca" "${auth[@]}" -X PUT \
    --data-urlencode "digest=$digest" --data-urlencode logo_b64@"$tmp/logo.b64" \
    --data-urlencode logo_name=lab-branding.png -o "$tmp/upload" -w '%{http_code}' \
    "${base}/branding/upload" >"$tmp/upload.code"
[[ $(<"$tmp/upload.code") == 200 ]]
asset=$(python3 - "$tmp/upload" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text()).get("data", {})
name = data.get("logo", "")
if not name.endswith(".png") or len(name) != 68:
    raise SystemExit("upload não devolveu o asset PNG esperado")
print(name)
PY
)
printf 'branding upload: OK\n'
printf '%s\n' "$asset"
REMOTE
cat "$control_log"
previous=$(sed -n 's/^branding-anterior=\([01]\)$/\1/p' "$control_log")
if [[ -n $previous ]]; then restore_pending=1; fi
(( rc == 0 )) || lab_fail "upload de branding falhou (consulte $control_log)"

asset=$(awk '/^[0-9a-f]{64}\.png$/ { print; exit }' "$control_log")
[[ -n $asset ]] || lab_fail 'não consegui obter o nome content-addressed do PNG'

# O apply recarrega o pveproxy quando o branding muda: é o reload que registra
# a pasta mm-branding no pveproxy, então aqui não se usa --no-reload.
for node in "$LAB_NODE1" "$LAB_NODE2" "$LAB_NODE3"; do
    lab_step "branding: aplicar e consultar asset em ${node}"
    log="${LAB_EVIDENCE_RUN_DIR}/branding-${node}.log"
    rc=0
    lab_ssh "$node" mm-pve apply --no-patches >"$log" 2>&1 || rc=$?
    cat "$log"
    (( rc == 0 )) || lab_fail "apply de branding falhou em $node"
    check_rc=0
    lab_ssh "$node" bash -s -- "$(lab_node_url "$node")" "$LAB_API_CA_FILE" "$asset" \
        >"$log.check" 2>&1 <<'REMOTE' || check_rc=$?
set -euo pipefail
url=$1
ca=$2
asset=$3
body=$(mktemp)
trap 'rm -f -- "$body"' EXIT
code=000
for _ in $(seq 1 10); do
    code=$(curl --silent --cacert "$ca" -o "$body" -w '%{http_code}' "${url}/pve2/images/mm-branding/${asset}" || true)
    [[ $code == 200 ]] && break
    sleep 1
done
[[ $code == 200 ]] || { printf 'asset HTTP %s\n' "$code" >&2; exit 1; }
served=$(sha256sum <"$body" | cut -d' ' -f1)
[[ "${served}.png" == "$asset" ]] || { printf 'asset servido difere do enviado (%s)\n' "$served" >&2; exit 1; }
printf 'asset HTTP %s, conteúdo confere\n' "$code"
REMOTE
    cat "$log.check"
    (( check_rc == 0 )) || lab_fail "node $node não serviu o branding"
done

lab_step 'branding: clear via API e verificar remoção'
rc=0
restore_branding >"$control_log.clear" 2>&1 || rc=$?
cat "$control_log.clear"
(( rc == 0 )) || lab_fail 'clear de branding falhou'
for node in "$LAB_NODE1" "$LAB_NODE2" "$LAB_NODE3"; do
    apply_log="${LAB_EVIDENCE_RUN_DIR}/branding-clear-${node}.log"
    rc=0
    lab_ssh "$node" mm-pve apply --no-patches >"$apply_log" 2>&1 || rc=$?
    cat "$apply_log"
    (( rc == 0 )) || lab_fail "apply de clear falhou em $node"
    check_log="${LAB_EVIDENCE_RUN_DIR}/branding-clear-${node}.check.log"
    rc=0
    lab_ssh "$node" bash -s -- "$(lab_node_url "$node")" "$LAB_API_CA_FILE" "$asset" \
        >"$check_log" 2>&1 <<'REMOTE' || rc=$?
set -euo pipefail
url=$1
ca=$2
asset=$3
[[ ! -e /usr/share/pve-manager/images/mm-branding/$asset ]] || { printf 'asset ainda existe em disco\n' >&2; exit 1; }
# o pveproxy responde 500 (não 404) para arquivo estático ausente
code=$(curl --silent --cacert "$ca" -o /dev/null -w '%{http_code}' "${url}/pve2/images/mm-branding/${asset}" || true)
[[ $code != 200 ]] || { printf 'asset pós-clear ainda servido (HTTP 200)\n' >&2; exit 1; }
printf 'asset pós-clear: fora do disco, HTTP %s\n' "$code"
REMOTE
    cat "$check_log"
    (( rc == 0 )) || lab_fail "node $node ainda serve o branding após clear"
done
restore_pending=0
lab_pass 'branding upload, aplicação em três nodes e clear comprovados'
