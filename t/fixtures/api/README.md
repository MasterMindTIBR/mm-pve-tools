# Respostas reais do PVE 9.2 (fixtures)

Capturadas de um cluster de laboratório com pve-manager 9.2.24, libpve-access-control 9.1.2,
libpve-common-perl 9.2.5, libpve-cluster-perl 9.1.7, qemu-server 9.2.13 e pve-ha-manager 5.2.5,
pelo script `capture-mmtools-fixtures.sh` do lab (fora deste repositório). Nomes de nodes e
storages foram trocados por genéricos (`node1`, `local-zfs`, `local-dir`, `pbs-store`); o resto
está exatamente como o PVE devolveu.

Cada chamada gera três arquivos: `<nome>.stdout`, `<nome>.stderr` e `<nome>.rc` (código de saída
do `pvesh`/`qm`). Stubs e mocks dos testes só podem reproduzir formatos que estejam aqui.

Destaques:
- `agent-exec-status-*`: `{"exited":0}` enquanto roda; ao terminar `exited`, `exitcode`,
  `out-data`, `err-data`, `out-truncated`, `err-truncated` (sem `out-data` se não houve saída).
- `move-disk-*`: em contexto CLI o `pvesh` imprime o log da task e só na última linha a UPID
  como string JSON. A UPID pode conter `>` (`qmmove:9000-scsi0>9001-scsi0`).
- `ha-resources`, `ha-rules`: sid `vm:<id>`; regras do PVE 9 (`type node-affinity`).
- `backup-jobs`, `replication-jobs`: `exclude` é lista de VMIDs; job de replicação com
  `rate`, `comment`, `disable`, `schedule`, id `<vmid>-<n>`.
