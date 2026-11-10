#!/usr/bin/env bash
# Funções comuns dos scripts de prova no laboratório.
set -euo pipefail

lab_load_env() {
    local script_dir env_file
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd -P)
    env_file=${LAB_ENV_FILE:-${script_dir}/lab.env}
    [[ -r $env_file ]] || {
        printf 'FALHA: crie lab.env a partir de %s\n' "${script_dir}/lab.env.example" >&2
        return 1
    }
    # lab.env é operador-local e não deve conter comandos; valores são strings.
    # shellcheck disable=SC1090
    source "$env_file"
    export LAB_ENV_FILE="$env_file"
}

lab_require() {
    local name
    for name in "$@"; do
        [[ -n ${!name:-} ]] || {
            printf 'FALHA: variável ausente em lab.env: %s\n' "$name" >&2
            return 1
        }
    done
}

lab_init_evidence() {
    lab_require LAB_EVIDENCE_DIR
    if [[ -z ${LAB_EVIDENCE_RUN_DIR:-} ]]; then
        LAB_EVIDENCE_RUN_DIR="${LAB_EVIDENCE_DIR}/$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p -- "$LAB_EVIDENCE_RUN_DIR"
    chmod 0700 -- "$LAB_EVIDENCE_RUN_DIR"
    export LAB_EVIDENCE_RUN_DIR
}

lab_step() {
    printf 'PASSO: %s\n' "$*"
}

lab_pass() {
    printf 'OK: %s\n' "$*"
}

lab_fail() {
    printf 'FALHA: %s\n' "$*" >&2
    return 1
}

lab_node_url() {
    local node=$1
    printf '%s://%s:%s' "$LAB_API_SCHEME" "$node" "$LAB_API_PORT"
}

lab_ssh() {
    local node=$1
    local remote_command='' quoted arg
    shift
    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        remote_command+="${remote_command:+ }${quoted}"
    done
    ssh -F "$LAB_SSH_CONFIG" "$node" "$remote_command"
}

# lab_kick_apply NODE...: o set-module só grava o config e cada node aplica no
# timer de 5 min. Pede o apply agora pela própria unit, como o operador faria.
# Um apply já em curso pode ter lido o config antigo e o start se juntaria a
# ele sem rodar de novo; por isso espera ele acabar antes de pedir outro.
lab_kick_apply() {
    local node
    for node in "$@"; do
        # shellcheck disable=SC2016  # o script roda no node
        lab_ssh "$node" bash -c 'for _ in $(seq 1 150); do
            case $(systemctl show --property=ActiveState --value mm-pve-apply.service) in
                activating|deactivating|reloading) sleep 2 ;;
                *) break ;;
            esac
        done
        systemctl start --no-block mm-pve-apply.service'
    done
}

lab_scp_to() {
    local source=$1 node=$2 destination=$3
    scp -F "$LAB_SSH_CONFIG" "$source" "${node}:${destination}"
}

lab_scp_from() {
    local node=$1 source=$2 destination=$3
    scp -r -F "$LAB_SSH_CONFIG" "${node}:${source}" "$destination"
}

lab_record_command() {
    local name=$1
    shift
    local output="${LAB_EVIDENCE_RUN_DIR}/${name}.log"
    local rc=0
    "$@" >"$output" 2>&1 || rc=$?
    cat "$output"
    return "$rc"
}

lab_assert_command() {
    local label=$1
    shift
    local rc=0
    "$@" || rc=$?
    (( rc == 0 )) || lab_fail "$label (rc=$rc)"
}

lab_cleanup_file() {
    local path=$1
    [[ -n $path && -e $path ]] && rm -f -- "$path"
}
