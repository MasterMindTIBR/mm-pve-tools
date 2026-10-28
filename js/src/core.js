/* mm-tools.js — núcleo da interface MasterMind (Datacenter → MasterMind).
 * Carregado pelo <script> extra inserido no index.html.tpl (patch de 1 linha).
 * Namespace MM.*; módulos registram abas com MM.registerTab(...).
 * Estilo: Ext JS 6, mesmo padrão do pvemanagerlib.js.
 */

Ext.define('MM.Version', { singleton: true, version: '0.1.0' });

/* Registro de abas da tela MasterMind (cada módulo adiciona a sua). */
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
		let msg = response?.result?.errors?.toString?.() ||
		    response?.statusText || `HTTP ${response.status}`;
		if (opts.failure) { opts.failure(msg, response); return; }
		Ext.Msg.alert(gettext('Error'), msg);
	    },
	};
	if (opts.data) {
	    base.method = opts.method || 'PUT';
	    base.data = opts.data;
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
    checkIcon: function (ok, extra) {
	let ico = ok ? '✔' : '✘';
	return extra ? `${ico} ${extra}` : ico;
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
		    // endpoint: {config, digest, absent}
		    let mods = (res.config || {}).modules || {};
		    moduleGrid.getStore().setData(
			Object.keys(mods).map((k) => ({ name: k, enabled: !!mods[k] })),
		    );
		    me.digest = res.digest || '';
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
		    let ap = res.applied || {};
		    let patches = ap.patches || {};
		    store.add({
			node: res.node || n.name,
			pkg: res.package_version,
			pve: res.pve_version,
			patch_tpl: patches.index_tpl?.status,
			patch_pm: patches.nodes_pm?.status,
			state: ap.state,
			applied: ap.applied_revision,
			cfgrev: ap.config_revision,
			ntfs3g_ok: !!res.ntfs3g?.ok,
			ntfs3g: res.ntfs3g?.ok === undefined
			    ? gettext('skipped')
			    : (res.ntfs3g.ok ? 'ok' : (res.ntfs3g.error || 'fail')),
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
		    'state', 'applied', 'cfgrev', 'ntfs3g', 'ntfs3g_ok',
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
			`${rec.get('applied') ?? '-'}/${rec.get('cfgrev') ?? '-'} (${v})`,
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

/* ------------------------- Painel principal ------------------------- */

Ext.define('MM.panel.Tools', {
    extend: 'Ext.tab.Panel',
    alias: 'widget.mmToolsPanel',
    title: 'MasterMind',
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
	Ext.apply(me, { items });
	me.callParent();
    },
});

/* Aba dentro do Datacenter: PVE.dc.Config adiciona as tabs conforme
 * permissões; nós entram por cima com override seguro (callParent + add). */
Ext.define('PVE.dc.Config', {
    override: 'PVE.dc.Config',
    initComponent: function () {
	let me = this;
	me.callParent(arguments);
	let caps = Ext.state.Manager.get('GuiCap');
	if (caps?.dc?.['Sys.Audit']) {
	    me.add({ xtype: 'mmToolsPanel' });
	}
    },
});
