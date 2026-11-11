#!/usr/bin/env bash
# Prova de laboratório do Rock 5, disparada no workstation e executada no node.
# Uso: e2e-renumber.sh NODE STORAGE[,STORAGE...] OLD_VMID NEW_VMID
#
# O script só destrói VMs que criou nesta execução e cuja descrição ainda
# contém o marcador deste teste.

set -euo pipefail

if [[ ${MM_LAB_REMOTE:-0} != 1 ]]; then
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    # shellcheck disable=SC1091
    source "${script_dir}/lab-common.sh"
    lab_load_env
    lab_require LAB_SSH_CONFIG LAB_EVIDENCE_DIR
    lab_init_evidence
    if [[ $# -ne 4 ]]; then
        printf 'uso: %s NODE STORAGE[,STORAGE...] OLD_VMID NEW_VMID\n' "$0" >&2
        exit 2
    fi
    node=$1
    remote_script=/tmp/mm-pve-tools-e2e-renumber.sh
    remote_log_dir="/tmp/mm-pve-tools-e2e-renumber-${$}"
    local_log_dir="${LAB_EVIDENCE_RUN_DIR}/renumber-${node}"
    output="${LAB_EVIDENCE_RUN_DIR}/e2e-renumber-${node}.log"
    mkdir -p -- "$local_log_dir"
    chmod 0700 -- "$local_log_dir"
    lab_ssh "$node" rm -rf -- "$remote_script" "$remote_log_dir" >/dev/null 2>&1 || true
    scp_rc=0
    lab_scp_to "$0" "$node" "$remote_script" >"$output" 2>&1 || scp_rc=$?
    (( scp_rc == 0 )) || lab_fail "não copiei e2e-renumber para $node"
    rc=0
    lab_ssh "$node" env MM_LAB_REMOTE=1 bash "$remote_script" "$@" "$remote_log_dir" \
        >>"$output" 2>&1 || rc=$?
    copy_rc=0
    lab_scp_from "$node" "$remote_log_dir/." "$local_log_dir" >>"$output" 2>&1 || copy_rc=$?
    cleanup_rc=0
    lab_ssh "$node" rm -rf -- "$remote_script" "$remote_log_dir" >>"$output" 2>&1 || cleanup_rc=$?
    cat "$output"
    (( cleanup_rc == 0 )) || lab_fail "não removi o script temporário no node $node"
    (( copy_rc == 0 )) || lab_fail "não copiei os logs do renumber para $local_log_dir"
    printf 'Evidência renumber: %s\n' "$local_log_dir"
    (( rc == 0 )) || lab_fail "e2e-renumber falhou em $node (evidência: $local_log_dir)"
    lab_pass "e2e-renumber concluído em $node"
    exit 0
fi

if [[ $# -ne 5 ]]; then
    printf 'uso: %s NODE STORAGE[,STORAGE...] OLD_VMID NEW_VMID LOG_DIR\n' "$0" >&2
    exit 2
fi

node=$1
storage_csv=$2
base_old=$3
base_new=$4
tmp_dir=$5
marker="mm-pve-tools e2e-renumber $$"
mkdir -p -- "$tmp_dir"
chmod 0700 -- "$tmp_dir"
created_file="$tmp_dir/created"
: > "$created_file"

die() {
    printf 'FALHA: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local old new conf
    while IFS=' ' read -r old new; do
        [[ -n ${old:-} && -n ${new:-} ]] || continue
        for vmid in "$old" "$new"; do
            conf=$(qm config "$vmid" 2>/dev/null || true)
            if [[ $conf == *"description: $marker"* ]]; then
                qm destroy "$vmid" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 || true
            fi
        done
    done < "$created_file"
    while IFS=' ' read -r old new; do
        [[ -n ${old:-} && -n ${new:-} ]] || continue
        rm -f -- "/etc/pve/mm-tools/journal/renumber-${old}-${new}.json" \
            "/etc/pve/firewall/${old}.fw" "/etc/pve/firewall/${new}.fw"
    done < "$created_file"
    if [[ -n ${api_token:-} ]]; then
        pveum user token remove root@pam "$api_token" >/dev/null 2>&1 || true
    fi
    rm -f -- "${api_header:-}"
}
api_token=''
api_header=''
trap cleanup EXIT INT TERM

[[ $base_old =~ ^[0-9]+$ && $base_new =~ ^[0-9]+$ ]] || die 'VMIDs precisam ser numéricos'
(( base_old >= 100 && base_new >= 100 )) || die 'VMIDs precisam ser >= 100'

if ! pvesh get "/nodes/$node/status" --output-format json >/dev/null 2>&1; then
    die "node '$node' não está acessível neste ambiente"
fi

IFS=',' read -r -a storages <<< "$storage_csv"
(( ${#storages[@]} > 0 )) || die 'passe pelo menos um storage'
for storage in "${storages[@]}"; do
    [[ -n $storage ]] || die 'storage vazio na lista'
    if ! pvesm status --storage "$storage" >/dev/null 2>&1; then
        die "storage '$storage' não existe/está indisponível neste node"
    fi
done

steps=(reserve move_disks config firewall refs verify destroy)

vm_exists() {
    qm status "$1" >/dev/null 2>&1
}

assert_marker() {
    local conf
    conf=$(qm config "$1" 2>/dev/null) || die "VM $1 não existe"
    [[ $conf == *"description: $marker"* ]] || die "VM $1 não tem o marcador deste teste"
}

create_fixture() {
    local old=$1
    local idx=0
    vm_exists "$old" && die "VM $old já existe; não vou tocá-la"
    vm_exists "$2" && die "VM $2 já existe; não vou tocá-la"
    [[ ! -e /etc/pve/mm-tools/journal/renumber-$old-$2.json ]] \
        || die "journal renumber-$old-$2 já existe; não vou tocá-lo"
    qm create "$old" --name "mm-r5-$old" --memory 128 --cores 1 \
        --ostype l26 --scsihw virtio-scsi-single --description "$marker" \
        >/dev/null || die "não consegui criar VM $old"
    printf '%s %s\n' "$old" "$2" >> "$created_file"
    for storage in "${storages[@]}"; do
        qm set "$old" "--scsi${idx}" "$storage:1,format=raw" >/dev/null \
            || die "não consegui criar disco em $storage para VM $old"
        idx=$((idx + 1))
    done
    assert_marker "$old"
}

run_injected() {
    local step=$1 old=$2 new=$3 log=$4
    if MM_RENUMBER_FAIL_AFTER="$step" mm-pve renumber --from "$old" --to "$new" \
        --node "$node" >"$log" 2>&1; then
        die "fault injection '$step' terminou sem falhar"
    fi
}

assert_finished() {
    local old=$1 new=$2 journal="/etc/pve/mm-tools/journal/renumber-$1-$2.json"
    local state
    state=$(perl -MJSON::PP -0777 -ne 'print decode_json($_)->{state} // ""' "$journal") \
        || die "journal $journal ilegível"
    [[ $state == finished ]] || die "journal $journal não terminou (estado: ${state:-vazio})"
}

run_resume_case() {
    local old=$1 new=$2 step=$3
    local inject_log="$tmp_dir/inject-$old.log"
    local resume_log="$tmp_dir/resume-$old.log"
    create_fixture "$old" "$new"
    run_injected "$step" "$old" "$new" "$inject_log"
    if [[ $step == destroy ]]; then
        ! vm_exists "$old" || die "VM antiga ainda existe após destroy"
    else
        vm_exists "$old" || die "VM antiga sumiu antes do destroy"
    fi
    mm-pve renumber --resume --from "$old" --to "$new" --node "$node" \
        >"$resume_log" 2>&1 || die "resume falhou no passo $step (ver $resume_log)"
    vm_exists "$new" || die "VM nova não existe após resume de $step"
    if [[ $step != destroy ]]; then
        ! vm_exists "$old" || die "VM antiga ainda existe após resume de $step"
    fi
    assert_finished "$old" "$new"
}

run_rollback_case() {
    local old=$1 new=$2 step=$3
    local inject_log="$tmp_dir/inject-$old.log"
    local rollback_log="$tmp_dir/rollback-$old.log"
    create_fixture "$old" "$new"
    run_injected "$step" "$old" "$new" "$inject_log"
    if [[ $step == destroy ]]; then
        if mm-pve renumber --rollback --from "$old" --to "$new" --node "$node" \
            >"$rollback_log" 2>&1; then
            die 'rollback após destroy foi aceito'
        fi
        grep -qi 'rollback refused' "$rollback_log" || die 'rollback não explicou a recusa pós-destroy'
        return
    fi
    mm-pve renumber --rollback --from "$old" --to "$new" --node "$node" \
        >"$rollback_log" 2>&1 || die "rollback falhou no passo $step (ver $rollback_log)"
    vm_exists "$old" || die "VM antiga não voltou após rollback de $step"
    ! vm_exists "$new" || die "VM nova ainda existe após rollback de $step"
    assert_finished "$old" "$new"
}

offset=0
for step in "${steps[@]}"; do
    old=$((base_old + offset))
    new=$((base_new + offset))
    run_resume_case "$old" "$new" "$step"
    offset=$((offset + 2))
    old=$((base_old + offset))
    new=$((base_new + offset))
    run_rollback_case "$old" "$new" "$step"
    offset=$((offset + 2))
    printf 'OK: %s — resume e rollback\n' "$step"
done

# O botão da GUI chama a API, que roda dentro do pvedaemon com perl -T: uma
# troca completa por ela, com arquivo de firewall, prova o caminho real.
run_api_case() {
    local old=$1 new=$2 log="$tmp_dir/api-run.log" upid state exit_status
    create_fixture "$old" "$new"
    printf '[OPTIONS]\nenable: 0\n' >"/etc/pve/firewall/${old}.fw"
    api_token="mm-e2e-renumber-${$}"
    # o cabeçalho com o segredo fica fora de $tmp_dir, que vira evidência
    api_header=$(mktemp /run/mm-e2e-renumber.XXXXXX)
    pveum user token add root@pam "$api_token" --privsep 0 --output-format json \
        | perl -MJSON::PP -0777 -ne 'my $d = decode_json($_); printf "Authorization: PVEAPIToken=%s=%s\n", $d->{"full-tokenid"}, $d->{value}' \
        >"$api_header" || die 'não criei o token temporário da API'
    local code
    code=$(curl --silent --show-error --cacert /etc/pve/pve-root-ca.pem -H @"$api_header" \
        -X POST --data-urlencode "from=$old" --data-urlencode "to=$new" \
        -o "$tmp_dir/api-run.json" -w '%{http_code}' \
        "https://${node}:8006/api2/json/nodes/${node}/mm-tools/renumber/run") || die 'curl da API falhou'
    [[ $code == 200 ]] || die "API renumber/run: HTTP $code: $(head -c 400 "$tmp_dir/api-run.json")"
    upid=$(perl -MJSON::PP -0777 -ne 'print decode_json($_)->{data} // ""' "$tmp_dir/api-run.json")
    [[ $upid == UPID:* ]] || die 'API renumber/run não devolveu UPID'
    for _ in $(seq 1 300); do
        state=$(pvesh get "/nodes/${node}/tasks/${upid}/status" --output-format json \
            | perl -MJSON::PP -0777 -ne 'my $d = decode_json($_); print "$d->{status} ", $d->{exitstatus} // ""')
        [[ ${state%% *} == stopped ]] && break
        sleep 2
    done
    pvesh get "/nodes/${node}/tasks/${upid}/log" --limit 200 --output-format json \
        | perl -MJSON::PP -0777 -ne 'print "$_->{t}\n" for @{decode_json($_)}' >"$log" || true
    [[ ${state%% *} == stopped ]] || die "tarefa da API não terminou (ver $log)"
    exit_status=${state#* }
    [[ $exit_status == OK ]] || die "tarefa da API terminou com '$exit_status': $(tail -n 5 "$log" | tr '\n' ' ')"
    vm_exists "$new" || die 'VM nova não existe após renumber pela API'
    ! vm_exists "$old" || die 'VM antiga ainda existe após renumber pela API'
    grep -q '^enable: 0$' "/etc/pve/firewall/${new}.fw" 2>/dev/null \
        || die 'firewall não foi copiado para a VM nova pela API'
    assert_finished "$old" "$new"
    pveum user token remove root@pam "$api_token" >/dev/null || die 'não removi o token temporário'
    api_token=''
    rm -f -- "$api_header"
    api_header=''
}

run_api_case "$((base_old + offset))" "$((base_new + offset))"
printf 'OK: API (pvedaemon, perl -T) — troca completa com firewall\n'

printf 'Rock 5 renumber: PASS (%s; storages=%s)\n' "$node" "$storage_csv"
