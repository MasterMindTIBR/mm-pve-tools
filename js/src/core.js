/* mm-tools.js — núcleo da interface MM Tools (Datacenter → MM Tools).
 * Carregado pelo <script> extra inserido no index.html.tpl (patch de 1 linha).
 * Namespace MM.*; módulos registram abas com MM.registerTab(...).
 * Estilo: Ext JS 6, mesmo padrão do pvemanagerlib.js.
 */

Ext.define('MM.Version', { singleton: true, version: '@MM_PVE_VERSION@' });

/* Registro de abas da tela MM Tools (cada módulo adiciona a sua). */
Ext.define('MM.Registry', {
    singleton: true,
    tabs: [],
});

MM.registerTab = function (cfg) {
    // eslint-disable-next-line no-console
    if (typeof cfg !== 'object' || !cfg.title) { console.warn('MM.registerTab: cfg inválido'); return; }
    MM.Registry.tabs.push(cfg);
};

/* Helper de API em cima de Proxmox.Utils.API2Request. */
Ext.define('MM.Api', {
    singleton: true,

    request: function (opts) {
	let base = {
	    method: opts.method || 'GET',
	    url: opts.url,
	    params: opts.params,
	    failure: function (response) {
		let msg = response?.htmlStatus ||
		    (Proxmox.Utils.extractRequestError
			? Proxmox.Utils.extractRequestError(response?.result || {}, true) : '') ||
		    response?.result?.errors?.toString?.() ||
		    response?.statusText || `HTTP ${response.status}`;
		if (opts.failure) { opts.failure(msg, response); return; }
		Ext.Msg.alert(gettext('Error'), msg);
	    },
	};
	if (opts.data) {
	    base.method = opts.method || 'PUT';
	    base.data = opts.data;
	}
	if (opts.jsonData) {
	    base.method = opts.method || 'PUT';
	    base.jsonData = opts.jsonData;
	    base.headers = Ext.apply({ 'Content-Type': 'application/json' }, opts.headers || {});
	}
	if (opts.success) {
	    base.success = function (response) { opts.success(response.result, response); };
	}
	Proxmox.Utils.API2Request(base);
    },

    /* nodes online (via /cluster/status) */
    clusterNodes: function (cb, fb) {
	MM.Api.request({
	    url: '/cluster/status',
	    success: function (res) {
		let nodes = (res.data || []).filter((e) => e.type === 'node' && e.online);
		cb(nodes);
	    },
	    failure: fb,
	});
    },
});

Ext.define('MM.Utils', {
    singleton: true,
    html: function (value) {
	return Ext.String.htmlEncode(String(value ?? ''));
    },
    checkIcon: function (ok, extra) {
	let ico = ok ? '✔' : '✘';
	return extra ? `${ico} ${MM.Utils.html(extra)}` : ico;
    },
});

/* Aplicar em todos os nodes: POST /nodes/{n}/mm-tools/apply em cada online,
 * Task Log do primeiro para acompanhar. */
MM.applyAll = function () {
    MM.Api.clusterNodes((nodes) => {
	let upids = [];
	let pending = nodes.length;
	let maybeShow = () => {
	    if (pending === 0 && upids.length > 0) {
		Ext.create('Proxmox.window.TaskViewer', { upid: upids[0], autoShow: true });
	    }
	};
	nodes.forEach((n) => {
	    MM.Api.request({
		method: 'POST',
		url: `/nodes/${n.name}/mm-tools/apply`,
		success: (res) => {
		    if (res?.data) { upids.push(res.data); }
		    pending--; maybeShow();
		},
		failure: () => { pending--; maybeShow(); },
	    });
	});
    });
};

/* ------------------------- Geral ------------------------- */

Ext.define('MM.panel.General', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.mmPanelGeneral',
    title: gettext('General'),
    layout: { type: 'vbox', align: 'stretch' },

    initComponent: function () {
	let me = this;

	let moduleGrid = Ext.create('Ext.grid.Panel', {
	    flex: 1,
	    store: { fields: ['name', 'enabled'], data: [] },
	    columns: [
		{ text: gettext('Module'), dataIndex: 'name', flex: 1 },
		{
		    text: gettext('Enabled'),
		    dataIndex: 'enabled',
		    width: 120,
		    renderer: (v) => v ? '✔' : '✘',
		},
	    ],
	});

	me.reload = function () {
	    MM.Api.request({
		url: '/nodes/localhost/mm-tools/config',
		success: function (res) {
		    let data = res.data || {};
		    let mods = (data.config || {}).modules || {};
		    moduleGrid.getStore().setData(
			Object.keys(mods).map((k) => ({ name: k, enabled: !!mods[k] })),
		    );
		    me.digest = data.digest || '';
		},
	    });
	};

	Ext.apply(me, {
	    items: [
		{
		    xtype: 'container',
		    padding: 10,
		    layout: { type: 'hbox' },
		    items: [
			{
			    xtype: 'button',
			    text: gettext('Apply on all nodes'),
			    iconCls: 'fa fa-fw fa-play',
			    handler: () => MM.applyAll(),
			},
			{ xtype: 'tbspacer', width: 10 },
			{
			    xtype: 'button',
			    text: gettext('Reload'),
			    iconCls: 'fa fa-fw fa-refresh',
			    handler: () => me.reload(),
			},
		    ],
		},
		moduleGrid,
	    ],
	    listeners: { activate: () => me.reload() },
	});

	me.callParent();
	me.reload();
    },
});

/* ------------------------- Diagnóstico ------------------------- */

MM.fillDiag = function (grid) {
    MM.Api.clusterNodes((nodes) => {
	let store = grid.getStore();
	store.removeAll();
	nodes.forEach((n) => {
	    MM.Api.request({
		url: `/nodes/${n.name}/mm-tools/status`,
		success: (res) => {
		    let data = res.data || {};
		    let ap = data.applied || {};
		    let patches = ap.patches || {};
		    store.add({
			node: data.node || n.name,
			pkg: data.package_version,
			pve: data.pve_version,
			patch_tpl: patches.index_tpl?.status,
			patch_pm: patches.nodes_pm?.status,
			state: ap.state,
			applied: ap.applied_revision,
			cfgrev: ap.config_revision,
			branding_serves: !!data.branding?.serves_asset,
			ntfs3g_ok: !!data.ntfs3g?.ok,
			ntfs3g: data.ntfs3g?.ok === undefined
			    ? gettext('skipped')
			    : (data.ntfs3g.ok ? 'ok' : (data.ntfs3g.error || 'fail')),
		    });
		},
		failure: (msg) => {
		    store.add({ node: n.name, state: 'inacessível', ntfs3g: msg });
		},
	    });
	});
    });
};

Ext.define('MM.panel.Diag', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.mmPanelDiag',
    title: gettext('Diagnostics'),

    initComponent: function () {
	let me = this;
	Ext.apply(me, {
	    store: {
		fields: [
		    'node', 'pkg', 'pve', 'patch_tpl', 'patch_pm',
		    'state', 'applied', 'cfgrev', 'branding_serves', 'ntfs3g', 'ntfs3g_ok',
		],
	    },
	    columns: [
		{ text: gettext('Node'), dataIndex: 'node', width: 120 },
		{ text: 'mm-pve-tools', dataIndex: 'pkg', width: 110 },
		{ text: 'PVE', dataIndex: 'pve', width: 70 },
		{
		    text: 'patch index.tpl', dataIndex: 'patch_tpl', width: 120,
		    renderer: (v) => MM.Utils.checkIcon(v === 'applied', v),
		},
		{
		    text: 'patch Nodes.pm', dataIndex: 'patch_pm', width: 120,
		    renderer: (v) => MM.Utils.checkIcon(v === 'applied', v),
		},
		{
		    text: gettext('Revision'), dataIndex: 'state', width: 140,
		    renderer: (v, md, rec) =>
			`${MM.Utils.html(rec.get('applied') ?? '-')}/${MM.Utils.html(rec.get('cfgrev') ?? '-')} (${MM.Utils.html(v)})`,
		},
		{
		    text: gettext('Branding'), dataIndex: 'branding_serves', width: 100,
		    renderer: (v) => MM.Utils.checkIcon(v, v ? gettext('serving') : gettext('not serving')),
		},
		{
		    text: 'ntfs3g', dataIndex: 'ntfs3g', flex: 1,
		    renderer: (v, md, rec) => MM.Utils.checkIcon(rec.get('ntfs3g_ok'), v),
		},
	    ],
	    tbar: [
		{
		    xtype: 'button',
		    text: gettext('Reload'),
		    iconCls: 'fa fa-fw fa-refresh',
		    handler: () => MM.fillDiag(me),
		},
	    ],
	});
	me.callParent();
	me.on('activate', () => MM.fillDiag(me));
    },
});

/* ------------------------- Sobre ------------------------- */

Ext.define('MM.About', {
    singleton: true,
    repo: 'https://github.com/MasterMindTIBR/mm-pve-tools',
    ntfs3g: 'https://github.com/junglivre/pve-file-restore-ntfs3g',
    apt: 'https://apt.mastermindti.cloud/debian',
    license: 'https://www.gnu.org/licenses/agpl-3.0.html',
    // Colaboradores: [nome, usuário do GitHub].
    contributors: [
	['jung', 'junglivre'],
    ],
    modules: [
	['Renumber', 'troca o VMID de VMs e CTs sem copiar os discos.'],
	['Restore', 'publica uma pasta de um backup do PBS para a VM do cliente, por SMB somente leitura.'],
	['Branding', 'logo e título em todos os nodes.'],
	['Interface', 'console padrão por tipo e sem o pop-up de assinatura.'],
	['Updates', 'atualiza os nodes pela GUI e sugere reboot só quando o kernel muda.'],
	['Limites de pool', 'vCPU, RAM e disco por pool, valendo em todo o PVE.'],
    ],

    version: function () {
	let v = MM.Version.version;
	return v && v.indexOf('@') !== 0 ? v : 'desenvolvimento';
    },

    link: function (url, text) {
	let u = MM.Utils.html(url);
	return `<a href="${u}" target="_blank" rel="noopener noreferrer">${MM.Utils.html(text || url)}</a>`;
    },

    html: function () {
	let h = MM.Utils.html;
	let section = (title, body) =>
	    `<div style="margin-top:18px"><div style="font-size:14px;font-weight:600;margin-bottom:6px">${h(title)}</div>${body}</div>`;
	let list = (items) => `<ul style="margin:0;padding-left:20px;line-height:1.7">${items.map((i) => `<li>${i}</li>`).join('')}</ul>`;
	return [
	    '<div style="max-width:760px">',
	    '<div style="display:flex;align-items:center;gap:12px">',
	    '<i class="fa fa-puzzle-piece" style="font-size:32px"></i>',
	    '<div><div style="font-size:20px;font-weight:600">MM Tools</div>',
	    `<div>Versão <b class="mm-about-version">${h(MM.About.version())}</b> · pacote <code>mm-pve-tools</code></div></div>`,
	    '</div>',
	    '<p style="margin-top:12px">Extensões da MasterMindTI para a GUI do Proxmox VE. ',
	    'Cada módulo é ligado à parte e pode ser desligado sem deixar resto.</p>',
	    section('Módulos', list(MM.About.modules.map(([name, text]) => `<b>${h(name)}</b>: ${h(text)}`))),
	    section('Links', list([
		`Código-fonte: ${MM.About.link(MM.About.repo, 'github.com/MasterMindTIBR/mm-pve-tools')}`,
		`Novidades de cada versão: ${MM.About.link(`${MM.About.repo}/blob/master/CHANGELOG.md`, 'CHANGELOG')}`,
		`Reportar um problema: ${MM.About.link(`${MM.About.repo}/issues`, 'issues no GitHub')}`,
		`Repositório APT: ${MM.About.link(MM.About.apt, 'apt.mastermindti.cloud')}`,
	    ])),
	    section('Créditos', list([
		'Desenvolvido pela <b>MasterMindTI</b>:'
		    + list(MM.About.contributors.map(([name, user]) =>
			`${h(name)} ${MM.About.link(`https://github.com/${user}`, `(@${user})`)}`)),
		`Restauração de NTFS com deduplicação do Windows: ${MM.About.link(MM.About.ntfs3g, 'pve-file-restore-ntfs3g')}`,
		'Feito sobre o Proxmox VE, o Proxmox Widget Toolkit e o Ext JS.',
	    ])),
	    section('Licença', `<p style="margin:0">Software livre sob a ${MM.About.link(MM.About.license, 'GNU AGPL 3.0 ou posterior')}. `
		+ '© 2026 MasterMindTI.</p>'
		+ '<p style="margin-top:8px;color:#888">Proxmox é marca registrada da Proxmox Server Solutions GmbH.<br>'
		+ 'O MM Tools é um projeto independente, sem vínculo com a Proxmox.</p>'),
	    '</div>',
	].join('');
    },
});

Ext.define('MM.panel.About', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.mmPanelAbout',
    title: 'Sobre',
    iconCls: 'fa fa-fw fa-info-circle',
    itemId: 'about',
    scrollable: true,
    bodyPadding: 20,

    initComponent: function () {
	this.html = MM.About.html();
	this.callParent();
    },
});

/* ------------------------- Painel principal ------------------------- */

Ext.define('MM.panel.Tools', {
    extend: 'Ext.tab.Panel',
    alias: 'widget.mmToolsPanel',
    title: 'MM Tools',
    iconCls: 'fa fa-fw fa-puzzle-piece',

    initComponent: function () {
	let me = this;
	let items = [
	    { xtype: 'mmPanelGeneral' },
	    { xtype: 'mmPanelDiag' },
	];
	MM.Registry.tabs.forEach((cfg) => {
	    items.push(Ext.apply({ closable: false }, cfg));
	});
	items.push({ xtype: 'mmPanelAbout' });
	Ext.apply(me, { items });
	me.callParent();
    },
});

/* Aba dentro do Datacenter. O upstream constrói a árvore em insertNodes()
 * antes do callParent(); interceptamos esse ponto para a aba entrar no
 * TreeStore real, em vez de adicioná-la tarde demais ao card panel. */
Ext.define('PVE.dc.Config', {
    override: 'PVE.dc.Config',
    insertNodes: function (items) {
	let caps = Ext.state.Manager.get('GuiCap') || {};
	if (caps.dc?.['Sys.Audit']) {
	    items.push({
		xtype: 'mmToolsPanel',
		// itemId antigo mantido: é o que fica no estado/URL da GUI.
		itemId: 'mastermind',
		title: 'MM Tools',
		iconCls: 'fa fa-fw fa-puzzle-piece',
	    });
	}
	this.callParent(arguments);
    },
});
