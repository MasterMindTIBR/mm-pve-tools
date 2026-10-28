# AGENTS.md — regras e contratos do `mm-pve-tools`

Leia isto antes de mexer no repositório. O plano de origem é
`~/Desktop/PLAN-mm-pve-tools.md` (handoff definitivo; em caso de conflito, **o
plano vence** e a divergência vai para "Questões em aberto" dele).

## O que é

Pacote `mm-pve-tools` (nodes PVE) + `mm-gw-restore` (VM gateway de restore),
monorepo, público (`MasterMindTIBR/mm-pve-tools`). Nenhum segredo, nenhum dado
de cliente, nada de nome/IP/VLAN/hostname de cliente em código, issues, PRs,
logs de CI, fixtures ou capturas.

## Layout e donos

| Caminho | Instala em | Dono |
|---|---|---|
| `bin/mm-pve` | `/usr/sbin/mm-pve` | núcleo |
| `lib/MMPve/Core/*.pm`, `lib/MMPve/Journal.pm` | `/usr/share/perl5/` | núcleo |
| `lib/MMPve/Module/<Nome>.pm` | `/usr/share/perl5/` | módulo `<nome>` |
| `perl/PVE/API2/MMTools.pm` | `/usr/share/perl5/` | núcleo |
| `perl/PVE/API2/MMTools/<Nome>.pm` | `/usr/share/perl5/` | módulo `<nome>` |
| `js/src/core.js` + `js/src/<nome>.js` | concatenados em `/usr/share/pve-manager/js/mm-tools.js` | core.js=núcleo, resto=módulo |
| `lib/mm-pve-tools/apply-patches` | `/usr/lib/mm-pve-tools/` | núcleo |
| `systemd/`, `debian/` | — | núcleo |
| `gateway/` | pacote `mm-gw-restore` | gateway |
| `t/<area>/` | — | área correspondente |

`refs/upstream/` (gitignored) guarda arquivos reais do `pve-manager` 9.2.24
(`Nodes.pm`, `index.html.tpl`, `pvemanagerlib.js` e recortes) para conferir
âncoras e classes da GUI. Fixture de teste vive em `t/fixtures/pve-manager/`.

## Regras invioláveis

1. **Nada de módulo interno do PVE fora de `perl/PVE/API2/MMTools*.pm`.**
   O resto fala com o cluster por `pvesh`/`qm` via `MMPve::Core::Runner`.
2. **Nenhuma senha/token em log, Task Log, journal, URL ou pacote.**
3. `apply`/`revert` de módulo são idempotentes; módulo desligado roda `revert`.
4. Falha de patch deixa o PVE original; `pveproxy`/`pvedaemon` nunca ficam
   parados (o `MMPve::Core::Patch` verifica e reverte sozinho).
5. Perl: `use strict; use warnings;` sempre. Sem dependências fora do perl core
   (JSON::PP, Digest::SHA, IPC::Open3, Getopt::Long, POSIX…).
6. `t/lib-stubs/` tem stubs mínimos de `PVE::*` só para `perl -c` dos
   endpoints sem PVE instalado (`make lint` e CI usam `-It/lib-stubs`).
   Nunca em runtime ou teste de comportamento.
7. Testes rodam sem PVE instalado: `prove -Ilib -Iperl -r t` tem que passar em
   qualquer Debian 13. Gateway: `python3 -m unittest discover -s t/gateway -v`
   (top-level do repo) — sem samba/nft/PBS.
8. Não atualize `debian/changelog` por commit; versão é `X.Y.Z` (SemVer) +
   `CHANGELOG.md` com `[Unreleased]` até a release.
9. GUI JS: Ext JS 6 (estilo `pvemanagerlib.js`), namespace `MM.*`, registro de
   aba via `MM.registerTab(...)`. O arquivo final é concatenação na ordem do
   `Makefile` (`core.js, renumber.js, restore.js, branding.js`) — nunca edite
   um `mm-tools.js` gerado.

## Contratos

### Runner (única porta de saída para comandos)

```perl
my $res = MMPve::Core::Runner->run(['pvesh', 'get', '/version'], timeout => 30);
# $res = { ok => 1, rc => 0, out => "...", err => "" }
my $data = MMPve::Core::Runner->pvesh(get => '/cluster/status');   # JSON decodificado; die em erro
```

### ModuleBase

```perl
package MMPve::Module::X;
use base qw(MMPve::Core::ModuleBase);
sub name       { 'x' }                       # igual à chave em modules => {}
sub validate_section { my ($class, $sec) = @_; return @erros }  # "" = ok
sub apply  { my ($class, $cfg) = @_; ... }   # idempotente; die ou retorna hash
sub revert { my ($class) = @_; ... }
sub check  { my ($class, $cfg) = @_; ... }   # hashref p/ diagnóstico
sub cli    { my ($class, $av) = @_; ... }    # subcomandos `mm-pve x ...`
```

Registro: `MMPve::Core::Modules->all()` (núcleo). Endpoint: classe
`PVE::API2::MMTools::X` registrada como subclass em `MMTools.pm` (núcleo
mantém o registro; módulo só implementa a classe).

### Config (estado desejado em `/etc/pve/mm-tools/config.json`)

```perl
my ($cfg, $digest) = MMPve::Core::Config->load();
MMPve::Core::Config->save($novo, digest => $digest);   # CAS por digest, flock, revision++
```

Testes apontam `$ENV{MM_PVE_CONFIG_DIR}` e `$ENV{MM_PVE_ROOT}` para tmp.

### Journal (passos de tarefa longa, replicado pelo pmxcfs)

`/etc/pve/mm-tools/journal/<id>.json`; `mark_running` ANTES de executar o
passo, `mark_done`/`mark_failed` depois; `first_pending` para `--resume`;
`rollback_steps` em ordem inversa para `--rollback`.

### Gateway (`mm-gw-restore`)

Python 3 stdlib puro (`gw-restore`), raiz `/srv/gw-restore`, estado
`/var/lib/gw-restore`, auditoria `/var/log/gw-restore/audit.log`, lock
`flock /run/gw-restore.lock`. Contrato JSON de `publish`/`revoke`/`list`/`gc`/
`selfcheck` está no plano (seção "No gateway"). Entrada e saída de senha:
senha só no stdout do `publish` e no `/run/mm-pve-tools/results/<upid>.json`
(0600, dono da tarefa, apagado na leitura). Nunca em log.

## Comandos

```sh
make test            # prove -Ilib -Iperl -r t  (exclui t/gateway)
make test-gateway    # unittest python
make js              # concatena js/src → build/mm-tools.js
make lint            # perl -c em tudo + shellcheck se houver
make build           # dpkg-buildpackage -us -uc -b (precisa debhelper)
make pkg-direct      # staging + dpkg-deb --build (sem debhelper; smoke local)
make check-anchors   # apply-patches --check contra t/fixtures/pve-manager
```

CI (`.github/workflows/ci.yml`) roda lint, testes, build com lintian em
`debian:13`, teste de âncoras contra o `pve-manager` mais recente do
`pve-no-subscription` e compatibilidade com as releases do ntfs3g.

## Upstream PVE — âncoras vigentes (9.2.24)

- `index.html.tpl`: linha com `/pve2/js/pvemanagerlib.js?ver=[% version %]` →
  inserir depois o `<script ... src="/pve2/js/mm-tools.js?ver=[% version %]">`.
- `Nodes.pm` (package `PVE::API2::Nodes::Nodeinfo`): `use PVE::API2::Replication;`
  e o bloco `register_method` com `subclass => "PVE::API2::Replication"` →
  inserir `use PVE::API2::MMTools; # mm-pve-tools` e o
  `register_method({ subclass => "PVE::API2::MMTools", path => 'mm-tools' }); # mm-pve-tools`.
- Branding: `PMX.image.LogoSVG` em `proxmox-widget-toolkit/src/Logo.js`.

## Procedimento de update do PVE (resumo)

1. lab antes; 2. `grep mm-pve-tools` nos dois arquivos pós-update (trigger
deveria ter reaplicado); 3. checklist da GUI; 4. só então cliente.
