#!/usr/bin/env bash
# Prova de laboratório do Rock 5.
# Uso: e2e-renumber.sh NODE STORAGE[,STORAGE...] OLD_VMID NEW_VMID
# Exemplo no lab: e2e-renumber.sh lab1 zfs-lab1,dir-lab1 9100 9200
#
# O script só destrói VMs que criou nesta execução e cuja descrição ainda
# contém o marcador deste teste. Ele deve ser executado em um node PVE.

set -u

if [[ $# -ne 4 ]]; then
    printf 'uso: %s NODE STORAGE[,STORAGE...] OLD_VMID NEW_VMID\n' "$0" >&2
    exit 2
fi

node=$1
storage_csv=$2
base_old=$3
base_new=$4
marker="mm-pve-tools e2e-renumber $$"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mm-renumber-e2e.XXXXXX")
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
    rm -rf "$tmp_dir"
}
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
    grep -q '"state": "finished"' "$journal" \
        || die "journal $journal não terminou"
}

run_resume_case() {
    local old=$1 new=$2 step=$3
    local log="$tmp_dir/resume-$old.log"
    create_fixture "$old" "$new"
    run_injected "$step" "$old" "$new" "$log"
    if [[ $step == destroy ]]; then
        ! vm_exists "$old" || die "VM antiga ainda existe após destroy"
    else
        vm_exists "$old" || die "VM antiga sumiu antes do destroy"
    fi
    mm-pve renumber --resume --from "$old" --to "$new" --node "$node" \
        >"$log" 2>&1 || die "resume falhou no passo $step (ver $log)"
    vm_exists "$new" || die "VM nova não existe após resume de $step"
    if [[ $step != destroy ]]; then
        ! vm_exists "$old" || die "VM antiga ainda existe após resume de $step"
    fi
    assert_finished "$old" "$new"
}

run_rollback_case() {
    local old=$1 new=$2 step=$3
    local log="$tmp_dir/rollback-$old.log"
    create_fixture "$old" "$new"
    run_injected "$step" "$old" "$new" "$log"
    if [[ $step == destroy ]]; then
        if mm-pve renumber --rollback --from "$old" --to "$new" --node "$node" \
            >"$log" 2>&1; then
            die 'rollback após destroy foi aceito'
        fi
        grep -qi 'rollback recusado' "$log" || die 'rollback não explicou a recusa pós-destroy'
        return
    fi
    mm-pve renumber --rollback --from "$old" --to "$new" --node "$node" \
        >"$log" 2>&1 || die "rollback falhou no passo $step (ver $log)"
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

printf 'Rock 5 renumber: PASS (%s; storages=%s)\n' "$node" "$storage_csv"
