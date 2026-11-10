#!/usr/bin/env bash
# Constrói e instala mm-pve-tools nos três nodes PVE; o gateway instala seu próprio pacote.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091
source "${script_dir}/lab-common.sh"
lab_load_env
lab_require LAB_SSH_CONFIG LAB_NODE1 LAB_NODE2 LAB_NODE3 LAB_EVIDENCE_DIR \
    LAB_MASTERMIND_APT LAB_MASTERMIND_KEY_URL
lab_init_evidence
repo_root=$(cd -- "${script_dir}/../.." && pwd -P)
build_log="${LAB_EVIDENCE_RUN_DIR}/build.log"

# Versão acima da publicada: senão um dist-upgrade real no lab (prova do
# módulo updates) troca o build em teste pelo mm-pve-tools do APT.
version_suffix="lab$(date -u +%Y%m%d%H%M%S)"
if git_rev=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null); then
    version_suffix+=".g${git_rev}"
fi
lab_step "build: scripts/build-deb.sh (+${version_suffix})"
rc=0
"${repo_root}/scripts/build-deb.sh" "--version-suffix=${version_suffix}" >"$build_log" 2>&1 || rc=$?
cat "$build_log"
(( rc == 0 )) || lab_fail "build dos pacotes falhou (consulte $build_log)"

mapfile -t node_packages < <(find "${repo_root}/dist" -maxdepth 1 -type f \
    -name 'mm-pve-tools_*.deb' -print | sort)
(( ${#node_packages[@]} == 1 )) || lab_fail 'dist não contém exatamente um pacote mm-pve-tools esperado'
for package in "${node_packages[@]}"; do
    [[ -s $package ]] || lab_fail "pacote vazio: $package"
done

for node in "$LAB_NODE1" "$LAB_NODE2" "$LAB_NODE3"; do
    label="deploy-${node//[^A-Za-z0-9_.-]/_}"
    lab_step "deploy: mm-pve-tools em ${node}"
    node_log="${LAB_EVIDENCE_RUN_DIR}/${label}.log"
    : >"$node_log"
    for package in "${node_packages[@]}"; do
        base=$(basename -- "$package")
        scp_rc=0
        lab_scp_to "$package" "$node" "/tmp/$base" >>"$node_log" 2>&1 || scp_rc=$?
        (( scp_rc == 0 )) || lab_fail "scp de $base para $node falhou"
        install_rc=0
        lab_ssh "$node" bash -s -- "$base" "$LAB_MASTERMIND_APT" \
            "$LAB_MASTERMIND_KEY_URL" >>"$node_log" 2>&1 <<'REMOTE' || install_rc=$?
set -euo pipefail
deb=$1
mastermind_apt=$2
mastermind_key_url=$3
cd /tmp
installed=0
if dpkg-query -W -f='${Status}' pve-file-restore-ntfs3g 2>/dev/null | \
    grep -q '^install ok installed$'; then
    installed=1
fi
if (( installed == 0 )); then
    temp_key=/etc/apt/keyrings/mm-pve-rock7.gpg
    temp_source=/etc/apt/sources.list.d/mm-pve-rock7-temporary.list
    cleanup_apt() { rm -f -- "$temp_source" "$temp_key"; }
    trap cleanup_apt EXIT
    install -d -m 0755 /etc/apt/keyrings
    curl --fail --silent --show-error --location "$mastermind_key_url" -o "$temp_key"
    chmod 0644 "$temp_key"
    printf 'deb [signed-by=%s] %s trixie testing\n' "$temp_key" "$mastermind_apt" >"$temp_source"
    apt-get update -qq
    apt-get install -y --no-install-recommends mastermind-apt-config
    rm -f -- "$temp_source" "$temp_key"
    mastermind-apt-channel testing
    apt-get update -qq
fi
# --reinstall: um build novo com a mesma versão do instalado seria ignorado
apt-get install -y --reinstall "./$deb"
rm -f -- "./$deb"
REMOTE
        (( install_rc == 0 )) || lab_fail "apt install de $base em $node falhou"
    done
    version_rc=0
    lab_ssh "$node" bash -s >>"$node_log" 2>&1 <<'REMOTE' || version_rc=$?
set -euo pipefail
dpkg-query -W -f='${binary:Package} ${Version}\n' mm-pve-tools
REMOTE
    (( version_rc == 0 )) || lab_fail "não consegui confirmar versões em $node"
    cat "$node_log"
done
lab_pass 'deploy concluído nos três nodes; nenhum restart manual foi executado'
