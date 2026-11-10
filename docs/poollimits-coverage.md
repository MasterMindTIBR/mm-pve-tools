# Cobertura do Rock 5 — limites de disco por pool

Cobertura implementada sobre o Rock 4. A quota mede tamanho provisionado, em
bytes, dos volumes que a configuração atual do guest referencia. Há dois
limites independentes: por datastore (`disk_storage`) e total (`disk_total_gib`);
cada um tem seu próprio `enabled`. Disco é sempre contado pelo modo alocado.

O valor reservado é o alvo absoluto do guest, por datastore e total. Chamadas
que ainda não gravaram a configuração acumulam o alvo; a reserva desaparece
quando a configuração chega ao alvo ou quando o TTL expira. Aumento sem tamanho
comprovável em pool limitado falha fechado com a mensagem do Rock 4. Sem pool,
sem limite de disco ou com `modules.poollimits = 0`, o hook retorna antes do
lock e não faz contabilidade.

## Decisão de arquitetura

Para guest já pertencente a pool limitado, o ponto primário antes do efeito é o
storage layer, em `libpve-storage-perl/usr/share/perl5/PVE/Storage.pm`:

- `vdisk_alloc`: conhece `vmid`, storage, nome e tamanho antes de criar o
  volume;
- `vdisk_clone`: conhece `vmid`, volid e storage antes do clone;
- `volume_resize`: conhece o volid e o tamanho novo; só o volume atual do guest
  conta, e resize com snapshot/non-current nunca aumenta a quota;
- `volume_import`: é protegido quando há tamanho disponível; o mesmo volid já
  referenciado não é aumento.

Não há preflight novo por operação em `PVE/API2/Qemu.pm` ou `PVE/API2/LXC.pm`
para add disk, import, import-from, resize, move, cloud-init, EFI ou TPM. Esses
caminhos chegam aos hooks de storage. Preflight de API existe somente para
entrada no pool: create/clone/restore com `--pool`, restore sobre guest já
pertencente a pool limitado, `add_vm_to_pool` e `update_pool`, antes da primeira
alocação. O preflight de restore recupera a configuração do backup pelo mesmo
fluxo do PVE.

Um volid já na configuração atual não é aumento: isso cobre replication e
migração para o mesmo storage. Durante qualquer migração, a configuração atual
tem `lock: migrate`; enquanto esse lock existir, `vdisk_alloc`, `vdisk_clone`,
`volume_import` e o trecho de disco de `write_config` retornam antes do lock da
quota. Portanto NBD, storage tunnel e storage mapping são isentos: a migração
não conta disco duas vezes nem falha fechado por tamanho desconhecido. O efeito
conhecido é que um mapping pode mudar a distribuição por datastore sem uma
verificação de limite por datastore durante a cópia; a configuração final passa
a ser a referência para as operações seguintes.

Fleecing (`-fleece-`) e vmstate (`-state-`) são isentos. O temporário de OVA
fica reservado somente pelo TTL. `pvesm alloc --vmid` passa por `vdisk_alloc`,
mas está fora da promessa após o TTL até o volume entrar na configuração.

## Matriz QEMU

Em todas as linhas abaixo, “Storage hook” significa a chamada
`PVE::MMTools::PoolLimits->check_storage_*` inserida antes da chamada efetiva do
plugin. O hook relê pool/configuração sob o lock, deduplica volids e verifica o
alvo por storage e total.

| Operação | Cadeia upstream exata (arquivo:linha) | Check antes do primeiro efeito; conhecimento disponível | Alvo da reserva | Conta ou isenção | Teste executável no lab Rock 7 |
|---|---|---|---|---|---|
| Add disk — `qm set`/API | `qemu-server/usr/share/perl5/PVE/CLI/qm.pm:1358-1371` → `PVE/API2/Qemu.pm:update_vm_api:2111-2128` → `create_disks:462-475,532-702` → `PVE::Storage::vdisk_alloc:688-691` → `libpve-storage-perl/usr/share/perl5/PVE/Storage.pm:1157-1190` | **Storage hook `vdisk_alloc`** após `parse_vmid`, antes do plugin. O vmid é argumento; o pool vem da membership; storage/nome/tamanho vêm dos argumentos de alocação. | Config atual + cada volume novo no storage destino; total é a soma. | Conta; `unusedN` também conta quando escrito. | Com headroom menor, executar CLI e API; provar recusa antes do plugin, nenhum volid/`unusedN` novo e config inalterada. Repetir permitido. |
| Import disk — `qm disk import` | `CLI/qm.pm:1430-1444,613-700` → `PVE::QemuServer::ImportDisk::do_import:19-42` → `vdisk_alloc:35-42` → `Storage.pm:1157-1190`; `unusedN` em `ImportDisk.pm:46-79` | **Storage hook `vdisk_alloc`**. vmid/storage/tamanho do `source` já estão nos argumentos; a config futura é protegida também por `write_config` quando `unusedN` é gravado. | Alvo por storage da configuração que receberá o volume; total inclui o importado. | Conta. | CLI com source maior que headroom: nenhum volume destino, nenhum `unusedN`, config igual; repetir com limite suficiente. |
| Import-from — arquivo ou volume PVE | `API2/Qemu.pm:541-645` → source PVE `PVE::QemuServer::clone_disk:7889-7997` → `vdisk_clone:7921-7924`; source externo → `ImportDisk::do_import:35-42` → `vdisk_alloc` | **Storage hook** (`vdisk_clone` ou `vdisk_alloc`), sem preflight de operação. O vmid é o destino; storage e tamanho estão no clone/alocação. | Config futura do destino por storage e total. Mesmo volid referenciado é deduplicado. | Conta o volume final; artefato temporário só vale pelo TTL. | Recusar antes de clone/alloc; provar ausência de volume e config igual para source PVE e arquivo. |
| Resize — `qm resize` | `CLI/qm.pm:1430-1444` → `API2/Qemu.pm:6014-6150` → `QemuServer::Blockdev::resize:6134-6136` → `PVE::Storage::volume_resize:728-735` → `Storage.pm:395-410` | **Storage hook `volume_resize`**, depois de adicionar padding e antes do plugin. Owner/vmid vem de `parse_volname`/volid; storage vem do volid; novo tamanho é o argumento. `$snap` exclui snapshot. | Config atual com o volume no novo tamanho; delta somente se o novo tamanho for maior. | Aumento do volume atual conta; redução e snapshot/non-current não contam. | `qm resize` excedente falha antes do resize; redução passa; resize com snapshot não altera quota nem config. |
| Move disk/volume — `qm disk move` | `CLI/qm.pm:1439-1440` → `API2/Qemu.pm:4809-5053` → `QemuServer::clone_disk:7889-7997` → `vdisk_clone`/`vdisk_alloc` → `Storage.pm:1085-1105/1157-1190` | **Storage hook** no clone/alloc. Source, target storage, vmid e tamanho aparecem antes do plugin. A mesma referência não é aumento; volid novo no target é aumento. | Target recebe o volume; durante a cópia o source continua contado. Total pode contar ambos até a config/cleanup. | Conta o destino; não bloqueia a mesma referência. | Com target sem headroom, nenhum target/config novo; caso permitido confirma target e remoção do source conforme `--delete`. |
| Create com discos, com/sem `--pool` | `CLI/qm.pm:1358-1371` → `API2/Qemu.pm:1191-1417` → `create_disks:1531-1545` → branches `vdisk_alloc:659-702` | Com `--pool`, **preflight `check_qemu_create`** em `API2/Qemu.pm` antes de `create_and_lock_config/create_disks`; sem pool não há quota de destino. As alocações também passam no hook. | Config completa solicitada por storage e total; EFI/TPM/cloud-init entram no mesmo alvo. | Conta volumes gerenciados; sem pool é safe exemption por escopo. | Create excedente com `--pool`: nenhum VMID/config/volume. Sem `--pool`: provar ausência de enforcement por pool. |
| Full clone com/sem `--pool` | `CLI/API2/Qemu.pm:4382-4807` → `clone_disk:4715-4723,7889-7997` → `vdisk_alloc:7935-7965` | Com `--pool`, **preflight `check_clone`** antes do primeiro `clone_disk`; sem pool não há alvo. O source fornece tamanhos, storage override e pool fornecem o destino. O hook é a defesa final. | Config futura do novo guest; source não é somado como novo guest. | Conta cada volume novo do clone. | Full clone excedente não cria VM/volume; repetir sem pool e caso aceito. |
| Linked clone com/sem `--pool` | `API2/Qemu.pm:4382-4807` → `clone_disk:7889-7997` → `vdisk_clone:7921-7924` → `Storage.pm:1085-1105` | **Preflight `check_clone`** para entrada no pool; depois defesa `vdisk_clone`. vmid novo, pool, source volid/storage e tamanho são conhecidos. | Volumes ligados ao clone por storage e total. | Conta: CoW ainda cria volume referenciado. | Linked clone excedente falha antes de `vdisk_clone`, sem VM/base nova; caso aceito confere a config final. |
| Restore `qmrestore`/API archive, com/sem `--pool`, inclusive overwrite | `CLI/qm.pm:1358-1408` → `API2/Qemu.pm:1191-1477` → `QemuServer::restore_allocate_devices:6543-6580` → `vdisk_alloc:6572-6573` | **Preflight `check_qemu_create`** lê/mescla a config do backup como o PVE (`PVE::Storage::extract_vzdump_config` + `PVE::QemuServer::restore_merge_config`) antes de `create_and_lock_config/restore`. `--pool` ou membership do guest existente fornece pool; mapping fornece storage/tamanho. | Config restaurada, substituta em overwrite, por storage e total; não soma permanentemente config velha + nova. | Conta disks, cloud-init, EFI, TPM e `unusedN` restaurados. | Archive excedente com e sem `--pool`, inclusive sobre guest existente: nenhum volume novo e config antiga byte a byte igual. |
| Cloud-init drive | `API2/Qemu.pm:495-531` → `vdisk_alloc:525`; update `QemuServer.pm:5167-5195` → `Cloudinit.pm:21-90` → alloc `:50-63` | **Storage hook `vdisk_alloc`**; vmid/pool vêm do guest, storage do drive e tamanho da alocação. Conteúdo regenerado em drive já existente não é aumento. | Config + cloud-init final no storage. | Conta; é a exceção a CD-ROM. | Criar drive acima do limite falha antes do alloc; update de conteúdo existente não aumenta quota. |
| EFI disk | `API2/Qemu.pm:659-674` → `QemuServer/OVMF.pm:190-208` → `vdisk_alloc:197` → `Storage.pm:1157-1190` | **Storage hook `vdisk_alloc`**; `efidisk0`, storage e tamanho estão disponíveis antes do plugin. | Config + EFI por storage e total. | Conta. | Create/update excedente não cria EFI/volume/config; caso aceito registra o tamanho efetivo. |
| TPM state | `API2/Qemu.pm:675-687` → `vdisk_alloc:682-684` → `Storage.pm:1157-1190` | **Storage hook `vdisk_alloc`**; `tpmstate0`, vmid, storage e tamanho constante estão disponíveis. | Config + TPM por storage e total. | Conta. | Recusa antes do alloc, sem `tpmstate0`; testar arredondamento e caso aceito. |
| Snapshot rollback | `API2/Qemu.pm:6445-6510` → `QemuConfig->snapshot_rollback:6495-6498`; resize interno `QemuServer/Snapshot.pm:101-116` | **Hook `write_config`** antes da gravação calcula a config final. Volume já em `unusedN` conta; volume reanexado que não estava na config atual gera aumento e é recusado. Resize com snapshot é ignorado pelo hook. | Config final do rollback, deduplicada por storage/total; `snapshots` não entra como uso permanente. | Snapshot sozinho não conta; reanexação não contada conta/é bloqueada. | Rollback que só reanexa `unusedN` passa sem aumento; rollback que reanexa volid não contado recusa antes do write e mantém config. |
| Migração NBD | `QemuServer.pm:5230-5261` (`vm_migrate_alloc_nbd_disks`) → `vdisk_alloc:5252` → `Storage.pm:1157-1190` | **Storage hook `vdisk_alloc`** vê `lock: migrate` na configuração atual e retorna antes do lock da quota; não há preflight específico de migração. | Nenhum alvo de quota durante a migração; a config final volta a ser a referência. | **Isento durante `lock: migrate`** para não contar duas vezes o mesmo disco. | Com o pool já no limite, migrar por NBD deve concluir; provar que não há recusa por quota e que a config final é válida. |

## Matriz LXC

| Operação | Cadeia upstream exata (arquivo:linha) | Check antes do primeiro efeito; conhecimento disponível | Alvo da reserva | Conta ou isenção | Teste executável no lab Rock 7 |
|---|---|---|---|---|---|
| Add rootfs/mpN — `pct set`/API | `CLI/pct.pm:1096-1115` → `API2/LXC/Config.pm:111-272` → `LXC::Config::apply_pending_mountpoint:1879-1905` → `LXC::create_disks:2649-2680` → `LXC.pm:2617-2630` → `Storage.pm:1157-1190` | **Storage hook `vdisk_alloc`**; vmid vem do path, pool da membership, storage/tamanho dos mountpoints. `classify_mountpoint` já separa volume de bind/device. | Config atual + rootfs/mpN novos por storage e total. | Volume conta; bind, device e caminho absoluto são isentos. | `pct set` CLI/API excedente falha antes de alloc, sem volume/pending novo; bind/device passam sem quota. |
| Import-from/update de volume | `API2/LXC/Config.pm:111-272` → `LXC::create_disks:2649-2680`/`alloc_disk` → `vdisk_alloc` ou `vdisk_clone` → `Storage.pm:1085-1105,1157-1190` | **Storage hook** escolhido pelo caminho; vmid, target storage e tamanho estão nos argumentos. Mesmo volid atual não é aumento. | Config futura do mountpoint por storage e total. | Volume final conta; transporte temporário só pelo TTL. | Import-from excedente não chama alloc/clone e mantém config; caso aceito conta rootfs/mpN. |
| Resize — `pct resize` | `CLI/pct.pm:1096-1115` → `API2/LXC.pm:2323-2494` → `volume_resize:2437-2439` → `Storage.pm:395-410` | **Storage hook `volume_resize`**; owner/vmid do volid, storage do volid e novo tamanho estão disponíveis; snapshot/non-current é ignorado. | Config atual no novo tamanho, por storage e total. | Aumento atual conta; redução e snapshot não. | Recusar antes do resize; redução passa; volume não atual/snapshot não altera quota. |
| Mover volume — `pct move-volume` | `CLI/pct.pm:1130-1140` → `API2/LXC.pm:2496-2693` → `LXC::copy_volume:2657-2668,3391-3412` → `alloc_disk:2617-2630` → `Storage.pm:1157-1190` | **Storage hook `vdisk_alloc`/clone** antes do plugin; vmid, source/target storage e tamanho são conhecidos. | Source continua durante cópia; target é acrescentado por storage e total até cleanup. | Destino conta; mesmo volid não aumenta. | Target sem headroom não chama `copy_volume`, não cria volume/config; caso aceito confere cleanup. |
| Create com rootfs/mpN, com/sem `--pool` | `CLI/pct.pm:1096-1115` → `API2/LXC.pm:140-430` → `create_disks:541-544` → `LXC.pm:2603-2635` → `Storage.pm:1157-1190` | Com `--pool`, **preflight `check_lxc_create`** antes de `create_disks`; sem pool não há quota. Hook permanece defesa. | Config futura de volumes por storage e total. | Volumes contam; bind/device/absolute são safe exemptions. | Create excedente com pool não deixa CT/volume; sem pool não é bloqueado por pool; testar storages distintos. |
| Full clone com/sem `--pool` | `CLI/pct.pm:1130-1140` → `API2/LXC.pm:1905-2320` → `copy_volume:2222-2230` → `alloc_disk:3391-3412` → `Storage.pm:1157-1190` | **Preflight `check_clone`** antes do primeiro `copy_volume`; source fornece tamanhos, pool/storage são destino. | Config do novo CT por storage e total. | Conta volumes copiados; sem pool não há quota alvo. | Clone excedente não cria CT/volume; testar override de storage e caso permitido. |
| Linked clone com/sem `--pool` | `API2/LXC.pm:1905-2320` → linked `vdisk_clone:2231-2235` → `Storage.pm:1085-1105` | **Preflight `check_clone`** antes de `vdisk_clone`; hook é defesa final. | Volumes ligados ao novo CT por storage e total. | Conta CoW referenciado. | Recusa antes de base/volume novo; caso aceito verifica rootfs/mpN. |
| Restore `pct restore`/API archive, com/sem `--pool`, inclusive overwrite | `CLI/pct.pm:1096-1115` → `API2/LXC.pm:140-544` (recover `:441-505`) → `create_disks:482-544` → `LXC.pm:2617-2630` → `Storage.pm:1157-1190` | **Preflight `check_lxc_create`** recupera `orig_conf`/mountpoints pelo parser do PVE antes de `create_disks`; pool é explícito ou do CT existente. | Config final do archive após storage mapping, por storage/total. | Volumes e `unusedN` contam; bind/device/absolute não. | Restore excedente, com/sem pool e overwrite, deixa CT/config antiga e volumes intactos. |
| Snapshot rollback | `API2/LXC/Snapshot.pm:267-329` → `LXC::Config->snapshot_rollback:315-317` → `write_config` | **Hook `write_config`** calcula config final antes da gravação. `snapshots` não é somado; `unusedN` já conta. | Config final do rollback. | Só reanexação de volume não contado seria aumento e é recusada. | Rollback de `unusedN` passa; reanexação nova falha sem mudar config; bind/device não contam. |
| Migração por storage tunnel | `libpve-guest-common-perl/usr/share/perl5/PVE/StorageTunnel.pm:205-217` → `volume_import_start` → `Storage.pm:2107-2124` | **Storage hook `volume_import`** detecta `lock: migrate` antes de consultar tamanho ou tomar o lock; o stream pode criar volid novo sem quota intermediária. | Nenhum alvo de quota durante a migração; a config final é a referência posterior. | **Isento durante `lock: migrate`**; não bloqueia por tamanho desconhecido. | Com o pool no limite, migrar pelo tunnel deve concluir; provar nenhum erro de quota e nenhuma recusa do import. |
| Migração com storage mapping | `QemuServer.pm:5230-5261` → `StorageTunnel.pm:205-217` → `volume_import` → `AbstractConfig::write_config` | `volume_import` e o trecho de disco de `write_config` retornam antes do lock enquanto a config tem `lock: migrate`. | Nenhum alvo intermediário; o volid final passa a ser contado depois que o lock de migração some. | **Isento durante a migração.** Limite conhecido: a troca pode alterar o uso de um datastore sem enforcement per-datastore durante a cópia. | Com o pool no limite, migrar para datastore mapeado deve concluir; provar ausência de recusa após o copy e conferir o novo uso por datastore no inventário final. |

## Chamadores e tratamento especial

| Chamador | Regra implementada |
|---|---|
| `vdisk_alloc` (`Storage.pm:1157-1190`) | Recebe tamanho em KiB, converte para bytes e reserva o alvo do guest; early-return antes do lock para guest sem pool/limite/módulo ou com `lock: migrate`. `pvesm alloc --vmid` passa por ele, mas permanece fora da promessa após TTL. |
| `vdisk_clone` (`Storage.pm:1085-1105`) | Obtém tamanho provisionado do volid; unknown em pool limitado falha fechado antes do clone, exceto durante `lock: migrate`. |
| `volume_resize` (`Storage.pm:395-410`) | Só aumenta volume atual identificado pelo owner; redução, `$snap`, volid não atual e `-fleece-`/`-state-` não contam. |
| `volume_import` (`Storage.pm:2107-2124`) | Mesmo volid é no-op; tamanho conhecido reserva; tamanho desconhecido falha fechado. Durante `lock: migrate`, volid novo também é isento antes do stream. |
| Fleecing/vmstate | Nomes `-fleece-` e `-state-` retornam antes do contexto/lock e nunca entram no inventário lógico. |
| OVA temporário | A reserva física temporária é aceita somente pelo TTL; o volume final segue as regras de import/restore e `write_config`. |

## Contabilidade do `write_config`

`PVE::AbstractConfig::write_config` recebe o hook em
`lib/MMPve/Module/Poollimits.pm` e chama
`PVE::MMTools::PoolLimits->check_write_config`. O hook só age para
`PVE::QemuConfig` e `PVE::LXC::Config`, compara configuração antiga e nova e só
trava quando há aumento.

O inventário usa `size=` quando presente; sem ele consulta
`PVE::Storage::volume_size_info`. Deduplica o mesmo volid, agrupa por storage e
soma o total. QEMU inclui disks (`ide/sata/scsi/virtio/nvme`), `efidisk`,
`tpmstate` e `unusedN`; LXC inclui `rootfs`, volumes `mpN` e `unusedN`.

- `unusedN` conta;
- `snapshots` e snapshots de resize não contam como uso permanente;
- bind mounts, devices e caminhos absolutos não contam;
- CD-ROM/ISO e mídia externa não contam;
- cloud-init conta apesar de `media=cdrom`;
- vmstate e fleecing não contam;
- tamanho desconhecido em aumento de pool limitado falha fechado.

Assim, rollback que reanexa um volid não contado é recusado antes da gravação;
reanexar um `unusedN` já contado não é aumento.

## Protocolo de prova

Cada cenário do Rock 7 deve registrar digest/configuração e inventário antes e
depois. Em recusa, deve provar erro antes do plugin, ausência de volume novo ou
resize, ausência de `unusedN` novo e configuração inalterada. Em caso permitido,
deve provar alvo por datastore e total. A suíte local cobre os hooks e o
preflight sem PVE instalado; o lab deve executar as linhas de CLI/API, restore
overwrite, move, NBD, storage tunnel, storage mapping, fleecing, vmstate, OVA e
replication. Para as três modalidades de migração, o caso obrigatório é um
guest já no limite de disco: a migração deve concluir sem recusa de quota; no
mapping, o lab também registra o efeito final por datastore como limitação
conhecida.

Comandos de prova:

```sh
make test test-gateway lint
make test-api
make check-anchors
```

`make test-api` usa os módulos reais de `scripts/test-pve-env.sh`; `make
check-anchors` valida os patches contra os sources fixados e mais recentes,
inclusive `libpve-storage-perl`, e executa o patch+execute com os dois trees.
Operação sem ponto anterior ao efeito fica explicitamente BLOCKED nesta matriz e
não pode ser promovida por um check posterior; as três linhas de migração são
isenções deliberadas durante `lock: migrate`, não operações BLOCKED.
