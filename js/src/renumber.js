/* Módulo renumber — aba VMID + menu "Trocar ID…" na VM + validação do wizard.
 * Namespace MM.*; gui em Ext JS 6 no estilo pvemanagerlib.js. */

/* ------------------------- Aba VMID (vmid_scheme) ------------------------- */

Ext.define('MM.panel.Vmid', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.mmPanelVmid',
    title: 'VMID',
    layout: { type: 'vbox', align: 'stretch' },

    initComponent: function () {
	let me = this;

	let store = Ext.create('Ext.data.Store', {
	    fields: ['label', { name: 'from', type: 'int' }, { name: 'to', type: 'int' }],
	    data: [],
	});

	let grid = Ext.create('Ext.grid.Panel', {
	    flex: 1,
	    store: store,
	    plugins: {
		ptype: 'cellediting',
		clicksToEdit: 1,
	    },
	    columns: [
		{
		    text: gettext('Label'), dataIndex: 'label', flex: 1,
		    editor: { xtype: 'proxmoxtextfield', allowBlank: false, maxLength: 64 },
		},
		{
		    text: 'De', dataIndex: 'from', width: 120,
		    editor: { xtype: 'proxmoxintegerfield', minValue: 100, maxValue: 9999999 },
		},
		{
		    text: 'Até', dataIndex: 'to', width: 120,
		    editor: { xtype: 'proxmoxintegerfield', minValue: 101, maxValue: 9999999 },
		},
	    ],
	    tbar: [
		{
		    xtype: 'button', text: gettext('Add'), iconCls: 'fa fa-fw fa-plus',
		    handler: () => store.add({ label: 'nova faixa', from: 1000, to: 1999 }),
		},
		{
		    xtype: 'button', text: gettext('Remove'), iconCls: 'fa fa-fw fa-minus',
		    handler: () => {
			let sel = grid.getSelection();
			store.remove(sel);
		    },
		},
		{ xtype: 'tbspacer', width: 10 },
		{
		    xtype: 'button', text: gettext('Save'), iconCls: 'fa fa-fw fa-floppy-o',
		    handler: () => me.saveScheme(),
		},
	    ],
	});

	me.reload = function () {
	    MM.Api.request({
		url: '/nodes/localhost/mm-tools/config',
		success: function (res) {
		    store.setData((res.config || {}).vmid_scheme || []);
		    me.digest = res.digest || '';
		},
	    });
	};

	// grava vmid_scheme no config do mm-tools (PUT com digest CAS)
	me.saveScheme = function () {
	    let ranges = [];
	    store.each((r) => {
		ranges.push({ label: r.get('label'), from: r.get('from'), to: r.get('to') });
	    });
	    MM.Api.request({
		url: '/nodes/localhost/mm-tools/config',
		method: 'GET',
		success: (res) => {
		    let cfg = res.config || {};
		    cfg.vmid_scheme = ranges;
		    MM.Api.request({
			method: 'PUT',
			url: '/nodes/localhost/mm-tools/config',
			params: { digest: res.digest },
			data: { config: cfg, digest: res.digest },
			success: () => {
			    me.digest = undefined;
			    me.reload();
			    Ext.Msg.alert('MasterMind', gettext('Saved'));
			},
		    });
		},
	    });
	};

	// grava a primeira faixa como next-id do datacenter (datacenter.cfg),
	// igual ao editor "Next Free VMID Range" do PVE (PUT /cluster/options).
	me.saveNextId = function () {
	    let first = store.getAt(0);
	    if (!first || !first.get('from') || !first.get('to')) {
		Ext.Msg.alert('MasterMind', 'Cadastre a faixa principal antes (primeira linha da grade).');
		return;
	    }
	    MM.Api.request({
		method: 'PUT',
		url: '/cluster/options',
		data: { 'next-id': { lower: first.get('from'), upper: first.get('to') } },
		success: () => Ext.Msg.alert(
		    'MasterMind',
		    `next-id do datacenter gravado: ${first.get('from')}–${first.get('to')}`,
		),
	    });
	};

	Ext.apply(me, {
	    items: [
		{
		    xtype: 'component',
		    padding: '10 10 0 10',
		    html: 'Faixas de VMID por finalidade (vmid_scheme). O renumber avisa quando o ID novo cai fora delas.',
		},
		{
		    xtype: 'container',
		    padding: 10,
		    layout: { type: 'hbox' },
		    items: [
			{
			    xtype: 'button',
			    text: 'Gravar faixa principal no next-id do datacenter.cfg',
			    iconCls: 'fa fa-fw fa-arrow-up',
			    handler: () => me.saveNextId(),
			},
			{ xtype: 'tbspacer', width: 10 },
			{
			    xtype: 'button', text: gettext('Reload'), iconCls: 'fa fa-fw fa-refresh',
			    handler: () => me.reload(),
			},
		    ],
		},
		grid,
	    ],
	    listeners: { activate: () => me.reload() },
	});

	me.callParent();
	me.reload();
    },
});

MM.registerTab({ xtype: 'mmPanelVmid', title: 'VMID' });

/* ------------------------- Diálogo "Trocar ID…" ------------------------- */

Ext.define('MM.window.Renumber', {
    extend: 'Ext.window.Window',
    alias: 'widget.mmRenumberWindow',

    modal: true,
    width: 620,
    layout: { type: 'vbox', align: 'stretch' },
    title: 'Trocar ID da VM',

    vmid: undefined,   // ID antigo
    nodename: undefined,

    initComponent: function () {
	let me = this;
	if (!me.vmid || !me.nodename) {
	    throw 'mmRenumberWindow: precisa de vmid e nodename';
	}
	me.title += ` ${me.vmid}`;

	let store = Ext.create('Ext.data.Store', {
	    fields: ['check', 'ok', 'warning', 'detail'],
	    data: [],
	});

	let idfield = Ext.create('Proxmox.form.field.Integer', {
	    fieldLabel: 'ID novo',
	    minValue: 100,
	    maxValue: 9999999,
	    allowBlank: false,
	    listeners: {
		change: function (f, value) {
		    store.setData([]);
		    me.setButtonState();
		    if (!value || value === me.vmid || value < 100) { return; }
		    me.validateNewId(value, store);
		},
	    },
	});

	let grid = Ext.create('Ext.grid.Panel', {
	    flex: 1,
	    store: store,
	    margin: '10 0 0 0',
	    columns: [
		{
		    text: '#', width: 40, dataIndex: 'ok',
		    renderer: (v, md, rec) => {
			if (rec.get('warning') && v) { return '⚠'; }
			return MM.Utils.checkIcon(v);
		    },
		},
		{ text: gettext('Check'), dataIndex: 'check', width: 150 },
		{ text: gettext('Detail'), dataIndex: 'detail', flex: 1 },
	    ],
	});

	me.runButton = Ext.create('Ext.Button', {
	    text: 'Executar',
	    disabled: true,
	    handler: () => me.runRenumber(idfield.getValue()),
	});

	me.setButtonState = function () {
	    let allOk = store.getCount() > 0 && store.findBy(
		(r) => !r.get('ok'),
	    ) === -1;
	    me.runButton.setDisabled(!allOk);
	};

	// validação em tempo real: nextid nativo (livre?) + precheck mm-tools
	me.validateNewId = function (value, st) {
	    let from = parseInt(me.vmid, 10);
	    let to = parseInt(value, 10);
	    MM.Api.request({
		url: '/cluster/nextid',
		params: { vmid: to },
		method: 'GET',
		success: () => {
		    MM.Api.request({
			url: `/nodes/${me.nodename}/mm-tools/renumber/precheck`,
			params: { from, to },
			success: (res) => {
			    st.setData((res.checks || []).map((c) => ({
				check: c.check, ok: !!c.ok,
				warning: !!c.warning, detail: c.detail,
			    })));
			    me.setButtonState();
			},
		    });
		},
		failure: () => {
		    st.setData([{ check: 'id-novo-livre', ok: false, detail: `ID ${to} em uso` }]);
		    me.setButtonState();
		},
	    });
	};

	me.runRenumber = function (value) {
	    let from = parseInt(me.vmid, 10);
	    let to = parseInt(value, 10);
	    MM.Api.request({
		method: 'POST',
		url: `/nodes/${me.nodename}/mm-tools/renumber/run`,
		params: { from, to },
		waitMsgTarget: me,
		success: (res) => {
		    me.close();
		    let upid = res?.data;
		    if (upid) {
			Ext.create('Proxmox.window.TaskViewer', { upid, autoShow: true });
		    }
		},
	    });
	};

	Ext.apply(me, {
	    items: [
		{ xtype: 'container', padding: 10, items: [idfield] },
		grid,
	    ],
	    buttons: [{ text: gettext('Cancel'), handler: () => me.close() }, me.runButton],
	});

	me.callParent();
    },
});

/* ------------------------- Menu da VM: "Trocar ID…" ------------------------- */

Ext.define('PVE.qemu.CmdMenu', {
    override: 'PVE.qemu.CmdMenu',
    initComponent: function () {
	let me = this;
	me.callParent(arguments);
	let info = me.pveSelNode.data;
	let caps = Ext.state.Manager.get('GuiCap');
	if (caps?.nodes?.['Sys.Modify']) {
	    me.insert(0, {
		text: 'Trocar ID…',
		iconCls: 'fa fa-fw fa-exchange',
		handler: () => Ext.create('MM.window.Renumber', {
		    vmid: info.vmid,
		    nodename: info.node,
		    autoShow: true,
		}),
	    });
	    me.insert(1, { xtype: 'menuseparator' });
	}
    },
});

/* ------------------- Wizard Create VM: aviso fora da faixa ------------------- */

Ext.define('MM.VmidSchemeCache', {
    singleton: true,
    ranges: null,
    loaded: false,

    load: function (cb) {
	if (MM.VmidSchemeCache.loaded) { cb(MM.VmidSchemeCache.ranges || []); return; }
	MM.Api.request({
	    url: '/nodes/localhost/mm-tools/config',
	    success: (res) => {
		MM.VmidSchemeCache.ranges = (res.config || {}).vmid_scheme || [];
		MM.VmidSchemeCache.loaded = true;
		cb(MM.VmidSchemeCache.ranges);
	    },
	    failure: () => cb([]),
	});
    },

    warningFor: function (vmid) {
	let ranges = MM.VmidSchemeCache.ranges || [];
	if (!ranges.length || !vmid) { return null; }
	for (const r of ranges) {
	    if (vmid >= r.from && vmid <= r.to) { return null; }
	}
	let labels = ranges.map((r) => r.label).join(', ');
	return `AVISO: VMID ${vmid} fora das faixas MasterMind (${labels}). ` +
	    'Confirme se é intencional.';
    },
});

Ext.define('PVE.qemu.CreateWizard', {
    override: 'PVE.qemu.CreateWizard',
    initComponent: function () {
	let me = this;
	me.callParent(arguments);

	let vmidField = me.query('[name=vmid]')[0];
	if (!vmidField) { return; }

	let warnBox = Ext.create('Ext.Component', {
	    hidden: true,
	    cls: 'x-form-display-field',
	    style: { color: '#c94f41', paddingTop: '4px', whiteSpace: 'normal' },
	});
	let col = vmidField.ownerCt;
	if (col) { col.insert(col.items.indexOf(vmidField) + 1, warnBox); }

	MM.VmidSchemeCache.load(() => {
	    let upd = () => {
		let w = MM.VmidSchemeCache.warningFor(parseInt(vmidField.getValue(), 10));
		if (w) {
		    warnBox.update(Ext.String.htmlEncode(w));
		    warnBox.show();
		} else {
		    warnBox.hide();
		}
	    };
	    vmidField.on('change', upd);
	    upd();
	});
    },
});
