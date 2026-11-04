#!/usr/bin/env bash
# Validate the production environment before a release workflow uses it.
set -euo pipefail

readonly REPOSITORY="${GITHUB_REPOSITORY:-MasterMindTIBR/mm-pve-tools}"
readonly ENVIRONMENT="production"
readonly GH_BIN="${RELEASE_PREFLIGHT_GH:-gh}"

command -v "$GH_BIN" >/dev/null 2>&1 || {
    printf 'gh não encontrado para consultar o ambiente %s\n' "$ENVIRONMENT" >&2
    exit 127
}

if ! environment_json=$("$GH_BIN" api "repos/${REPOSITORY}/environments/${ENVIRONMENT}" 2>/dev/null); then
    printf 'ambiente %s não existe ou não pôde ser consultado\n' "$ENVIRONMENT" >&2
    exit 1
fi
if ! policy_json=$("$GH_BIN" api "repos/${REPOSITORY}/environments/${ENVIRONMENT}/deployment-branch-policies" 2>/dev/null); then
    printf 'não foi possível consultar as restrições de branch do ambiente %s\n' "$ENVIRONMENT" >&2
    exit 1
fi

export environment_json policy_json
python3 - <<'PY'
import json
import os
import sys

try:
    environment = json.loads(os.environ["environment_json"])
    policy = json.loads(os.environ["policy_json"])
except (KeyError, json.JSONDecodeError) as exc:
    print(f"resposta inválida do ambiente production: {exc}", file=sys.stderr)
    sys.exit(1)

reviewers = any(
    rule.get("type") == "required_reviewers" and rule.get("reviewers")
    for rule in environment.get("protection_rules", [])
)
if not reviewers:
    print("ambiente production não possui required reviewer", file=sys.stderr)
    sys.exit(1)

names = {
    item.get("name")
    for item in policy.get("branch_policies", [])
    if isinstance(item, dict)
}
if names != {"master"}:
    print("ambiente production não está restrito à branch master", file=sys.stderr)
    sys.exit(1)

print("preflight de release OK: production exige reviewer e está restrito à master")
PY
