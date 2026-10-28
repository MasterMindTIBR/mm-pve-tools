# Fixtures upstream (para testes de patch/âncora)

Copias exatas de `pve-manager` 9.2.24 (`pve-no-subscription` trixie):

- `Nodes.pm` — `/usr/share/perl5/PVE/API2/Nodes.pm`
- `index.html.tpl` — `/usr/share/pve-manager/index.html.tpl`

Fonte: http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/pve-manager_9.2.24_all.deb
Licença: AGPL-3.0 (Proxmox Server Solutions GmbH). Uso apenas como fixture
de teste das âncoras de patch.

O CI baixa a versão mais recente e roda o mesmo teste contra ela
(job "anchors" do ci.yml).
