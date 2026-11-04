#!/usr/bin/env bash
# Move CHANGELOG.md [Unreleased] notes into a Debian release entry.
set -euo pipefail

if [[ $# -ne 1 || ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'uso: %s X.Y.Z\n' "$0" >&2
    exit 2
fi

readonly VERSION="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO_ROOT
DATE="$(date +%F)"
readonly DATE
DEBIAN_DATE="$(date -R)"
readonly DEBIAN_DATE

python3 - "$REPO_ROOT" "$VERSION" "$DATE" "$DEBIAN_DATE" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
version = sys.argv[2]
date = sys.argv[3]
debian_date = sys.argv[4]
changelog_path = root / "CHANGELOG.md"
debian_path = root / "debian" / "changelog"
markdown = changelog_path.read_text(encoding="utf-8")
marker = "## [Unreleased]"
start = markdown.find(marker)
if start < 0:
    raise SystemExit("CHANGELOG.md sem a seção [Unreleased]")
notes_start = start + len(marker)
next_heading = markdown.find("\n## [", notes_start)
if next_heading < 0:
    next_heading = len(markdown)
notes = markdown[notes_start:next_heading].strip()
if not notes:
    raise SystemExit("a seção [Unreleased] está vazia")
if f"## [{version}]" in markdown:
    raise SystemExit(f"CHANGELOG.md já contém a versão {version}")

debian = debian_path.read_text(encoding="utf-8")
if debian.startswith(f"mm-pve-tools ({version}-"):
    raise SystemExit(f"debian/changelog já contém a versão {version}")
debian_lines = []
for line in notes.splitlines():
    if line.startswith("### "):
        debian_lines.append("  * " + line[4:] + ":")
    elif line.startswith("- "):
        debian_lines.append("  * " + line[2:])
    elif line.startswith("  "):
        debian_lines.append("    " + line.lstrip())
    elif line:
        debian_lines.append("  * " + line)
    else:
        debian_lines.append("")
entry = (
    f"mm-pve-tools ({version}-1) unstable; urgency=medium\n\n"
    + "\n".join(debian_lines)
    + f"\n\n -- MasterMind TI <infra@mastermindti.cloud>  {debian_date}\n\n"
)
debian_path.write_text(entry + debian, encoding="utf-8")

updated = markdown[:notes_start] + "\n\n"
updated += f"## [{version}] - {date}\n\n{notes}\n"
updated += markdown[next_heading:]
changelog_path.write_text(updated, encoding="utf-8")
PY

printf 'versão %s adicionada a debian/changelog e movida de [Unreleased]\n' "$VERSION"
