# Cobertura do Rock 5 — limites de disco por pool

Documento da Fase A do Rock 5. Ele é uma especificação de cobertura e de
provas para a implementação que virá depois; não altera os hooks nem promete
que o código atual já faça enforcement de disco.

## Escopo e decisões já aprovadas

Esta cobertura foi conferida contra:

- `.rocket-fuel/FEATURES-PLAN.md`, seção `Rock 5 — Limites por pool: disco`;
- `.rocket-fuel/FEATURES-SAME-PAGE-LOG.md`, decisões das rodadas 2–4 sobre
  disco;
- o Rock 4 em `perl/PVE/MMTools/PoolLimits.pm` e
  `lib/MMPve/Module/Poollimits.pm`, no `HEAD 31c9e2c`;
- as fontes do PVE 9.2 extraídas com `scripts/fetch-pve-debs.sh` (pve-manager
  9.2.25, qemu-server 9.2.14, pve-container 6.1.18, libpve-guest-common-perl
  6.0.6, libpve-storage-perl e libpve-access-control mais recentes em
  2026-11-05).

O Rock 4 fornece o lock, as reservas com TTL, a descoberta de pool, o
`check_write_config` de vCPU/RAM e os preflights de create/clone. A cobertura
abaixo adiciona o contrato de disco sobre essa base. As linhas de código
citadas são as das fontes extraídas, não linhas do repositório deste pacote.

A unidade de quota é o tamanho provisionado, em bytes, dos volumes que a
configuração atual do guest referencia. Há dois limites independentes:

- por datastore: soma dos volumes do guest naquele storage;
- total do pool: soma dos datastores do guest.

O alvo de uma reserva é sempre o valor absoluto que a configuração terá depois
da operação, por datastore e total. Não é o delta da chamada. O uso efetivo do
guest durante o TTL é o máximo entre a configuração observada e a reserva viva.
Uma reserva só é criada quando o guest pertence a um pool com o limite
correspondente ligado; sem pool ou com o módulo deliberadamente desligado não
há enforcement.

Em qualquer preflight, o check deve acontecer sob o lock do pool e antes da
primeira alocação, clone, importação, cópia ou mutação persistente. Se a
configuração do pool estiver inválida/ilegível, os pools que tinham limite na
última configuração válida recusam aumentos; não se trata a falha como um
desligamento. `modules.poollimits = 0` em uma configuração válida é o único
desligamento intencional.

### Decisão de arquitetura (revisão do Visionary)

A Fase A propôs um preflight de API para cada operação. A revisão aprovou a
cobertura com uma mudança: para um guest **já pertencente** a um pool com
limite de disco, o ponto de checagem antes do primeiro efeito é a camada de
storage em `PVE/Storage.pm` — `vdisk_alloc`, `vdisk_clone`, `volume_resize`
(só do volume atual do guest) e `volume_import` (só para volid já
referenciado, ver abaixo). Essas funções recebem vmid, storage e tamanho antes
de o volume existir ou crescer, e todas as cadeias das tabelas abaixo
(adicionar, importar, `import-from`, resize, mover, cloud-init, EFI, TPM)
passam por elas. Assim um único ponto cobre CLI, API e caminhos internos, sem
uma âncora por operação em `PVE/API2/Qemu.pm` e `PVE/API2/LXC.pm`.

Nas tabelas, a coluna de check descreve onde o PVE já tem a informação; a
implementação checa no hook de storage alcançado por aquela cadeia. O preflight
de API fica só na **entrada no pool**: create, clone e restore com `--pool`, e
restore sobre um guest que já está num pool com limite. `add_vm_to_pool` e
`update_pool` checam disco como defesa final.

Regras de contexto no hook de storage:

- volume cujo volid já está referenciado na config atual do guest não é
  aumento (replication e migração do mesmo volume para o mesmo storage);
- fleecing (`-fleece-`) e vmstate (`-state-`) nunca contam;
- o temporário da importação OVA conta só durante o TTL da reserva;
- `pvesm alloc --vmid` passa pelo hook de `vdisk_alloc` no momento da
  alocação, mas continua fora da promessa depois do TTL.

Limite conhecido: `volume_import` não recebe o tamanho antes do stream. Uma
migração que muda o storage do volume (volid novo no destino, por storage
mapping) não tem ponto de checagem antes do efeito e pode exceder um limite
**por datastore**. O total do pool não muda numa migração dentro do cluster.
Fica registrado como limite conhecido; a migração com NBD
(`vm_migrate_alloc_nbd_disks`) usa `vdisk_alloc` com tamanho conhecido e é
coberta.

### Como ler a tabela

`PRE` significa que existe um ponto proposto antes do primeiro efeito e a
linha deve virar um teste do Rock 7. `BLOCKED` significa que o PVE observado
não fornece um ponto suficientemente informado antes do efeito; não é
permitido preencher a lacuna com um check posterior em `write_config`.

Em todas as linhas, o ponto de API deve passar ao núcleo: `vmid`, pool
explícito ou inferido, mapa de storages e tamanho-alvo em bytes. O hook de
storage continua obrigatório como defesa para um guest já pertencente ao pool,
mas não substitui o preflight. O hook não pode contar uma alocação segura só
porque recebeu um `vmid`: ele precisa do contexto do chamador.

## QEMU

| Operação | Cadeia upstream exata | Check antes do primeiro efeito; como conhece vmid/pool/storage/tamanho | Alvo da reserva | Conta ou isenção | Teste executável no lab Rock 7 |
|---|---|---|---|---|---|
| **Adicionar disco — `qm set` e API update** | CLI `qm set` é mapeado em `qemu-server/usr/share/perl5/PVE/CLI/qm.pm:1358-1371` para `PVE::API2::Qemu::update_vm_api` (`Qemu.pm:2111-2128`). A atualização chama `create_disks` (`API2/Qemu.pm:462-475,532-702`); disco novo chega a `PVE::Storage::vdisk_alloc` (`API2/Qemu.pm:688-691`). | **PRE:** no início do update, depois de carregar a config atual e antes do worker/create_disks (`API2/Qemu.pm:2250-2298`), montar a config futura apenas em memória. `vmid` é o parâmetro; pool é a membership atual; storage e `size` vêm de cada drive novo e do default storage resolvido pelo próprio `create_disks`. | Config atual + cada disco que ficará referenciado, agrupados por storage; total é a soma. | **Conta.** É a alocação normal que o guest vai referenciar. O `vdisk_alloc` (`Storage.pm:1157-1190`) repete a defesa para vmid já no pool. | Preparar guest no pool com limite abaixo de `disco atual + novo`. Executar `qm set VMID --scsi1 STORAGE:...`; exigir erro antes de `vdisk_alloc`, lista de volumes igual e digest/config byte a byte igual. Repetir via API `PUT .../config`. Fazer um caso permitido e confirmar o volume e a config final.
| **Importar disco — `qm disk import`** | `qm disk import` é alias de `importdisk` (`CLI/qm.pm:1430-1444`); o método recebe source/storage/vmid em `CLI/qm.pm:613-700` e chama `PVE::QemuServer::ImportDisk::do_import` (`ImportDisk.pm:19-42`). O primeiro efeito é `vdisk_alloc` (`ImportDisk.pm:35-42`); a entrada `unusedN` é escrita depois (`ImportDisk.pm:46-79`). | **PRE:** no método `importdisk`, após obter `vmid`, storage e tamanho do source (`CLI/qm.pm:656-678`) e antes de `do_import`. A membership vem da config/pool do guest; o tamanho vem de `file_size_info`/source e é convertido para a unidade de `vdisk_alloc`. | Config atual + o volume importado no storage destino, ainda que o PVE o anexe como `unusedN`. | **Conta.** A decisão aprovada trata importação como alocação que o guest referencia ou passa a poder referenciar; `unusedN` conta na contabilidade. | Com guest limitado e headroom menor que o source, importar uma imagem para o storage destino deve falhar antes da criação. Verificar ausência do volume destino, nenhum novo `unusedN` e config/digest inalterados. Repetir com limite suficiente e `qm rescan` para confirmar a semântica de `unusedN`.
| **Importar com `import-from` — arquivo externo ou volume PVE** | `qm set`/API update segue `API2/Qemu.pm:2111-2128,462-475`. O branch `import-from` está em `API2/Qemu.pm:541-645`: volume PVE pode passar por `clone_disk` (`QemuServer.pm:7889-7997`) e source externo por `ImportDisk::do_import`. A cópia PVE usa `PVE::Storage::vdisk_clone` (`QemuServer.pm:7921-7924`); a importação externa usa `vdisk_alloc` (`ImportDisk.pm:35-42`). | **PRE:** o mesmo preflight do update, mas resolver o tamanho do source antes de chamar o branch (`API2/Qemu.pm:541-650`). Para volume PVE, consultar `volume_size_info`; para arquivo, obter o tamanho como o importador. O destino é conhecido no drive novo; `vmid` e pool vêm do update. | Config atual + tamanho-alvo do drive no storage destino. Se o source e o destino forem o mesmo volume lógico, contar uma vez na config final. | **Conta.** Tanto clone quanto import resultam em volume que o guest referencia. Artefatos temporários não podem ser confundidos com esse volume final. | Usar `import-from` externo e PVE-managed contra um guest no limite. A recusa deve ocorrer antes de `vdisk_clone`/`vdisk_alloc`; o storage não pode ganhar volume e a config deve permanecer idêntica. Em caso aceito, conferir o drive final e a contagem por storage.
| **Resize — `qm resize`** | CLI `qm resize` mapeia para `resize_vm` (`CLI/qm.pm:1430-1444`). API registra o método em `API2/Qemu.pm:6014-6150`; carrega config e calcula o novo tamanho (`:6055-6126`), chama `PVE::QemuServer::Blockdev::resize` (`:6134-6136`), que chama `PVE::Storage::volume_resize` (`Blockdev.pm:728-735`), e só depois grava (`API2/Qemu.pm:6138-6142`). | **PRE:** depois do cálculo de `newsize` e antes de `Blockdev::resize` (`API2/Qemu.pm:6108-6136`). `vmid`, disk, storage e tamanho antigo vêm da config/drive; pool vem da membership atual. O hook `volume_resize` é a defesa caso outra API alcance o storage sem o preflight. | Config atual com o volume no mesmo storage e `size = newsize`; o alvo do guest é recalculado, não `old + request` cegamente. | **Conta somente aumento do volume atual.** Reduções são aceitas. Chamada com `$snap` ou volume não atual não altera a quota; o hook deve preservar o contexto de snapshot. | Configurar pouco headroom e executar `qm resize VMID DISK +SIZE`; exigir falha antes de resize, tamanho físico/config inalterados. Executar resize para valor menor e aceitar. Executar resize do snapshot com `$snap` e provar que a quota do guest não muda.
| **Mover disco — `qm disk move`** | CLI é alias de `move_vm_disk` (`CLI/qm.pm:1439-1440`). API e validações estão em `API2/Qemu.pm:4809-5053`; source/target são resolvidos antes do copy (`:4918-4950`), a cópia chama `QemuServer::clone_disk` (`:5001-5011`) e a config é atualizada depois (`:5012-5023`). `clone_disk` usa `vdisk_clone` no linked ou `vdisk_alloc` no full (`QemuServer.pm:7921-7965`). | **PRE:** dentro da fase de checks, antes de `clone_disk` (`API2/Qemu.pm:4918-5001`). `vmid` e drive vêm da config; source storage é o volid atual; target storage é o parâmetro; tamanho é o `size` atual do drive/storage. | Por storage: manter o source durante a cópia e acrescentar o destino; no total, contar source + destino enquanto a cópia existir. Depois que a config final e a limpeza forem confirmadas, a reconciliação reduz o source. | **Conta no destino e conta transitoriamente nos dois no total.** Não aceitar que a quota seja verificada só depois da troca da config. | Com headroom menor que o volume no storage destino, executar `qm disk move`; exigir falha antes de `clone_disk`, sem volume novo no destino e sem mudança na config/source. Em caso permitido, confirmar a janela de dupla contagem e a limpeza do source conforme `--delete`.
| **Criar VM com discos, com ou sem `--pool`** | `qm create` é encaminhado pela CLI (`CLI/qm.pm:1358-1371`) ao create da API; `PVE::API2::Qemu` extrai `vmid`, `pool`, archive e discos (`API2/Qemu.pm:1191-1417`) e chama `create_disks` (`:1531-1545`), que chega aos branches de `vdisk_alloc` (`:659-702`). | **PRE:** no endpoint de create, depois de normalizar todos os parâmetros e antes de `create_and_lock_config`/qualquer `create_disks` (`API2/Qemu.pm:1298-1417`). Com `--pool`, o pool é o parâmetro e o alvo é toda a config solicitada; sem `--pool`, não há pool de destino. | Soma dos discos solicitados por storage e total. Para create sem pool, não criar reserva. | **Conta** cada disk que ficará na config. O create também pode criar EFI/TPM/cloud-init, cobertos nas linhas seguintes. | Fazer create com `--pool` e uma lista de discos que excede por storage/total; exigir ausência do VMID/config e dos volumes. Repetir sem `--pool` com o mesmo storage e provar que não há enforcement por pool. Fazer um create permitido com cada combinação de `vcpus`/RAM já coberta no Rock 4.
| **Clone full, com ou sem `--pool`** | CLI/API clone está em `API2/Qemu.pm:4382-4807`; o full clone chama `QemuServer::clone_disk` (`:4715-4723`). `clone_disk` calcula tamanho e chama `PVE::Storage::vdisk_alloc` (`QemuServer.pm:7935-7965`), copia e ativa (`:7970-7985`). | **PRE:** após carregar source config, resolver todos os discos e o `pool` do novo VMID, mas antes do primeiro `clone_disk` (`API2/Qemu.pm:4501-4563`). O source fornece tamanhos; `--pool`, quando presente, fornece o pool alvo; storage override fornece o destino. | Config futura completa do novo guest por storage; total é a soma. O guest source não é somado ao alvo, exceto pela utilização já existente do pool. | **Conta.** Full clone cria volumes novos que o novo guest referencia. Sem `--pool`, não há quota de pool para o novo guest. | Clonar full de um guest para pool com limite insuficiente; exigir falha antes do primeiro `vdisk_alloc`, nenhum novo VMID/volume e source/config intactos. Testar com `--storage` que o limite por datastore é o destino real.
| **Clone linked, com ou sem `--pool`** | Mesmo endpoint/CLI do clone (`API2/Qemu.pm:4382-4807`), mas o branch linked chama `PVE::Storage::vdisk_clone` (`QemuServer.pm:7921-7924`) dentro de `clone_disk` (`:7889-7997`). | **PRE:** o mesmo preflight pré-clone, incluindo o storage de cada base/volume e o pool futuro, antes de qualquer `vdisk_clone`. | Tamanho provisionado dos volumes que ficarão referenciados pelo novo guest, por storage; total da config futura. | **Conta.** Linked clone ainda cria um volume/base que o guest referencia; não é uma isenção por ser copy-on-write. | Repetir o teste de clone excedente com `--full 0`/linked; exigir nenhum novo volume/base e nenhum novo VMID depois da recusa. Testar um caso aceito e conferir que a base e a config são as esperadas.
| **Restore `qmrestore`/API com archive, com ou sem `--pool`, inclusive sobre guest existente** | CLI `qmrestore` é o caminho de restore em `CLI/qm.pm:1358-1408`; create/restore da API extrai archive e config (`API2/Qemu.pm:1191-1387`), cria/fecha a config inicial (`:1414-1417`), executa o worker de restore (`:1420-1477`) e aloca os devices em `QemuServer.pm:6543-6580`, com `vdisk_alloc` em `:6572-6573`. | **PRE:** recuperar a configuração do backup exatamente como o PVE (`API2/Qemu.pm:1298-1312` e o parser de restore) e reservar antes de `create_and_lock_config` e antes de `restore_*_archive`. Se o VMID já existe, excluir a configuração atual do cálculo de destino e reservar a config que substituirá o guest; o pool é o `--pool` explícito ou a membership já existente. | Config do backup, com os storages remapeados pelos parâmetros do restore; total da config restaurada. Para overwrite, é substituição lógica do guest, não soma permanente da config velha e nova, mas falha do preflight deve deixar a velha intacta. | **Conta** root disks, disks, cloud-init, EFI/TPM presentes no backup quando forem volumes finais referenciados. `unusedN` do backup segue a regra geral e conta se restaurado na config. | Criar guest existente no pool com limite baixo, guardar config/inventário, executar `qmrestore` com e sem `--pool`; exigir recusa antes de qualquer volume/configuração nova e config velha byte a byte igual. Testar remapeamento para outro storage e falha em um datastore intermediário.
| **Cloud-init drive** | No create/update, `create_disks` identifica cloud-init (`API2/Qemu.pm:495-531`) e aloca com `vdisk_alloc` em `:525`; a atualização do drive passa por `vmconfig_update_cloudinit_drive` (`QemuServer.pm:5167-5195`) e `Cloudinit::commit_cloudinit_disk` (`Cloudinit.pm:21-90`), com alocação em `:50-63`. | **PRE:** no preflight do create/update, reconhecer `drive_is_cloudinit` antes de `create_disks`/`commit_cloudinit_disk`; `vmid` e pool vêm do guest, storage do drive e tamanho do constante de 4 MiB/size retornado pelo storage. Se o drive já existe e apenas o conteúdo é regenerado, não reservar de novo. | Config atual + cloud-init final no storage escolhido, usando o tamanho provisionado real da config/storage. | **Conta quando cria ou passa a ser referenciado.** Apesar de `media=cdrom`, cloud-init é um volume gerenciado criado para o guest; não é ISO/CD-ROM isento. | Recusar `qm create --pool ... --ide2 STORAGE:cloudinit` quando o limite exceder; conferir ausência de volume. Repetir `qm cloudinit update` com drive ausente em guest do pool e verificar a mesma proteção. Atualização de conteúdo com drive já existente não deve aumentar quota.
| **EFI disk** | `create_disks` chama `PVE::QemuServer::OVMF::create_efidisk` (`API2/Qemu.pm:659-674`); o helper chama `PVE::Storage::vdisk_alloc` (`OVMF.pm:190-208`, alocação em `:197`). | **PRE:** preflight de create/update deve incluir `efidisk0` antes do branch OVMF. `vmid`/pool vêm da config alvo; storage e tamanho vêm do parâmetro EFI, formato e tamanho efetivo retornado pelo storage. | Config atual + `efidisk0` no datastore selecionado; total inclui o EFI. | **Conta.** É um volume que permanece ligado à configuração. | Create/update com `efidisk0` excedente deve falhar antes do `OVMF::create_efidisk`, sem volume e sem config. Caso aceito deve registrar o tamanho real, inclusive quando a granularidade do storage arredondar a alocação.
| **TPM state disk** | `create_disks` entra no branch `tpmstate0` (`API2/Qemu.pm:675-687`) e chama `PVE::Storage::vdisk_alloc` (`:682-684`). | **PRE:** mesmo preflight de create/update, antes do branch TPM. O tamanho-alvo é `TPMSTATE_DISK_SIZE` convertido para KB e depois o tamanho efetivo informado pelo storage; vmid/pool/storage são conhecidos na config alvo. | Config atual + `tpmstate0` no storage selecionado; total inclui o estado TPM. | **Conta.** É provisionado e ligado ao guest. | Recusar create/update com TPM excedente antes da alocação; verificar nenhum `tpmstate0`, nenhum volume e config original preservada. Testar arredondamento do storage.
| **Rollback de snapshot** | CLI/API chama `PVE::API2::Qemu::rollback` (`API2/Qemu.pm:6445-6510`), que executa `PVE::QemuConfig->snapshot_rollback` (`:6495-6498`). O caminho interno de snapshot pode fazer `PVE::Storage::volume_resize` com `$snap` (`QemuServer/Snapshot.pm:101-116`). | **PRE:** o contrato é o hook de `write_config` do Rock 4, restrito a `PVE::QemuConfig`, calculando a config final antes de gravá-la. Comparar config atual com a config do snapshot: volumes já em `unusedN` já contam; um volume de snapshot reanexado que não estava na config atual gera aumento e deve ser reservado/recusado antes da gravação. O resize com `$snap` é passado como contexto não atual. | Config final após rollback, por storage; não somar o conteúdo de `snapshots` como uso permanente. | **Não aumenta por si só.** Volumes não encolhem por existir snapshot, e volume destruído não volta. Reanexação que realmente aumentaria a config passa pelo cálculo de `write_config`; resize de snapshot não conta. | Criar snapshot, remover um disk da config mantendo-o como `unusedN`, rollback e provar que `unusedN` já contado não aumenta. Fazer um caso em que o snapshot reanexa volume não contado: exigir recusa antes de `write_config`, sem alteração persistente. Fazer resize interno de snapshot e confirmar quota igual.
| **Migração interna para destino — alocação NBD** | O destino calcula discos em `PVE::QemuServer::vm_migrate_alloc_nbd_disks` (`QemuServer.pm:5230-5261`) e chama `vdisk_alloc` em `:5252`; o handler de migração/mtunnel deve recebê-lo antes da alocação. | **PRE:** adicionar preflight no handler de migração do destino, antes de chamar `vm_migrate_alloc_nbd_disks`; o túnel já conhece `vmid`, storagemap/target storage e `drive->{size}`. Se o caminho de migração for apenas replication ou copy temporário que não ficará na config final, usar contexto de réplica e não contar. | Se a migração resulta no guest destino, config futura por storage e total; durante a cópia, reservar o destino e manter a origem conforme a política de cópia. | **Conta para migração que cria o volume final do guest.** Cópias de replication e artefatos temporários não contam, desde que não sejam ligados à config e sejam removidos. | Tentar migração para storage com headroom insuficiente: nenhum destino novo e config source/destination inalteradas após recusa. Separar um job de replication/cópia temporária e provar limpeza e ausência de impacto no uso lógico.

## LXC

| Operação | Cadeia upstream exata | Check antes do primeiro efeito; como conhece vmid/pool/storage/tamanho | Alvo da reserva | Conta ou isenção | Teste executável no lab Rock 7 |
|---|---|---|---|---|---|
| **Adicionar rootfs/mpN — `pct set` e API update** | `pct set` é registrado em `pve-container/usr/share/perl5/PVE/CLI/pct.pm:1096-1115` e chega a `PVE::API2::LXC::Config::update_vm` (`API2/LXC/Config.pm:111-272`). A aplicação de pending chama `PVE::LXC::Config::apply_pending_mountpoint` (`LXC/Config.pm:1879-1905`), `PVE::LXC::create_disks` (`LXC/Config.pm:1884-1888,2649-2680`) e `alloc_disk`, com `vdisk_alloc` em `LXC.pm:2617-2630`. | **PRE:** no update da API, interpretar pending mountpoints e montar a config futura antes de aplicar pending/create_disks. `vmid` vem do path; pool da membership; `storage` e `size` vêm de `rootfs`/`mpN`. `classify_mountpoint` (`LXC/Config.pm:1927-1934`) precisa ser aplicado antes de reservar. | Config atual + rootfs/mpN volumes novos por storage; total soma todos. | **Conta** `rootfs` e `mpN` do tipo `volume`. Bind/device/caminho absoluto são isentos pela classificação. | Com CT no pool e limite menor que `rootfs`/`mpN`, executar `pct set CT --mp0 STORAGE:...`; exigir recusa antes de `create_disks`, sem volume e com config/pending original inalterada. Repetir via API e testar bind/device sem alocação.
| **Resize — `pct resize`** | CLI é mapeado em `CLI/pct.pm:1096-1115`; API registra resize em `API2/LXC.pm:2323-2494`, carrega e calcula `newsize` (`:2363-2423`), chama `PVE::Storage::volume_resize` (`:2437-2439`) e grava a config (`:2441-2444`). | **PRE:** depois de resolver `volid`, size atual e `newsize`, antes de `volume_resize` (`API2/LXC.pm:2400-2439`). `vmid`, storage e owner vêm de `parse_volname`/`parse_volume_id`; pool da membership. | Config atual com o mountpoint no novo tamanho, por storage e total. | **Conta aumentos do volume atual.** Não contar volume de snapshot/interno que não é atual; redução é permitida. | Exceder o limite com `pct resize`; exigir falha antes do resize e config/tamanho/inventário iguais. Fazer redução aceita e um resize de volume não atual para provar que não altera quota.
| **Mover volume — `pct move-volume`** | CLI é mapeado em `CLI/pct.pm:1130-1140`; API resolve source/target em `API2/LXC.pm:2496-2643` e chama `PVE::LXC::copy_volume` (`:2657-2668`). `copy_volume` aloca antes de unshare (`LXC.pm:3391-3412`) via `alloc_disk`/`vdisk_alloc` (`LXC.pm:2617-2630`), atualiza e grava a config depois (`API2/LXC.pm:2678-2693`). | **PRE:** dentro de `move_to_storage_checks`, antes de `copy_volume` (`API2/LXC.pm:2611-2666`). `vmid`, mountpoint e tamanho atual vêm da config; target storage é parâmetro; pool é membership atual. | Durante a cópia, source + destino no total; por storage, source continua e destino é acrescentado. Após config final/cleanup, reconciliar source. | **Conta destino e dupla contagem transitória do total.** `unusedN` não pode ser movido por este caminho (`API2/LXC.pm:2626-2629`). | Exceder limite no target com `pct move-volume`; exigir nenhum `copy_volume`, nenhum volume target e config source sem lock residual/mutação. Caso permitido deve terminar com config target correta e política de limpeza observável.
| **Criar CT com rootfs/mpN, com ou sem `--pool`** | `pct create` é mapeado em `CLI/pct.pm:1096-1115`; API create/restore processa `vmid`, `pool`, storage e parâmetros (`API2/LXC.pm:140-430`) e chama `PVE::LXC::create_disks` (`:541-544` no caminho de create, também no restore). A alocação está em `LXC.pm:2603-2635`. | **PRE:** após normalizar `rootfs`, `mpN`, storage default e pool, antes de `create_disks` (`API2/LXC.pm:541-544`). Sem `--pool`, não há alvo de quota; com `--pool`, a config futura inteira já está disponível. | Soma dos volumes `rootfs/mpN` da config futura, por storage e total. | **Conta** volumes; bind mounts/devices/caminhos absolutos são excluídos e não chegam a `alloc_disk`. | Exceder com `pct create --pool`; exigir ausência do CT e dos volumes. Repetir sem pool e provar ausência de enforcement. Testar rootfs em storage diferente do mpN para por-storage e total.
| **Clone full, com ou sem `--pool`** | CLI/API clone é registrado em `CLI/pct.pm:1130-1140` e `API2/LXC.pm:1905-2320`; full clone chama `PVE::LXC::copy_volume` (`:2222-2230`), que aloca por `LXC.pm:3391-3412`. | **PRE:** depois de carregar e interpretar todos os mountpoints source e o pool do novo CT, antes do primeiro `copy_volume` (`API2/LXC.pm:2052-2127,2222`). Source fornece sizes; target storage/`--pool` vêm dos parâmetros. | Config futura do clone por storage; total da config futura. Source não é somado novamente ao alvo. | **Conta.** Cada rootfs/mpN copiado fica ligado ao novo CT. Sem pool não há quota alvo. | Clone full excedente com e sem storage override; exigir nenhum CT/volume novo e source intacto. Caso permitido deve criar a configuração com tamanhos esperados.
| **Clone linked, com ou sem `--pool`** | Mesmo endpoint (`API2/LXC.pm:1905-2320`), mas linked chama `PVE::Storage::vdisk_clone` em `:2231-2235` para cada volume. | **PRE:** mesmo preflight antes de `vdisk_clone`, conhecendo mountpoints, source volume, target storage e pool futuro. | Tamanho provisionado dos volumes ligados ao novo CT, por storage e total. | **Conta.** Copy-on-write ainda gera volume referenciado. | Repetir clone linked excedente; exigir ausência de bases/volumes novos e de CT após recusa. Testar caso aceito com rootfs e mpN em datastores distintos.
| **Restore `pct restore`/API archive, com ou sem `--pool`, inclusive sobre CT existente** | Restore passa por `CLI/pct.pm:1096-1115` e `PVE::API2::LXC` create/restore (`API2/LXC.pm:140-430`). A config do archive é recuperada (`:441-505`), volumes são normalizados e `create_disks` é chamado em `:482-544`; a alocação termina em `LXC.pm:2617-2630`. | **PRE:** recuperar `orig_conf`/`orig_mp_param` no mesmo ponto do PVE e reservar antes de `create_disks` (`API2/LXC.pm:441-544`). Pool é `--pool` ou membership do CT existente; storages e sizes vêm da config recuperada. Para overwrite, reservar a config final substituta e não destruir a config velha antes da aprovação. | Config do archive, após storage mapping; por storage e total. Bind/device/absolute path são tratados pela classificação e não viram alocação. | **Conta** rootfs/mpN volume e `unusedN` que permaneça na config restaurada. | Guardar CT existente no pool, executar restore excedente com e sem `--pool`; exigir config antiga e inventário iguais e nenhum volume novo. Testar archive com bind/device e archive que remapeia storage.
| **Snapshot rollback** | CLI/API rollback é `PVE::API2::LXC::Snapshot::rollback` (`API2/LXC/Snapshot.pm:267-329`), que chama `PVE::LXC::Config->snapshot_rollback` (`:315-317`). A gravação da configuração final deve passar pelo `write_config` do Rock 4. | **PRE:** calcular a config final do rollback e usar o hook `write_config` antes da gravação. `vmid` e snapshot vêm da API; storage/tamanho vêm de `rootfs/mpN/unusedN` da config final. Snapshots aninhados não entram na soma. | Config final por storage e total; apenas deltas de volumes atuais não contados devem gerar reserva. | **Não aumenta por si só.** Reanexar um volume que já era `unusedN` não aumenta porque `unusedN` conta; reanexar volume não contado exige recusa no write hook. | Criar/remover mountpoint, manter `unusedN`, fazer rollback e comparar quota. Testar reanexação não contada e exigir config inalterada após a recusa; provar que bind/device não contam.
| **Migração/cópia de volume via túnel de storage** | `PVE::StorageTunnel::handle_disk_import` recebe storage/format/volname e `state->{vmid}` (`libpve-guest-common-perl/usr/share/perl5/PVE/StorageTunnel.pm:205-217`) e inicia `volume_import_start`; o resultado pode chegar a `PVE::Storage::volume_import` (`libpve-storage-perl/usr/share/perl5/PVE/Storage.pm:2107-2124`). | **Mesmo volid: não é aumento** (replication, migração para o mesmo storage). **Volid novo (storage mapping): BLOCKED**, porque `volume_import` não conhece o tamanho antes do stream; fica como limite conhecido por datastore (o total do pool não muda numa migração). | Se for o volume final do CT, config futura por storage e total. Se for apenas transporte temporário, deve ser contexto de cópia e ser removido antes de qualquer config. | Volume final **conta**; transporte temporário só é isento com cleanup garantido. | Provar que replication/migração do mesmo volid em pool no limite não é recusada. O caso com storage mapping é declarado não coberto no resumo do lab.

## Alocações e caminhos que não podem ser esquecidos

Esta é a matriz do chamador de storage. Ela evita que o hook genérico conte um
artefato físico que não faz parte da quota lógica ou deixe de contar um volume
que o guest realmente vai referenciar.

| Chamador observado | Regra | Tratamento no hook |
|---|---|---|
| `PVE::Storage::vdisk_alloc` (`libpve-storage-perl/usr/share/perl5/PVE/Storage.pm:1157-1190`) | API preflight é a autoridade para add/import/clone/restore/move/cloud-init/EFI/TPM. | Defesa contextual: para vmid já em pool, recusar aumento se a reserva não cobrir o alvo. Inferir storage/size pelo argumento e owner pelo volid; não substituir o preflight.
| `PVE::Storage::vdisk_clone` (`Storage.pm:1085-1105`) | Clone full/linked cria o volume que o novo guest referencia. | Deve carregar contexto da operação ou ser precedido pelo preflight de clone; conta para guest alvo.
| `PVE::Storage::volume_resize` (`Storage.pm:395-410`) | Resize do volume atual aumenta provisionado; resize com `$snap` é interno e não é quota do guest atual. | Só contar aumento quando o volid pertence à config atual do guest. Preservar `$snap` e ignorar volume não atual.
| `PVE::Storage::volume_import` (`Storage.pm:2107-2124`) | Importação final ligada ao guest conta; import temporário de transporte não conta se for limpo e não entrar na config. | Volid já referenciado na config do guest: não conta (replication, migração do mesmo volume). Volid novo: sem tamanho antes do stream, BLOCKED (limite conhecido por datastore).
| `PVE::QemuServer::QemuConfig` vmstate (`QemuConfig.pm:251-260`) | Cria um state file para suspender a VM; o plano exclui `vmstate`. | Isenção explícita `vmstate`; teste deve provar que a alocação e sua limpeza não mudam uso lógico nem deixam entrada na config de disks.
| Fleecing de backup (`qemu-server/usr/share/perl5/PVE/VZDump/QemuServer.pm:594-610`) | `fleece-volid` é cópia temporária de backup, não volume referenciado pela config. | Isenção explícita. O backup deve limpar cada `fleece-volid` em sucesso e falha; nunca somar ao guest. O teste falha se sobrar volume persistente invisível.
| Restore VMA (`qemu-server/usr/share/perl5/PVE/QemuServer.pm:6543-6580`) | `restore_allocate_devices` cria os volumes finais do restore. | Conta pelo mapa recuperado antes da chamada; o tamanho vem de `d->{size}`, o storage de `d->{storeid}` e o vmid do restore.
| `PVE::GuestImport` OVA (`libpve-storage-perl/usr/share/perl5/PVE/GuestImport.pm:11-91`) | Pode reservar um volume temporário de 1 MiB (`:74-78`) e renomeá-lo (`:80-83`) antes de entregar o resultado. | O alvo final é contado pelo preflight de import/restore; o 1 MiB temporário é isento somente com cleanup comprovado em sucesso e erro. Se a branch puder ficar ligada ao guest, tratá-la como volume final.
| Replication | Cópias de replication são excluídas da quota lógica aprovada; não são configuração atual do guest. | Contexto de replication explícito, sem alterar o contador. A prova fica **não provada** quando o lab não tiver storage replicável, e não pode ser apresentada como cobertura concluída.
| `pvesm alloc --vmid` solto (`libpve-storage-perl/usr/share/perl5/PVE/API2/Storage/Content.pm:256-272`) | O plano retirou este comando da promessa: ele pode criar um volume para o vmid sem ainda estar na config. | **Fora da promessa.** O hook de `vdisk_alloc` checa a alocação no momento dela (reserva com TTL), mas depois do TTL um volume que nunca entrou na config deixa de contar. Ele só passa a contar quando entrar na config, por exemplo como `unusedN` via `qm rescan`.

## Contabilidade no `write_config`

O patch de Rock 4 atinge `PVE::AbstractConfig::write_config` conforme
`lib/MMPve/Module/Poollimits.pm:266-300`, mas a versão atual só verifica
vCPU/RAM em `PVE::MMTools::PoolLimits::check_write_config` (`PoolLimits.pm:417-451`).
O Rock 5 deve ampliar esse check sem alterar o contrato de escrita nem atingir
classes que não são guests.

O cálculo proposto para QEMU e LXC é:

1. aceitar somente `PVE::QemuConfig` e `PVE::LXC::Config` e obter o `vmid` da
   própria chamada/configuração;
2. comparar a configuração atual com a nova, incluindo pending quando esta
   estiver prestes a ser aplicada;
3. coletar volumes atuais com os parsers do PVE, não por varredura física do
   storage. Em QEMU, as chaves de disco, `efidisk0`, `tpmstate0` e `unusedN`
   são analisadas; em LXC, `rootfs`, `mpN` e `unusedN` passam por
   `parse_volume`/`classify_mountpoint`;
4. para cada volid gerenciado, usar `size=` explícito da config. Se não houver
   `size=`, consultar `PVE::Storage::volume_size_info` (`Storage.pm:380-391`)
   para obter o tamanho provisionado. Tamanho desconhecido é falha fechada
   para um aumento;
5. agrupar por datastore, deduplicar o mesmo volid e somar os storages no
   total. A comparação usa a configuração final; não somar a árvore
   `snapshots` como se fosse a configuração atual;
6. recusar o aumento antes de `cfs_write_file`/gravação e manter a reserva até
   a configuração atingir o alvo ou o TTL expirar.

### Inclusões e exclusões

- `unusedN` **conta**: o volume está provisionado para o guest mesmo quando não
  está conectado a um bus/mountpoint. Isto também torna seguro reanexar um
  `unusedN` durante rollback sem aumentar a quota.
- Snapshots **não contam** na soma permanente. O rollback compara a config
  final: se reanexar um volume que não estava nem na config atual nem em
  `unusedN`, o aumento é recusado pelo hook antes de gravar.
- QEMU `vmstate` **não conta**; é estado de execução/suspensão, não um disk
  provisionado da config lógica para esta quota.
- QEMU CD-ROM e ISO **não contam** quando são mídia `cdrom`/`iso` ou caminhos
  externos. O drive cloud-init é a exceção deliberada: embora use
  `media=cdrom`, é um volume gerenciado criado e referenciado pelo guest, então
  conta.
- LXC bind mounts, devices e caminhos absolutos **não contam**:
  `PVE::LXC::Config::classify_mountpoint` retorna `bind` para `/...`, `device`
  para `/dev/...` e `volume` somente para volids (`LXC/Config.pm:1927-1934`).
- `unusedN` com caminho absoluto não vira volume de storage; não conta como
  datastore, mas continua sendo preservado na config.
- Fleecing, backup temporário e replication **não contam** somente quando o
  contexto e a limpeza forem demonstrados; um volume que termina referenciado
  pela config deixa de ser exceção.
- Volumes em caminhos absolutos, ISO/CD-ROM externo ou devices não devem ser
  “descobertos” por `pvesm list` para inflar a quota: a fonte de verdade é a
  configuração lógica do guest e seu `size=`/storage.

## Protocolo de prova comum a cada linha

Cada linha da tabela deve virar um cenário executável no lab Rock 7, com a
mesma sequência mínima:

1. criar ou selecionar um guest e pool, colocar um limite por datastore e/ou
   total abaixo do alvo da operação, e registrar o digest/bytes da config e a
   lista de volumes do storage;
2. executar a forma CLI indicada e repetir pelo endpoint API correspondente;
3. esperar o task terminar e exigir uma recusa com pool, recurso, uso, alvo e
   limite, sem senha, token ou dado sensível;
4. reler a config e o inventário: para create/clone/restore não pode existir
   VM/CT ou volume novo; para add/import/resize/move não pode haver volume
   novo, resize, `unusedN` novo ou troca de storage; em todos os casos o
   digest/config original deve permanecer igual;
5. repetir com limite suficiente para provar o caminho aceito e a contagem por
   datastore/total;
6. para fleecing, vmstate, backup temporário e replication, provar também
   limpeza em sucesso e falha e ausência no contador lógico;
7. rodar a suíte de cobertura com os módulos reais do PVE, `make test
   test-api`, `check-anchors` e `perl -T`; a cobertura de replication deve ser
   explicitamente marcada como não provada se o lab não tiver storage
   replicável.

Nenhuma operação marcada `BLOCKED` pode ser promovida a cobertura garantida
sem que o Rock 7 demonstre um ponto anterior ao primeiro efeito com `vmid`,
pool, storage e tamanho conhecidos.
