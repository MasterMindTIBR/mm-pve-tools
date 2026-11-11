#!/usr/bin/env bash
# Validate the production environment before a release workflow uses it.
set -euo pipefail

readonly REPOSITORY="${GITHUB_REPOSITORY:-MasterMindTIBR/mm-pve-tools}"
readonly ENVIRONMENT="production"
readonly GH_BIN="${RELEASE_PREFLIGHT_GH:-gh}"

command -v "$GH_BIN" >/dev/null 2>&1 || {
    printf 'gh not found to query environment %s\n' "$ENVIRONMENT" >&2
    exit 127
}

if ! environment_json=$("$GH_BIN" api "repos/${REPOSITORY}/environments/${ENVIRONMENT}" 2>/dev/null); then
    printf 'environment %s does not exist or could not be queried\n' "$ENVIRONMENT" >&2
    exit 1
fi
if ! policy_json=$("$GH_BIN" api "repos/${REPOSITORY}/environments/${ENVIRONMENT}/deployment-branch-policies" 2>/dev/null); then
    printf 'could not query branch restrictions for environment %s\n' "$ENVIRONMENT" >&2
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
    print(f"invalid response from production environment: {exc}", file=sys.stderr)
    sys.exit(1)

reviewers = any(
    rule.get("type") == "required_reviewers" and rule.get("reviewers")
    for rule in environment.get("protection_rules", [])
)
if not reviewers:
    print("production environment has no required reviewer", file=sys.stderr)
    sys.exit(1)

names = {
    item.get("name")
    for item in policy.get("branch_policies", [])
    if isinstance(item, dict)
}
if names != {"master"}:
    print("production environment is not restricted to the master branch", file=sys.stderr)
    sys.exit(1)

print("release preflight OK: production requires a reviewer and is restricted to master")
PY
