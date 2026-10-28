#!/usr/bin/python3
"""Gera DEBIAN/control do build direto (make pkg-direct) a partir de
debian/control, com o que o debhelper resolveria no build normal:
  Version/Maintainer -> copiados da stanza Source
  ${perl:Depends}    -> perl
  ${misc:Depends}    -> (removido)
Uso: pkg-direct-control.py <pacote> <debian/control> <saída>"""
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    pkg, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    text = open(src, encoding="utf-8").read()

    # metadados da stanza Source
    version, maintainer = None, None
    stanzas = [s for s in text.split("\n\n") if s.strip()]
    for s in stanzas:
        first = s.splitlines()[0].strip()
        if first.startswith("Source:"):
            for line in s.splitlines():
                if line.startswith("Maintainer:"):
                    maintainer = line.split(":", 1)[1].strip()
                elif line.startswith("Version:"):
                    version = line.split(":", 1)[1].strip()
            break

    stanza = None
    for s in stanzas:
        first = s.splitlines()[0].strip()
        if first == f"Package: {pkg}":
            stanza = s
            break
    if stanza is None:
        print(f"stanza de {pkg} não encontrada", file=sys.stderr)
        return 1

    lines = stanza.splitlines()
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("Depends:"):
            field = [line[len("Depends:"):].strip()]
            i += 1
            while i < len(lines) and lines[i].startswith((" ", "\t")):
                field.append(lines[i].strip())
                i += 1
            deps = []
            for part in ",".join(field).split(","):
                part = part.strip()
                if not part or part.startswith("${"):
                    continue
                if part not in deps:
                    deps.append(part)
            if "perl" not in deps:
                deps.insert(0, "perl")  # resolve ${perl:Depends}
            out.append("Depends: " + ", ".join(deps))
            continue
        out.append(line)
        i += 1

    out.append(f"Version: {version or '0.1.0-1'}")
    out.append(f"Maintainer: {maintainer or 'MasterMind TI <infra@mastermindti.cloud>'}")

    open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
