/* mm-tools.js — núcleo da interface MM Tools (Datacenter → MM Tools).
 * Carregado pelo <script> extra inserido no index.html.tpl (patch de 1 linha).
 * Namespace MM.*; módulos registram abas com MM.registerTab(...).
 * Estilo: Ext JS 6, mesmo padrão do pvemanagerlib.js.
 */

/* The catalogs are loaded immediately before this file by Makefile. Keep the
 * detector aligned with PVE.Utils.getUiLanguage(), including its cookie and
 * Proxmox.defaultLang fallback, but make this safe during early PVE boot. */
MM.i18n = MM.i18n || {};
MM.i18n.normalize = function (code) {
    if (['en', 'en_US', 'en-US'].includes(code)) { return 'en'; }
    if (['pt_BR', 'pt-BR'].includes(code)) { return 'pt_BR'; }
    if (['es', 'es_ES', 'es-ES'].includes(code)) { return 'es'; }
    return 'en';
};
MM.i18n.detect = function () {
    let code;
    try {
	if (PVE?.Utils?.getUiLanguage) { code = PVE.Utils.getUiLanguage(); }
    } catch (e) { /* PVE may not have finished loading its helpers yet. */ }
    if (!code) {
	try { code = Ext.util?.Cookies?.get?.('PVELangCookie'); } catch (e) { /* fallback */ }
    }
	if (!code && typeof Proxmox !== 'undefined') { code = Proxmox.defaultLang; }
    return MM.i18n.normalize(code || 'en');
};
MM.i18n.language = MM.i18n.detect();
MM.t = function (key, args) {
    let catalogs = MM.i18n.catalogs || {};
    let text = catalogs[MM.i18n.language]?.[key]
	|| catalogs.en?.[key]
	|| key;
    return String(text).replace(/\{([a-zA-Z0-9_]+)\}/g, (match, name) => {
	if (args && Object.prototype.hasOwnProperty.call(args, name)) { return args[name]; }
	return match;
    });
};

Ext.define('MM.Version', { singleton: true, version: '@MM_PVE_VERSION@' });

/* Registro de abas da tela MM Tools (cada módulo adiciona a sua). */
Ext.define('MM.Registry', {
    singleton: true,
    tabs: [],
});

MM.registerTab = function (cfg) {
    // eslint-disable-next-line no-console
	if (typeof cfg !== 'object' || !cfg.title) { console.warn('MM.registerTab: invalid cfg'); return; }
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
		Ext.Msg.alert(MM.t('common.error'), msg);
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

    /* Todos os nodes, inclusive os que estão offline: usado pela General para
     * não transformar ausência de resposta em "aplicado". */
    clusterNodesAll: function (cb, fb) {
	MM.Api.request({
	    url: '/cluster/status',
	    success: function (res) {
		cb((res.data || []).filter((e) => e.type === 'node'));
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
MM.applyAll = function (done) {
    MM.Api.clusterNodes((nodes) => {
	let upids = [];
	let pending = nodes.length;
	let maybeShow = () => {
	    if (pending === 0) {
		if (upids.length > 0) {
		    Ext.create('Proxmox.window.TaskViewer', { upid: upids[0], autoShow: true });
		}
		if (done) { done(); }
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
	maybeShow();
    }, () => { if (done) { done(); } });
};

/* ------------------------- Geral ------------------------- */

/* Módulos na ordem da tela, o que cada um faz e o aviso mostrado ao ligar. */
Ext.define('MM.Modules', {
    singleton: true,
    order: ['ui', 'updates', 'poollimits', 'renumber', 'restore', 'branding'],
    info: {
	ui: MM.t('module.info.ui'),
	updates: MM.t('module.info.updates'),
	poollimits: MM.t('module.info.poollimits'),
	renumber: MM.t('module.info.renumber'),
	restore: MM.t('module.info.restore'),
	branding: MM.t('module.info.branding'),
    },
    warnOn: {
	poollimits: MM.t('module.warn.poollimits'),
	restore: MM.t('module.warn.restore'),
	branding: MM.t('module.warn.branding'),
    },
    label: {
	ui: MM.t('tabs.interface'),
	updates: MM.t('tabs.updates'),
	poollimits: MM.t('tabs.poollimits'),
	renumber: MM.t('tabs.vmid'),
	restore: MM.t('tabs.restore'),
	branding: MM.t('tabs.branding'),
    },
});

/* Strings novas da General e da faixa comum das abas. Mantidas aqui para o
 * catálogo de i18n do Rock 5 conseguir migrá-las sem procurar no código. */
MM.Text = {
    general: {
	onAll: MM.t('general.on_all'), offAll: MM.t('general.off_all'),
	allOnTitle: MM.t('general.on_all_title'), allOffTitle: MM.t('general.off_all_title'),
	allQuestion: MM.t('general.all_question'), noChanges: MM.t('general.no_changes'),
	changeList: MM.t('general.change_list'), applyRevert: MM.t('general.apply_revert'),
	nodes: MM.t('common.nodes'), unknown: MM.t('common.unknown'),
	configChanged: MM.t('general.config_changed'),
	moduleOn: MM.t('general.module_on'), moduleOff: MM.t('general.module_off'),
	moduleQuestion: MM.t('general.module_question'),
    },
    module: {
	off: MM.t('module.off'), goGeneral: MM.t('module.go_general'),
    },
};

/* Estado comum e navegação das abas de módulo. A aba continua editável quando
 * desligada; a faixa apenas informa onde a ativação é feita. */
MM.selectModule = function (name) {
    let tools = Ext.ComponentQuery.query('mmToolsPanel')[0];
    let general = tools?.down('mmPanelGeneral')
	|| Ext.ComponentQuery.query('mmPanelGeneral')[0];
    if (!general) { return; }
    if (tools) { tools.setActiveTab(general); }
    if (general.selectModule) { general.selectModule(name); }
};

MM.ModuleState = {
    banner: function (name) {
	return Ext.create('Ext.container.Container', {
	    itemId: 'module-off-banner', dock: 'top', hidden: true, padding: '7 10',
	    cls: 'mm-module-off-banner',
	    layout: { type: 'hbox', align: 'middle' },
	    items: [
		{ xtype: 'component', itemId: 'module-off-text', flex: 1,
		    html: MM.Utils.html(MM.Text.module.off) },
		{ xtype: 'button', text: MM.Text.module.goGeneral,
		    handler: () => MM.selectModule(name) },
	    ],
	});
    },

    bind: function (panel, name) {
	panel.moduleName = name;
	panel.moduleBanner = MM.ModuleState.banner(name);
	panel.addDocked(panel.moduleBanner);
	let isAlive = () => !panel.destroyed && !panel.isDestroyed
	    && !panel.moduleBanner.destroyed && !panel.moduleBanner.isDestroyed;
	panel.refreshModuleState = function () {
	    MM.Api.request({
		url: '/nodes/localhost/mm-tools/config',
		success: (res) => {
		    if (!isAlive()) { return; }
		    let enabled = !!res.data?.config?.modules?.[name];
		    panel.moduleEnabled = enabled;
		    panel.moduleBanner.setHidden(enabled);
		},
		failure: () => {
		    if (!isAlive()) { return; }
		    panel.moduleEnabled = false;
		    panel.moduleBanner.setHidden(false);
		},
	    });
	};
	panel.on('activate', panel.refreshModuleState);
	panel.refreshModuleState();
    },
};

/* Liga/desliga um módulo: grava a seção "modules" (CAS pelo digest lido) e
 * aplica em todos os nodes, para não depender do timer de cada node. */
MM.setModules = function (changes, digest, done) {
    MM.Api.request({
	url: '/nodes/localhost/mm-tools/config',
	success: (res) => {
	    let data = res.data || {};
	    if (digest && data.digest && digest !== data.digest) {
		Ext.Msg.alert(MM.t('common.error'), MM.Text.general.configChanged);
		return;
	    }
	    let mods = Ext.apply({}, (data.config || {}).modules || {});
	    Object.keys(changes).forEach((name) => { mods[name] = changes[name] ? 1 : 0; });
	    let params = { value: JSON.stringify(mods) };
	    if (data.digest) { params.digest = data.digest; }
	    MM.Api.request({
		method: 'PUT',
		url: '/nodes/localhost/mm-tools/config/modules',
		params,
		success: () => {
		    MM.applyAll(() => {
			if (changes.branding !== undefined && MM.Branding?.init) { MM.Branding.init(); }
			if (done) { done(); }
		    });
		},
	    });
	},
    });
};

MM.setModule = function (name, enabled, digest, done) {
    MM.setModules({ [name]: enabled }, digest, done);
};

Ext.define('MM.panel.General', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.mmPanelGeneral',
	title: MM.t('tabs.general'),
    layout: { type: 'vbox', align: 'stretch' },

    initComponent: function () {
	let me = this;
	let caps = Ext.state.Manager.get('GuiCap') || {};
	me.canEdit = !!caps.dc?.['Sys.Modify'];

	let moduleGrid = Ext.create('Ext.grid.Panel', {
	    itemId: 'modules',
	    flex: 1,
	    store: { fields: ['name', 'enabled', 'info', 'nodesApplied', 'nodesTotal',
		'nodesIssues', 'nodesUnknown'], data: [] },
	    columns: [
		{ text: MM.t('common.module'), dataIndex: 'name', width: 140 },
		{ text: MM.t('general.function'), dataIndex: 'info', flex: 1, renderer: (v) => MM.Utils.html(v) },
		{
		    text: MM.t('common.enabled'),
		    dataIndex: 'enabled',
		    width: 120,
		    renderer: (v) => v ? '✔' : '✘',
		},
		{
		    text: MM.Text.general.nodes, dataIndex: 'nodesApplied', width: 230,
		    renderer: (v, md, rec) => {
			let total = rec.get('nodesTotal') || 0;
			let issues = rec.get('nodesIssues') || [];
			let unknown = rec.get('nodesUnknown') || [];
			let suffix = issues.length ? ` — ${issues.join(', ')}` : '';
			let unknownSuffix = unknown.length ? ` (${MM.Text.general.unknown}: ${unknown.join(', ')})` : '';
			return `${v || 0}/${total}${MM.Utils.html(suffix + unknownSuffix)}`;
		    },
		},
	    ],
	});

	let toggle = function (enable) {
	    let rec = moduleGrid.getSelection()[0];
	    if (!rec) { return; }
	    let name = rec.get('name');
	    let warn = enable ? MM.Modules.warnOn[name] : '';
		let text = MM.t(enable ? 'general.enable_question' : 'general.disable_question', {
		    name: MM.Utils.html(name), question: MM.Text.general.moduleQuestion,
		})
		+ (warn ? `<br><br>${MM.Utils.html(warn)}` : '')
		    + (enable ? '' : `<br><br>${MM.t('general.revert_note')}`);
	    Ext.Msg.confirm(enable ? MM.Text.general.moduleOn : MM.Text.general.moduleOff, text, (answer) => {
		if (answer !== 'yes') { return; }
		MM.setModule(name, enable, me.digest, () => me.reload());
	    });
	};

	let toggleAll = function (enable) {
	    let changes = {};
	    moduleGrid.getStore().each((rec) => {
		if (!!rec.get('enabled') !== enable) { changes[rec.get('name')] = enable; }
	    });
	    let names = Object.keys(changes);
	    if (!names.length) { Ext.Msg.alert(MM.t('product.name'), MM.Text.general.noChanges); return; }
	    let list = names.map((name) => {
		let warning = MM.Modules.warnOn[name];
		return `<b>${MM.Utils.html(MM.Modules.label[name] || name)}</b>`
		    + (warning ? `<br>${MM.Utils.html(warning)}` : '');
	    }).join('<br><br>');
	    let text = `${MM.Text.general.changeList}<br><br>${list}`
		+ `<br><br>${MM.Text.general.allQuestion}`
		+ (!enable ? `<br><br>${MM.Text.general.applyRevert}` : '');
	    Ext.Msg.confirm(enable ? MM.Text.general.allOnTitle : MM.Text.general.allOffTitle, text, (answer) => {
		if (answer === 'yes') { MM.setModules(changes, me.digest, () => me.reload()); }
	    });
	};

	let onButton = Ext.create('Ext.button.Button', {
	    itemId: 'module-on',
	    text: MM.t('general.on'),
	    iconCls: 'fa fa-fw fa-toggle-on',
	    disabled: true,
	    handler: () => toggle(true),
	});
	let offButton = Ext.create('Ext.button.Button', {
	    itemId: 'module-off',
	    text: MM.t('general.off'),
	    iconCls: 'fa fa-fw fa-toggle-off',
	    disabled: true,
	    handler: () => toggle(false),
	});
	let syncButtons = function () {
	    let rec = moduleGrid.getSelection()[0];
	    onButton.setDisabled(!me.canEdit || !rec || !!rec.get('enabled'));
	    offButton.setDisabled(!me.canEdit || !rec || !rec.get('enabled'));
	};
	moduleGrid.on('selectionchange', syncButtons);
	let isAlive = () => !me.destroyed && !me.isDestroyed
	    && !moduleGrid.destroyed && !moduleGrid.isDestroyed;

	me.reload = function () {
	    if (!isAlive()) { return; }
	    MM.Api.request({
		url: '/nodes/localhost/mm-tools/config',
		success: function (res) {
		    if (!isAlive()) { return; }
		    let data = res.data || {};
		    let mods = (data.config || {}).modules || {};
		    let names = MM.Modules.order.concat(
			Object.keys(mods).filter((k) => !MM.Modules.order.includes(k)).sort());
		    let selected = moduleGrid.getSelection()[0]?.get('name');
		    let store = moduleGrid.getStore();
		    store.setData(names.map((k) => ({
			name: k, enabled: !!mods[k], info: MM.Modules.info[k] || '',
		    })));
		    me.digest = data.digest || '';
		    let again = selected && store.findRecord('name', selected, 0, false, true, true);
		    if (again) { moduleGrid.setSelection(again); }
		    syncButtons();
		    me.refreshNodes();
		},
	    });
	};

	Ext.apply(me, {
	    tbar: [
		onButton,
		offButton,
		'-',
		{
		    xtype: 'button', itemId: 'module-on-all', text: MM.Text.general.onAll,
		    iconCls: 'fa fa-fw fa-toggle-on', disabled: !me.canEdit,
		    handler: () => toggleAll(true),
		},
		{
		    xtype: 'button', itemId: 'module-off-all', text: MM.Text.general.offAll,
		    iconCls: 'fa fa-fw fa-toggle-off', disabled: !me.canEdit,
		    handler: () => toggleAll(false),
		},
		{
		    xtype: 'button',
		    text: MM.t('common.reload'),
		    iconCls: 'fa fa-fw fa-refresh',
		    handler: () => me.reload(),
		},
	    ],
	    items: [moduleGrid],
	    listeners: { activate: () => me.reload() },
	});
	me.selectModule = (name) => {
	    let rec = moduleGrid.getStore().findRecord('name', name, 0, false, true, true);
	    if (rec) { moduleGrid.setSelection(rec); }
	};
	me.refreshNodes = function () {
	    if (!isAlive()) { return; }
	    MM.Api.clusterNodesAll((nodes) => {
		if (!isAlive()) { return; }
		let store = moduleGrid.getStore();
		let onlineNodes = nodes.filter((n) => n.online);
		let byName = {};
		store.each((rec) => {
		    byName[rec.get('name')] = { applied: 0, issues: [],
			unknown: nodes.filter((n) => !n.online).map((n) => n.name) };
		    rec.set({ nodesApplied: 0, nodesTotal: onlineNodes.length,
			nodesIssues: [], nodesUnknown: byName[rec.get('name')].unknown });
		});
		let pending = onlineNodes.length;
		let finish = () => {
		    if (!isAlive()) { return; }
		    if (pending <= 0) { moduleGrid.getView()?.refresh?.(); }
		};
		if (!pending) { finish(); return; }
		onlineNodes.forEach((node) => MM.Api.request({
		    url: `/nodes/${node.name}/mm-tools/status`,
		    success: (res) => {
			if (!isAlive()) { return; }
			let data = res.data || {};
			store.each((rec) => {
			    let name = rec.get('name');
			    let desired = !!rec.get('enabled');
			    let applied = data.applied?.modules?.[name];
			    let check = data.modules?.[name]?.check;
			    let known = !!applied || !!check;
			    let ok = applied ? applied.ok !== false : check ? check.ok !== false : false;
			    let matches = applied ? !!applied.enabled === desired : (check
				? (!!check.enabled === desired && (desired ? check.applied !== 0 : true)) : false);
			    let state = data.applied?.state || data.status;
			    let item = byName[name];
			    if (!known) { item.unknown.push(node.name); }
			    else if (matches && ok) { item.applied++; }
			    else if (state === 'error' || state === 'partial' || !ok) { item.issues.push(node.name); }
			    else { item.unknown.push(node.name); }
			    rec.set({ nodesApplied: item.applied, nodesIssues: item.issues.slice(),
				nodesUnknown: item.unknown.slice() });
			});
			pending--; finish();
		    },
		    failure: () => {
			if (!isAlive()) { return; }
			store.each((rec) => {
			    let item = byName[rec.get('name')];
			    item.unknown.push(node.name);
			    rec.set({ nodesUnknown: item.unknown.slice() });
			});
			pending--; finish();
		    },
		}));
	    });
	};

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
		    ? MM.t('diagnostics.skipped')
		    : (data.ntfs3g.ok ? MM.t('diagnostics.ok') : (data.ntfs3g.error || MM.t('diagnostics.fail'))),
		    });
		},
	    failure: (msg) => {
		    store.add({ node: n.name, state: MM.t('diagnostics.inaccessible'), ntfs3g: msg });
		},
	    });
	});
    });
};

Ext.define('MM.panel.Diag', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.mmPanelDiag',
	    title: MM.t('tabs.diagnostics'),

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
		{ text: MM.t('common.node'), dataIndex: 'node', width: 120 },
		{ text: MM.t('diagnostics.mm_package'), dataIndex: 'pkg', width: 110 },
		{ text: MM.t('diagnostics.pve'), dataIndex: 'pve', width: 70 },
		{
		    text: MM.t('diagnostics.patch_index'), dataIndex: 'patch_tpl', width: 120,
		    renderer: (v) => MM.Utils.checkIcon(v === 'applied', v),
		},
		{
		    text: MM.t('diagnostics.patch_nodes'), dataIndex: 'patch_pm', width: 120,
		    renderer: (v) => MM.Utils.checkIcon(v === 'applied', v),
		},
		{
		    text: MM.t('diagnostics.revision'), dataIndex: 'state', width: 140,
		    renderer: (v, md, rec) =>
			`${MM.Utils.html(rec.get('applied') ?? '-')}/${MM.Utils.html(rec.get('cfgrev') ?? '-')} (${MM.Utils.html(v)})`,
		},
		{
		    text: MM.t('diagnostics.branding'), dataIndex: 'branding_serves', width: 100,
		    renderer: (v) => MM.Utils.checkIcon(v, v ? MM.t('common.serving') : MM.t('common.not_serving')),
		},
		{
		    text: MM.t('diagnostics.ntfs3g'), dataIndex: 'ntfs3g', flex: 1,
		    renderer: (v, md, rec) => MM.Utils.checkIcon(rec.get('ntfs3g_ok'), v),
		},
	    ],
	    tbar: [
		{
		    xtype: 'button',
		    text: MM.t('common.reload'),
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
	    ['tabs.vmid', 'about.renumber'], ['tabs.restore', 'about.restore'],
	    ['tabs.branding', 'about.branding'], ['tabs.interface', 'about.interface'],
	    ['tabs.updates', 'about.updates'], ['tabs.poollimits', 'about.poollimits'],
	],

    version: function () {
	let v = MM.Version.version;
	return v && v.indexOf('@') !== 0 ? v : MM.t('about.development');
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
	    `<div><div style="font-size:20px;font-weight:600">${h(MM.t('product.name'))}</div>`,
	    `<div>${h(MM.t('about.version'))} <b class="mm-about-version">${h(MM.About.version())}</b> · ${h(MM.t('about.package'))} <code>mm-pve-tools</code></div></div>`,
	    '</div>',
	    `<p style="margin-top:12px">${h(MM.t('about.intro'))}</p>`,
	    section(MM.t('about.modules'), list(MM.About.modules.map(([name, key]) => `<b>${h(MM.t(name))}</b>: ${h(MM.t(key))}`))),
	    section(MM.t('about.links'), list([
		`${h(MM.t('about.source'))}: ${MM.About.link(MM.About.repo, MM.t('about.repo_link'))}`,
		`${h(MM.t('about.changelog'))}: ${MM.About.link(`${MM.About.repo}/blob/master/CHANGELOG.md`, MM.t('about.changelog_link'))}`,
		`${h(MM.t('about.report'))}: ${MM.About.link(`${MM.About.repo}/issues`, h(MM.t('about.github_issues')))}`,
		`${h(MM.t('about.apt'))}: ${MM.About.link(MM.About.apt, MM.t('about.apt_link'))}`,
	    ])),
	    section(MM.t('about.credits'), list([
		`${h(MM.t('about.developed'))} <b>MasterMindTI</b>:`
		    + list(MM.About.contributors.map(([name, user]) =>
		    `${h(name)} ${MM.About.link(`https://github.com/${user}`, MM.t('about.github_user', { user }))}`)),
		`${h(MM.t('about.ntfs'))}: ${MM.About.link(MM.About.ntfs3g, MM.t('about.ntfs_link'))}`,
		h(MM.t('about.built_on')),
	    ])),
	    section(MM.t('about.license'), `<p style="margin:0">${h(MM.t('about.free_software'))} ${MM.About.link(MM.About.license, MM.t('about.license_link', { or_later: MM.t('about.or_later') }))}. `
		+ MM.t('about.copyright') + '</p>'
		+ `<p style="margin-top:8px;color:#888">${h(MM.t('about.proxmox_trademark'))}<br>`
		+ `${h(MM.t('about.independent'))}</p>`),
	    '</div>',
	].join('');
    },
});

Ext.define('MM.panel.About', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.mmPanelAbout',
	title: MM.t('tabs.about'),
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
	title: MM.t('product.name'),
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
		title: MM.t('product.name'),
		iconCls: 'fa fa-fw fa-puzzle-piece',
	    });
	}
	this.callParent(arguments);
    },
});
