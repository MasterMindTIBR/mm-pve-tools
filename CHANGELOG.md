# Changelog

Todas as mudanças notáveis deste projeto ficam aqui. Formato baseado em
[Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versão segue
[SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

## [0.3.1] - 2026-11-10

### Alterado

- O `mm-pve-tools` passa a exigir o `pve-file-restore-ntfs3g` 2.1.11 ou mais
  novo, a versão com a imagem de restore `1.0.0+ntfs3g11`, que é a publicada
  no canal `stable` e a usada na prova do lab. Antes aceitava a 2.0.0.

## [0.3.0] - 2026-11-10

Limites por pool, atualização dos nodes pela GUI, console padrão por tipo e
fim do pop-up de assinatura. Provada num cluster PVE 9.2 de três nodes
(`docs/lab-evidence/2026-11-10.md`). Os três módulos novos vêm desligados.

### Adicionado

- Módulo **poollimits**: limite de vCPU, RAM, disco total e disco por
  storage em cada pool, cada um com seu liga/desliga. O pool conta o que está
  alocado ou só o que está ligado. O limite vale em create, clone, restore,
  entrada no pool, hardware edit, resize, import, alocação no storage, start
  pela CLI, API e HA, e migração; a recusa acontece antes de qualquer efeito
  e diz o pool, o uso atual, o pedido e o limite. Aba "Limites" no painel do
  pool: edita quem tem `Sys.Modify` em `/`; quem tem só `Pool.Audit` vê sem
  editar.
- Módulo **updates**: dashboard de atualização dos nodes no Datacenter. Um
  node, uma seleção ou todos, em sequência ou em paralelo, com o status de
  cada node. Sugere reboot só quando o kernel muda; o reboot pede
  confirmação tripla na GUI, e o backend repete a checagem e exige
  `Sys.PowerMgmt`. O trabalho roda numa unit transitória do systemd, com
  log no Task Log.
- Módulo **ui**: console padrão separado para VM e CT, com padrão do
  cluster e preferência por usuário em "My Settings" (sem preferência, vale
  a do cluster). Opção de esconder só o pop-up de assinatura.

### Alterado

- A tela MasterMind do Datacenter passa a se chamar **MM Tools** e ganha a
  aba "Sobre": versão, módulos, links do código e do APT, créditos e
  licença.
- Os patches agora podem mirar módulos de outros pacotes do PVE
  (`qemu-server`, `pve-container`, `libpve-guest-common-perl`,
  `libpve-storage-perl`, `libpve-access-control`), além do `pve-manager`.
  Cada grupo é aplicado e revertido inteiro; cada arquivo é validado como o
  próprio módulo antes de entrar; um patch que falhou antes não trava o
  apply (`mm-pve patch clear-failures`, também chamado na instalação).
- Depois de um patch, os daemons são recarregados com
  `systemctl try-reload-or-restart` (os do HA não aceitam reload).

### Limites conhecidos

- Ligar ou desligar um módulo leva até ~5 minutos para valer em cada node
  (o apply roda num timer). Para valer na hora, rode `mm-pve apply` em cada
  node.
- O modo paralelo do updates atualiza todos os nodes escolhidos ao mesmo
  tempo; o preflight só exige quórum, HA sem erro e Ceph `HEALTH_OK`. Em
  produção, prefira um node de cada vez. O reboot é o do próprio PVE: os
  guests seguem a política de shutdown do HA e do `pve-guests`, e nada é
  migrado antes.
- Não provados no lab: replicação, import de OVA, migração de CT com troca
  de storage, cluster com Ceph e desempenho com muitos guests por pool.
- `mm-pve updates reboot` sem `--confirm`, ou com o nome errado, recusa mas
  sai com rc 255 em vez de 2.
- Erros do gateway com acento chegam ao Task Log com UTF-8 codificado mais
  de uma vez (vem da 0.2.0).

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
