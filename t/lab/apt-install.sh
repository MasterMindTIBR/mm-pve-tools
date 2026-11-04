#!/usr/bin/env bash
# Prova pós-pre-release dos pacotes vindos do APT MasterMind assinado.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_NODE1 LAB_NODE2 LAB_NODE3 LAB_GATEWAY_NODE LAB_GATEWAY_VMID \
    LAB_EVIDENCE_DIR LAB_APT_SHA256_FILE LAB_APT_ORIGIN_PATTERN
lab_init_evidence
[[ -r $LAB_APT_SHA256_FILE ]] || lab_fail 'SHA256SUMS da release não é legível'
expected_pve=$(awk '$2 ~ /mm-pve-tools_[^ ]+\.deb$/ {print $1; exit}' "$LAB_APT_SHA256_FILE")
expected_gw=$(awk '$2 ~ /mm-gw-restore_[^ ]+\.deb$/ {print $1; exit}' "$LAB_APT_SHA256_FILE")
[[ $expected_pve =~ ^[0-9a-fA-F]{64}$ && $expected_gw =~ ^[0-9a-fA-F]{64}$ ]] || \
    lab_fail 'SHA256SUMS não contém os dois assets Debian esperados'

install_node() {
    local node=$1 package=$2 expected=$3
    local log="${LAB_EVIDENCE_RUN_DIR}/apt-${node}-${package}.log" rc=0
    lab_ssh "$node" bash -s -- "$package" "$expected" "$LAB_APT_ORIGIN_PATTERN" >"$log" 2>&1 <<'REMOTE' || rc=$?
set -euo pipefail
package=$1
expected=$2
origin=$3
apt-get purge -y "$package" || true
apt-get update -qq
apt-get --download-only install -y "$package"
cached=$(find /var/cache/apt/archives -maxdepth 1 -type f -name "${package}_*.deb" -print -quit)
test -n "$cached"
actual=$(sha256sum "$cached" | awk '{print $1}')
[[ $actual == "$expected" ]]
policy=$(apt-cache policy "$package")
grep -F "$origin" <<<"$policy"
apt-get install -y "$package"
installed=$(dpkg-query -W -f='${Version}' "$package")
candidate=$(awk '/Candidate:/ {print $2; exit}' <<<"$policy")
[[ -n $installed && $installed == "$candidate" ]]
printf '%s %s sha256=%s origin=%s\n' "$package" "$installed" "$actual" "$origin"
REMOTE
    cat "$log"
    (( rc == 0 )) || lab_fail "APT de $package falhou em $node"
}

for node in "$LAB_NODE1" "$LAB_NODE2" "$LAB_NODE3"; do
    lab_step "APT: mm-pve-tools em ${node}"
    install_node "$node" mm-pve-tools "$expected_pve"
done

lab_step 'APT: mm-gw-restore no gateway via QEMU guest agent'
gateway_log="${LAB_EVIDENCE_RUN_DIR}/apt-gateway.log"
rc=0
lab_ssh "$LAB_GATEWAY_NODE" bash -s -- "$LAB_GATEWAY_NODE" "$LAB_GATEWAY_VMID" "$expected_gw" \
    "$LAB_APT_ORIGIN_PATTERN" >"$gateway_log" 2>&1 <<'REMOTE' || rc=$?
set -euo pipefail
node=$1
vmid=$2
expected=$3
origin=$4
guest_exec() {
    local script=$1 out pid state rc=0
    out=$(pvesh create "/nodes/$node/qemu/$vmid/agent/exec" --output-format json \
        --command bash --command -lc --command "$script") || return $?
    pid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])' <<<"$out")
    while :; do
        state=$(pvesh get "/nodes/$node/qemu/$vmid/agent/exec-status" --pid "$pid" --output-format json)
        if [[ $(python3 -c 'import json,sys; print(int(json.load(sys.stdin).get("exited",0)))' <<<"$state") == 1 ]]; then
            rc=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("exitcode",0))' <<<"$state")
            python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data", ""), end="")' <<<"$state"
            return "$rc"
        fi
        sleep 2
    done
}
guest_exec "set -e; apt-get purge -y mm-gw-restore || true; apt-get update -qq; apt-get --download-only install -y mm-gw-restore; cached=\$(find /var/cache/apt/archives -maxdepth 1 -type f -name 'mm-gw-restore_*.deb' -print -quit); test -n \"\$cached\"; actual=\$(sha256sum \"\$cached\" | awk '{print \$1}'); test \"\$actual\" = \"$expected\"; policy=\$(apt-cache policy mm-gw-restore); grep -F \"$origin\" <<<\"\$policy\"; apt-get install -y mm-gw-restore; installed=\$(dpkg-query -W -f='\${Version}' mm-gw-restore); candidate=\$(awk '/Candidate:/ {print \$2; exit}' <<<\"\$policy\"); test \"\$installed\" = \"\$candidate\"; printf 'mm-gw-restore %s sha256=%s origin=%s\\n' \"\$installed\" \"\$actual\" \"$origin\""
guest_exec 'set -e; gw-restore selfcheck; nft list table inet gw_restore; test -z "$(find /srv/gw-restore/sessions /srv/gw-restore/mounts /etc/samba/gw-restore.d -mindepth 1 -maxdepth 1 -print -quit)"'
REMOTE
cat "$gateway_log"
(( rc == 0 )) || lab_fail 'APT de mm-gw-restore/selfcheck falhou no gateway'

lab_step 'APT: repetir smoke API e restore'
api_log="${LAB_EVIDENCE_RUN_DIR}/apt-api-smoke.log"
rc=0
bash "${script_dir}/api-smoke.sh" >"$api_log" 2>&1 || rc=$?
cat "$api_log"
(( rc == 0 )) || lab_fail 'api-smoke pós-APT falhou'
restore_log="${LAB_EVIDENCE_RUN_DIR}/apt-restore.log"
rc=0
bash "${script_dir}/e2e-restore.sh" >"$restore_log" 2>&1 || rc=$?
cat "$restore_log"
(( rc == 0 )) || lab_fail 'e2e-restore pós-APT falhou'
lab_pass 'APT testing, hashes dos assets, smoke API, selfcheck e restore comprovados'
