# Changelog

Todas as mudanças notáveis deste projeto ficam aqui. Formato baseado em
[Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versão segue
[SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

### Adicionado

- Núcleo `mm-pve`: `config`/`apply`/`status`/`patch`, estado desejado em
  `/etc/pve/mm-tools/config.json` (digest + revision + flock), aplicação por
  node com `applied.json`, timer `mm-pve-apply` (boot + 5 min) e trigger dpkg
  que reaplica os patches do `pve-manager`.
- Patch mínimo de 1 linha em `index.html.tpl` e `Nodes.pm` com verificação
  `perl -c`, restart seguro e reversão automática.
- API `/nodes/{node}/mm-tools/...` (`PVE::API2::MMTools`) com tarefas em
  worker (Task Log).
- GUI `mm-tools.js`: aba Datacenter → MasterMind (Geral e Diagnóstico).
- Módulo **renumber**: troca de VMID via `move_disk` com pré-checagens,
  journal com `--resume`/`--rollback`, menu "Trocar ID…" na VM e validação de
  faixa no wizard.
- Módulo **restore**: publicação de pasta de backup PBS por VM gateway
  (SMB só-leitura, credencial por sessão, expiração), resultado fora do Task
  Log, botão "Publicar pasta…" e "Publicações ativas".
- Pacote **mm-gw-restore**: `gw-restore` (publish/revoke/list/gc/selfcheck),
  sysctl de hardening, base nftables, include do Samba, timer de GC.
- Módulo **branding**: logo/favicon/título/textos com override de componentes,
  imagens em `/usr/share/pve-manager/images/mm-branding/`, sanitização de SVG.
- CI: lint, testes, build+lintian em `debian:13`, teste de âncoras contra o
  `pve-manager` mais recente, workflows de release (pre-release `testing`) e
  promoção (`stable`, aprovação do Jung).
