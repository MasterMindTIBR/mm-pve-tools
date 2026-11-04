# Changelog

Todas as mudanças notáveis deste projeto ficam aqui. Formato baseado em
[Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versão segue
[SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

### Adicionado

- Núcleo `mm-pve`: `config`/`apply`/`status`/`patch`, estado desejado em
  `/etc/pve/mm-tools/config.json` (digest + revision calculada no servidor,
  gravação via `cfs_lock_domain` do pmxcfs quando disponível), aplicação por
  node com `applied.json`, timer `mm-pve-apply` (boot + 5 min) e trigger dpkg
  que reaplica os patches do `pve-manager` (reload-or-restart fora do
  processo do `pvedaemon` via `systemd-run`).
- Patch mínimo de 1 linha em `index.html.tpl` e `Nodes.pm` com verificação
  `perl -c`, restart seguro e reversão automática.
- API `/nodes/{node}/mm-tools/...` (`PVE::API2::MMTools`) com `proxyto =>
  'node'` em todos os endpoints, permissões `Sys.Audit`/`Sys.Modify`
  consistentes, IDs de tarefa compatíveis com `PVE::UPID` e tarefas em
  worker (Task Log).
- GUI `mm-tools.js`: aba Datacenter → MasterMind (Geral e Diagnóstico),
  consumindo o envelope `{data: ...}` das respostas da API.
- Módulo **renumber**: troca de VMID via `move_disk` com pré-checagens que
  tratam erro de API como falha dura, journal com `--resume`/`--rollback`
  que relêem o estado real das duas VMs (nunca confiam cegamente no
  journal), `protection` preservada entre origem/destino, suporte a
  qualquer storage com a feature `rename` (`PVE::Storage::volume_has_feature`,
  incluindo LVM e RBD), ACLs de usuário/grupo/token preservadas por tipo,
  menu "Trocar ID…" na VM e validação de faixa no wizard.
- Módulo **restore**: publicação de pasta de backup PBS por VM gateway
  (SMB3 obrigatório, credencial por sessão, expiração máxima de 168h),
  resultado fora do Task Log, botão "Publicar pasta…" com seletor de
  caminho real do backup, e "Publicações ativas".
- Contrato node↔gateway versionado (`contract/gw-restore.v1.schema.json`,
  `contract: 1`), com fixtures compartilhadas entre os testes Perl e Python
  (`contract/fixtures/*.json`) validadas contra o mesmo schema dos dois
  lados.
- Pacote **mm-gw-restore**: `gw-restore` (publish/revoke/list/gc/selfcheck)
  validando o contrato, refcounts invalidados por `boot_id` após reboot,
  `gc --boot` ligado ao boot, sysctl de hardening, tabela nftables com
  `iifname`, include do Samba como última linha do `smb.conf` (nunca logo
  após `[global]`) e `server min protocol = SMB3`.
- Módulo **branding**: logo/favicon apenas PNG (≤200 KiB, assinatura
  verificada) com override de componentes, imagens em
  `/usr/share/pve-manager/images/mm-branding/`, texto do topo escapado
  (sem XSS), e inconsistência de assets em disco nunca derruba a leitura
  da configuração.
- CI: lint (perl -c + perlcritic + eslint + shellcheck nos maintainer
  scripts), testes, build+lintian em `debian:13` publicando `.deb`+
  `.changes`+`.buildinfo`, teste de âncoras aplicando os patches de verdade
  contra o `pve-manager`/`proxmox-widget-toolkit` mais recentes, workflows
  de release (pre-release `testing`) e promoção (`stable`, aprovação do
  Jung via environment `production`).
