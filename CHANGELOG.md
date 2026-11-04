# Changelog

Todas as mudanças notáveis deste projeto ficam aqui. Formato baseado em
[Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versão segue
[SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

## [0.2.0] - 2026-11-04

Primeira versão publicada. Provada num cluster PVE 9 de três nodes com PBS e
gateway Debian 13 (`docs/lab-evidence/2026-11-03.md`).

### Adicionado

- Núcleo `mm-pve` (`config`, `apply`, `status`, `patch`): estado desejado do
  cluster em `/etc/pve/mm-tools/config.json` (replicado pelo pmxcfs) e
  aplicação por node no boot, a cada 5 minutos e quando o `pve-manager` é
  atualizado (trigger do dpkg). O patch de `index.html.tpl` e `Nodes.pm` é
  transacional e recarrega o pveproxy/pvedaemon só quando algo muda.
- API `/nodes/{node}/mm-tools/...` com as permissões reais do PVE e tarefas
  no Task Log; GUI com a aba MasterMind no Datacenter.
- Módulo **renumber**: troca o VMID com `move_disk`, sem copiar dados.
  Journal com `--resume` e `--rollback`; trata HA (regras do PVE 9), backup
  jobs, replicação, pools, ACLs e cloud-init. Menu "Trocar ID…" na VM.
- Módulo **restore**: publica uma pasta de um backup PBS para a VM do
  cliente por SMB3 somente leitura, por até 168 horas, através da VM gateway.
  Botão "Publicar pasta…" nos backups e lista de publicações ativas.
- Pacote **mm-gw-restore** para a VM gateway: contrato versionado com o node
  (`contract/gw-restore.v1.schema.json`), Samba e nftables isolando cada VM,
  retomada segura depois de falha ou reboot.
- Módulo **branding**: logo e título em todos os nodes; só PNG de até
  256 KiB, gravado pelo sha256 junto com a configuração.
- Pacotes Debian (`debhelper`) com lintian limpo, release em pre-release
  (canal `testing` do APT) e promoção para `stable` com aprovação no
  environment `production`.

### Limites conhecidos

- O restore de arquivos deduplicados grandes do Windows depende do
  `pve-file-restore-ntfs3g` com o plugin de dedup corrigido.
- Duas sessões de restore na mesma VLAN usam o mesmo IP do gateway, e o
  Windows recusa uma segunda credencial no mesmo servidor (erro 1219).
