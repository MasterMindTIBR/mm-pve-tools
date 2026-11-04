#!/usr/bin/env bash
# shellcheck disable=SC2016
# Executa a prova Rock 7 na ordem congelada e grava apenas resumo sanitizado no repo.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091,SC2016
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_NODE1 LAB_NODE2 LAB_NODE3 LAB_EVIDENCE_DIR \
    LAB_RENUMBER1_NODE LAB_RENUMBER1_STORAGES LAB_RENUMBER1_OLD_VMID LAB_RENUMBER1_NEW_VMID \
    LAB_RENUMBER2_NODE LAB_RENUMBER2_STORAGES LAB_RENUMBER2_OLD_VMID LAB_RENUMBER2_NEW_VMID
lab_init_evidence
repo_root=$(cd -- "${script_dir}/../.." && pwd -P)
summary_dir="${repo_root}/docs/lab-evidence"
summary_file="${summary_dir}/$(date -u +%F).md"
mkdir -p -- "$summary_dir"
declare -a step_names=() step_states=()

write_summary() {
    # Versões dos .deb construídos nesta execução: deploy.sh instala o
    # mm-pve-tools nos nodes e gateway-vm.sh instala o mm-gw-restore na VM.
    local package_line='' deb
    for deb in "${repo_root}"/dist/mm-pve-tools_*.deb "${repo_root}"/dist/mm-gw-restore_*.deb; do
        [[ -f $deb ]] || continue
        package_line+="$(dpkg-deb -f "$deb" Package) $(dpkg-deb -f "$deb" Version); "
    done
    package_line=${package_line:-indisponível}
    {
        printf '# Evidência Rock 7 — resumo sanitizado\n\n'
        printf 'Gerado em UTC: %s\n\n' "$(date -u +%FT%TZ)"
        printf '| Etapa | Resultado | Versões dos pacotes |\n|---|---|---|\n'
        local index
        for index in "${!step_names[@]}"; do
            printf '| %s | %s | %s |\n' "${step_names[index]}" "${step_states[index]}" "$package_line"
        done
        printf '\nSomente resultado das etapas e versões de pacotes. Topologia, endereços, nomes de host, segredos e logs brutos ficam fora do repositório.\n'
    } >"$summary_file"
}

run_step() {
    local name=$1
    shift
    local log="${LAB_EVIDENCE_RUN_DIR}/run-all-${name}.log"
    local rc=0
    step_names+=("$name")
    printf 'PASSO: %s\n' "$name"
    "$@" >"$log" 2>&1 || rc=$?
    sed -n -E '/^(PASSO|OK|FALHA):/p' "$log" || true
    if (( rc == 0 )); then
        step_states+=(PASS)
        return 0
    fi
    step_states+=(FAIL)
    printf 'FALHA: Rock 7 parou em %s (evidência: %s)\n' "$name" "$log" >&2
    return "$rc"
}

status=0
run_step deploy bash "${script_dir}/deploy.sh" || status=$?
if (( status == 0 )); then run_step api-smoke bash "${script_dir}/api-smoke.sh" || status=$?; fi
if (( status == 0 )); then
    run_step renumber-node-1 bash "${script_dir}/e2e-renumber.sh" \
        "$LAB_RENUMBER1_NODE" "$LAB_RENUMBER1_STORAGES" "$LAB_RENUMBER1_OLD_VMID" "$LAB_RENUMBER1_NEW_VMID" || status=$?
fi
if (( status == 0 )); then
    run_step renumber-node-2 bash "${script_dir}/e2e-renumber.sh" \
        "$LAB_RENUMBER2_NODE" "$LAB_RENUMBER2_STORAGES" "$LAB_RENUMBER2_OLD_VMID" "$LAB_RENUMBER2_NEW_VMID" || status=$?
fi
if (( status == 0 )); then run_step gateway-vm bash "${script_dir}/gateway-vm.sh" || status=$?; fi
if (( status == 0 )); then run_step restore bash "${script_dir}/e2e-restore.sh" || status=$?; fi
if (( status == 0 )); then run_step branding bash "${script_dir}/e2e-branding.sh" || status=$?; fi

write_summary
if (( status != 0 )); then
    printf 'BLOCKED: Rock 7 interrompido na primeira falha; resumo: %s\n' "$summary_file" >&2
    exit "$status"
fi
lab_pass "Rock 7 concluído; resumo sanitizado: $summary_file"
