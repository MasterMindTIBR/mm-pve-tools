#!/bin/bash
# Smoke test da API instalada no cluster de laboratório.
# Uso: exporte as variáveis abaixo; os segredos devem ser arquivos 0600.
set -euo pipefail

: "${PVE_API_URL:?PVE_API_URL é a URL base HTTPS do pveproxy}"
: "${PVE_NODE:?PVE_NODE é o node usado no endpoint}"
: "${PVE_API_CA_FILE:?PVE_API_CA_FILE é o CA do cluster}"
: "${PVE_ALLOWED_TOKEN_ID:?PVE_ALLOWED_TOKEN_ID é o token limitado permitido}"
: "${PVE_ALLOWED_TOKEN_SECRET_FILE:?PVE_ALLOWED_TOKEN_SECRET_FILE é o arquivo do segredo permitido}"
: "${PVE_FORBIDDEN_TOKEN_ID:?PVE_FORBIDDEN_TOKEN_ID é o token sem permissão}"
: "${PVE_FORBIDDEN_TOKEN_SECRET_FILE:?PVE_FORBIDDEN_TOKEN_SECRET_FILE é o arquivo do segredo sem permissão}"

for secret_file in "$PVE_ALLOWED_TOKEN_SECRET_FILE" "$PVE_FORBIDDEN_TOKEN_SECRET_FILE"; do
    test -r "$secret_file" || { echo "segredo não legível: arquivo fora do repositório" >&2; exit 1; }
done
test -r "$PVE_API_CA_FILE" || { echo 'CA do pveproxy não é legível' >&2; exit 1; }

allowed_secret=$(tr -d '\r\n' < "$PVE_ALLOWED_TOKEN_SECRET_FILE")
forbidden_secret=$(tr -d '\r\n' < "$PVE_FORBIDDEN_TOKEN_SECRET_FILE")
api_base="${PVE_API_URL%/}/api2/json/nodes/${PVE_NODE}/mm-tools"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

request() {
    local token_id=$1
    local secret=$2
    local method=$3
    local path=$4
    local body=$5
    local code=$6
    shift 6
    local -a form_args=()
    for field in "$@"; do
        form_args+=(--data-urlencode "$field")
    done
    if ! curl --silent --show-error --cacert "$PVE_API_CA_FILE" \
        -H "Authorization: PVEAPIToken=${token_id}=${secret}" \
        -X "$method" -o "$body" -w '%{http_code}' \
        "${form_args[@]}" \
        "${api_base}${path}" > "$code"; then
        echo "falha de transporte em $method $path" >&2
        return 1
    fi
}

assert_code() {
    local expected=$1
    local code_file=$2
    local label=$3
    local actual
    actual=$(<"$code_file")
    if [[ $actual != "$expected" ]]; then
        echo "$label: HTTP $actual (esperado $expected)" >&2
        return 1
    fi
    echo "$label: HTTP $actual"
}

request "$PVE_ALLOWED_TOKEN_ID" "$allowed_secret" GET '' \
    "$tmp_dir/index.json" "$tmp_dir/index.code"
assert_code 200 "$tmp_dir/index.code" 'GET permitido'

request "$PVE_FORBIDDEN_TOKEN_ID" "$forbidden_secret" GET '' \
    "$tmp_dir/forbidden.json" "$tmp_dir/forbidden.code"
assert_code 403 "$tmp_dir/forbidden.code" 'GET sem permissão'

request "$PVE_ALLOWED_TOKEN_ID" "$allowed_secret" GET /config \
    "$tmp_dir/config.json" "$tmp_dir/config.code"
assert_code 200 "$tmp_dir/config.code" 'GET config permitido'

python3 - "$tmp_dir/config.json" "$tmp_dir/original-branding.json" "$tmp_dir/digest" <<'PY'
import json
import pathlib
import sys

response, branding_path, digest_path = map(pathlib.Path, sys.argv[1:])
payload = json.loads(response.read_text())
data = payload.get("data", payload)
digest = data.get("digest", "")
branding = data.get("config", {}).get("branding")
if not digest.startswith("sha256:") or not isinstance(branding, dict):
    raise SystemExit("GET config não trouxe digest/config.branding")
branding_path.write_text(json.dumps(branding, separators=(",", ":")))
digest_path.write_text(digest)
PY

digest=$(<"$tmp_dir/digest")
value_a=$(python3 - "$tmp_dir/original-branding.json" <<'PY'
import json
import pathlib
import sys

branding = json.loads(pathlib.Path(sys.argv[1]).read_text())
branding["header_text"] = "api-smoke-a"
print(json.dumps(branding, separators=(",", ":")))
PY
)
value_b=$(python3 - "$tmp_dir/original-branding.json" <<'PY'
import json
import pathlib
import sys

branding = json.loads(pathlib.Path(sys.argv[1]).read_text())
branding["header_text"] = "api-smoke-b"
print(json.dumps(branding, separators=(",", ":")))
PY
)

curl --silent --show-error --cacert "$PVE_API_CA_FILE" \
    -H "Authorization: PVEAPIToken=${PVE_ALLOWED_TOKEN_ID}=${allowed_secret}" \
    -X PUT --data-urlencode "digest=$digest" --data-urlencode "value=$value_a" \
    -o "$tmp_dir/write-a.json" -w '%{http_code}' \
    "${api_base}/config/branding" > "$tmp_dir/write-a.code" 2> "$tmp_dir/write-a.err" &
pid_a=$!
curl --silent --show-error --cacert "$PVE_API_CA_FILE" \
    -H "Authorization: PVEAPIToken=${PVE_ALLOWED_TOKEN_ID}=${allowed_secret}" \
    -X PUT --data-urlencode "digest=$digest" --data-urlencode "value=$value_b" \
    -o "$tmp_dir/write-b.json" -w '%{http_code}' \
    "${api_base}/config/branding" > "$tmp_dir/write-b.code" 2> "$tmp_dir/write-b.err" &
pid_b=$!
rc_a=0
rc_b=0
wait "$pid_a" || rc_a=$?
wait "$pid_b" || rc_b=$?
if [[ $rc_a -ne 0 || $rc_b -ne 0 ]]; then
    echo 'falha de transporte durante os escritores concorrentes' >&2
    exit 1
fi

python3 - "$tmp_dir/write-a.code" "$tmp_dir/write-b.code" \
    "$tmp_dir/write-a.json" "$tmp_dir/write-b.json" <<'PY'
import pathlib
import sys

code_a, code_b, body_a, body_b = map(pathlib.Path, sys.argv[1:])
codes = [code_a.read_text(), code_b.read_text()]
if codes.count("200") != 1:
    raise SystemExit(f"CAS concorrente inesperado: {codes}")
loser = body_b.read_text() if codes[0] == "200" else body_a.read_text()
if "DIGEST_MISMATCH" not in loser:
    raise SystemExit("o escritor perdedor não recebeu DIGEST_MISMATCH")
print(f"CAS concorrente: um HTTP 200, outro {next(code for code in codes if code != '200')}")
PY

request "$PVE_ALLOWED_TOKEN_ID" "$allowed_secret" GET /config \
    "$tmp_dir/config-after.json" "$tmp_dir/config-after.code"
assert_code 200 "$tmp_dir/config-after.code" 'GET config após CAS'
after_digest=$(python3 - "$tmp_dir/config-after.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(payload.get("data", payload).get("digest", ""))
PY
)
original_value=$(<"$tmp_dir/original-branding.json")
request "$PVE_ALLOWED_TOKEN_ID" "$allowed_secret" PUT /config/branding \
    "$tmp_dir/restore.json" "$tmp_dir/restore.code" \
    "digest=$after_digest" "value=$original_value"
assert_code 200 "$tmp_dir/restore.code" 'restauração da seção branding'

echo 'api-smoke: OK'
