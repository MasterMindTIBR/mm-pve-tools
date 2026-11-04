#!/usr/bin/env bash
# Smoke test da API instalada no cluster de laboratório, executado no workstation.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_NODE1 LAB_API_CA_FILE LAB_ALLOWED_TOKEN_ID \
    LAB_ALLOWED_TOKEN_SECRET_FILE LAB_FORBIDDEN_TOKEN_ID LAB_FORBIDDEN_TOKEN_SECRET_FILE \
    LAB_API_SCHEME LAB_API_PORT LAB_EVIDENCE_DIR
lab_init_evidence

lab_step 'API: permissões e CAS concorrente'
output="${LAB_EVIDENCE_RUN_DIR}/api-smoke.log"
rc=0
lab_ssh "$LAB_NODE1" bash -s -- "$LAB_NODE1" "$(lab_node_url "$LAB_NODE1")" \
    "$LAB_API_CA_FILE" "$LAB_ALLOWED_TOKEN_ID" "$LAB_ALLOWED_TOKEN_SECRET_FILE" \
    "$LAB_FORBIDDEN_TOKEN_ID" "$LAB_FORBIDDEN_TOKEN_SECRET_FILE" >"$output" 2>&1 <<'REMOTE'
set -euo pipefail
node=$1
api_base=$2
ca_file=$3
allowed_id=$4
allowed_file=$5
forbidden_id=$6
forbidden_file=$7
test -r "$ca_file"
test -r "$allowed_file"
test -r "$forbidden_file"
allowed_secret=$(tr -d '\r\n' < "$allowed_file")
forbidden_secret=$(tr -d '\r\n' < "$forbidden_file")
tmp=$(mktemp -d /run/mm-pve-api-smoke.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
base="${api_base}/api2/json/nodes/${node}/mm-tools"

request() {
    local id=$1 secret=$2 method=$3 path=$4 body=$5 code=$6
    shift 6
    local rc=0
    curl --silent --show-error --cacert "$ca_file" \
        -H "Authorization: PVEAPIToken=${id}=${secret}" \
        -X "$method" -o "$body" -w '%{http_code}' "$@" "${base}${path}" >"$code" || rc=$?
    (( rc == 0 )) || return "$rc"
}

assert_code() {
    local expected=$1 file=$2 label=$3 actual
    actual=$(<"$file")
    [[ $actual == "$expected" ]] || {
        printf '%s: HTTP %s (esperado %s)\n' "$label" "$actual" "$expected" >&2
        return 1
    }
    printf '%s: HTTP %s\n' "$label" "$actual"
}

request "$allowed_id" "$allowed_secret" GET '' "$tmp/index" "$tmp/index.code"
assert_code 200 "$tmp/index.code" 'GET permitido'
request "$forbidden_id" "$forbidden_secret" GET '' "$tmp/forbidden" "$tmp/forbidden.code"
assert_code 403 "$tmp/forbidden.code" 'GET sem permissão'
request "$allowed_id" "$allowed_secret" GET /config "$tmp/config" "$tmp/config.code"
assert_code 200 "$tmp/config.code" 'GET config permitido'

python3 - "$tmp/config" "$tmp/original" "$tmp/digest" <<'PY'
import json
from pathlib import Path
import sys
payload = json.loads(Path(sys.argv[1]).read_text())
data = payload.get("data", payload)
branding = data.get("config", {}).get("branding")
digest = data.get("digest", "")
if not isinstance(branding, dict):
    raise SystemExit("GET config não trouxe config.branding")
Path(sys.argv[2]).write_text(json.dumps(branding, separators=(",", ":")))
Path(sys.argv[3]).write_text(digest)
PY

if [[ -z $(<"$tmp/digest") ]]; then
    request "$allowed_id" "$allowed_secret" PUT /config/branding "$tmp/first-write" \
        "$tmp/first-write.code" --data-urlencode value@"$tmp/original"
    assert_code 200 "$tmp/first-write.code" 'primeira gravação sem digest'
    request "$allowed_id" "$allowed_secret" GET /config "$tmp/config-after-first" \
        "$tmp/config-after-first.code"
    assert_code 200 "$tmp/config-after-first.code" 'GET config após primeira gravação'
    python3 - "$tmp/config-after-first" "$tmp/digest" <<'PY'
import json
from pathlib import Path
import sys
data = json.loads(Path(sys.argv[1]).read_text()).get("data", {})
digest = data.get("digest", "")
if not digest.startswith("sha256:"):
    raise SystemExit("primeira gravação não produziu digest sha256")
Path(sys.argv[2]).write_text(digest)
PY
fi
[[ $(<"$tmp/digest") == sha256:* ]] || { printf 'GET config não trouxe digest sha256\n' >&2; exit 1; }

python3 - "$tmp/original" "$tmp/value-a" "$tmp/value-b" <<'PY'
import json
from pathlib import Path
import sys
branding = json.loads(Path(sys.argv[1]).read_text())
for path, value in zip(sys.argv[2:], ("api-smoke-a", "api-smoke-b")):
    copy = dict(branding)
    copy["header_text"] = value
    Path(path).write_text(json.dumps(copy, separators=(",", ":")))
PY
digest=$(<"$tmp/digest")
rc_a=0
rc_b=0
curl --silent --show-error --cacert "$ca_file" \
    -H "Authorization: PVEAPIToken=${allowed_id}=${allowed_secret}" \
    -X PUT --data-urlencode "digest=$digest" --data-urlencode value@"$tmp/value-a" \
    -o "$tmp/write-a" -w '%{http_code}' "${base}/config/branding" >"$tmp/write-a.code" 2>"$tmp/write-a.err" &
pid_a=$!
curl --silent --show-error --cacert "$ca_file" \
    -H "Authorization: PVEAPIToken=${allowed_id}=${allowed_secret}" \
    -X PUT --data-urlencode "digest=$digest" --data-urlencode value@"$tmp/value-b" \
    -o "$tmp/write-b" -w '%{http_code}' "${base}/config/branding" >"$tmp/write-b.code" 2>"$tmp/write-b.err" &
pid_b=$!
wait "$pid_a" || rc_a=$?
wait "$pid_b" || rc_b=$?
(( rc_a == 0 && rc_b == 0 )) || { printf 'falha de transporte no CAS\n' >&2; exit 1; }

python3 - "$tmp/write-a.code" "$tmp/write-b.code" "$tmp/write-a" "$tmp/write-b" <<'PY'
from pathlib import Path
import sys
codes = [Path(sys.argv[1]).read_text(), Path(sys.argv[2]).read_text()]
if codes.count("200") != 1:
    raise SystemExit(f"CAS concorrente inesperado: {codes}")
loser = Path(sys.argv[4] if codes[0] == "200" else sys.argv[3]).read_text()
if "DIGEST_MISMATCH" not in loser:
    raise SystemExit("o escritor perdedor não recebeu DIGEST_MISMATCH")
print("CAS concorrente: um HTTP 200 e um DIGEST_MISMATCH")
PY

request "$allowed_id" "$allowed_secret" GET /config "$tmp/after" "$tmp/after.code"
assert_code 200 "$tmp/after.code" 'GET config após CAS'
after_digest=$(python3 - "$tmp/after" <<'PY'
import json
from pathlib import Path
import sys
print(json.loads(Path(sys.argv[1]).read_text()).get("data", {}).get("digest", ""))
PY
)
original=$(<"$tmp/original")
request "$allowed_id" "$allowed_secret" PUT /config/branding "$tmp/restore" "$tmp/restore.code" \
    --data-urlencode "digest=$after_digest" --data-urlencode "value=$original"
assert_code 200 "$tmp/restore.code" 'restauração da seção branding'
printf 'api-smoke: OK\n'
REMOTE
rc=$?
cat "$output"
(( rc == 0 )) || lab_fail "api-smoke falhou (consulte $output)"
lab_pass 'api-smoke concluído'
