# mm-pve-tools

Extensões da MasterMind TI para a GUI do Proxmox VE: um pacote, vários
módulos, aplicado em todos os nodes do cluster e sobrevivente aos updates do
PVE.

| Módulo | Faz o quê |
|---|---|
| `renumber` | Troca o VMID de uma VM usando `move_disk` (sem copiar dados), com journal, `--resume` e `--rollback` |
| `restore`  | Publica uma pasta de um backup PBS para a VM do cliente via SMB só-leitura, por tempo limitado, através da VM gateway |
| `branding` | Logo, favicon, título e textos da interface em todos os nodes |

O pacote `mm-gw-restore` instala o lado do gateway (VM Debian 13 dedicada).

Documentação de arquitetura e decisões: ver plano de handoff interno da
MasterMind. Regras de desenvolvimento: `AGENTS.md`.

## Instalação (resumo)

Repositório APT público: `https://apt.mastermindti.cloud/debian`
(suites `trixie`, componentes `stable` e `testing`):

```sh
apt install mastermind-apt-config   # chave + .sources + pin
apt install mm-pve-tools            # nodes PVE (traz o pve-file-restore-ntfs3g)
apt install mm-gw-restore           # VM gateway
```

Bootstrap do cluster: `bootstrap-cluster.sh` do repositório `MasterMindTIBR/apt`.

## Comandos principais

```sh
mm-pve status                 # diagnóstico do node (patches, revisão, ntfs3g)
mm-pve config get             # estado desejado (/etc/pve/mm-tools/config.json)
mm-pve apply                  # aplica patches + módulos ligados neste node
mm-pve renumber --from 100 --to 1100 [--dry-run|--resume|--rollback]
mm-pve restore publish --backup <storage>:backup/vm/<id>/<ts> --path <b64>
mm-pve branding set --logo logo.png --title "Cliente — Virtualização"
gw-restore selfcheck          # no gateway
```
O contrato entre node e gateway é versionado em
`contract/gw-restore.v1.schema.json`, com exemplos compartilhados em
`contract/fixtures/*.json` (um arquivo por definição do schema). O MESMO
fixture é validado por `t/contract/01_fixtures.t` (Perl, lado node) e por
`t/gateway/test_gw_restore.py::TestContractFixtures` (Python, lado
gateway): renomear um campo de um lado sem atualizar schema/fixture quebra
os dois testes. Sessões de restore aceitam no máximo 168 horas. Branding
aceita somente PNG de até 256 KiB, validado pela assinatura e pelo IHDR; os
assets instalados usam nomes content-addressed `<sha256>.png`.


## Desenvolvimento

```sh
make test          # Perl (prove) — sem PVE instalado
make test-gateway  # Python (unittest) — sem samba/nft/PBS
make js            # gera build/mm-tools.js a partir de js/src/
make build         # .deb dos dois pacotes (debhelper)
make check-anchors # valida as âncoras de patch contra fixtures upstream
```

Requisitos: Debian 13 (trixie), perl, python3, make, debhelper (build).

## Licença

AGPL-3.0-or-later (o código carrega dentro de processos do Proxmox VE, que é
AGPL-3). Ver `debian/copyright`.
