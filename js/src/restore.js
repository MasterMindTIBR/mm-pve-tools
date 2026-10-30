/* Módulo restore — GUI (Rock 7).
 *  a) botão "Publicar pasta…" na janela de Backups (PVE.grid.BackupView),
 *     ao lado do "File Restore" (backups em storage PBS);
 *  b) diálogo MM.window.RestorePublish: navegação do backup (FileBrowser
 *     apenas-visual + campo de caminho), VM destino/duração/chamado/IP,
 *     Publicar → Task Log → resultado one-shot (UNC/usuário/senha+copiar);
 *  c) painel "Publicações ativas" (aba Restore da tela MasterMind) com
 *     sessões (GET restore/sessions) e botão Revogar;
 *  d) em falha: passo/erro + comando pronto `mm-pve restore publish
 *     ... --resume` com botão copiar.
 * A senha NUNCA aparece no Task Log — só no GET restore/results/<result_key>
 * (one-shot, dono da tarefa).
 */

Ext.define('MM.Restore.utils', {
    singleton: true,

    b64path: function (path) {
	return btoa(unescape(encodeURIComponent(path)));
    },

    copyToClipboard: function (text, btn) {
	let finish = (ok) => {
	    if (btn) {
		let old = btn.getText();
		btn.setText(ok ? '✔' : '✘');
		Ext.defer(() => btn.setText(old), 1500);
	    }
	};
	if (navigator.clipboard?.writeText) {
	    navigator.clipboard.writeText(text).then(
		() => finish(true),
		() => finish(false),
	    );
	} else {
	    let ta = document.createElement('textarea');
	    ta.value = text;
	    document.body.appendChild(ta);
	    ta.select();
	    let ok = false;
	    try { ok = document.execCommand('copy'); } catch (e) { console.warn(e); }
	    document.body.removeChild(ta);
	    finish(ok);
	}
    },

    /* falha de publish: erro + comando pronto com --resume */
    failureAlert: function (msg, resumeSpec) {
	let cmd = '';
	if (resumeSpec) {
	    cmd = 'mm-pve restore publish' +
		` --backup ${resumeSpec.backup}` +
		` --path-b64 ${resumeSpec.path_b64}`;
	    if (resumeSpec.vmid) { cmd += ` --vmid ${resumeSpec.vmid}`; }
	    if (resumeSpec.hours) { cmd += ` --hours ${resumeSpec.hours}`; }
	    if (resumeSpec.ticket) { cmd += ` --ticket ${resumeSpec.ticket}`; }
	    if (resumeSpec.vm_ip) { cmd += ` --vm-ip ${resumeSpec.vm_ip}`; }
	    cmd += ' --resume';
	}
	let items = [{ xtype: 'component', html: `<pre>${Ext.String.htmlEncode(msg)}</pre>` }];
	if (cmd) {
	    items.push({
		xtype: 'container',
		layout: 'hbox',
		items: [
		    {
			xtype: 'component',
			flex: 1,
			html: `<pre style="white-space:pre-wrap">${Ext.String.htmlEncode(cmd)}</pre>`,
		    },
		    {
			xtype: 'button',
			iconCls: 'fa fa-clipboard',
			tooltip: gettext('Copy command'),
			handler: (b) => MM.Restore.utils.copyToClipboard(cmd, b),
		    },
		],
	    });
	}
	Ext.create('Ext.window.Window', {
	    title: gettext('Publish folder failed'),
	    modal: true,
	    width: 620,
	    layout: { type: 'vbox', align: 'stretch' },
	    items,
	    buttons: [{ text: 'OK', handler: (b) => b.up('window').close() }],
	}).show();
    },
});

/* ---------------- Resultado one-shot (UNC/usuário/senha) ------------- */

Ext.define('MM.window.RestoreResult', {
    extend: 'Ext.window.Window',
    alias: 'widget.mmRestoreResult',

    title: gettext('Folder published'),
    modal: true,
    width: 560,
    layout: { type: 'vbox', align: 'stretch' },

    initComponent: function () {
	let me = this;
	let d = me.result || {};
	let row = (label, value) => ({
	    xtype: 'container',
	    layout: 'hbox',
	    margin: '4 0',
	    items: [
		{ xtype: 'component', html: `<b>${label}:</b>`, width: 110 },
		{
		    xtype: 'component',
		    flex: 1,
		    html: Ext.String.htmlEncode(value ?? ''),
		},
		{
		    xtype: 'button',
		    iconCls: 'fa fa-clipboard',
		    tooltip: gettext('Copy'),
		    handler: (b) => MM.Restore.utils.copyToClipboard(value ?? '', b),
		},
	    ],
	});

	Ext.apply(me, {
	    items: [
		row('UNC', d.unc),
		row(gettext('User'), d.user),
		row(gettext('Password'), d.password),
		row(gettext('Expires'), d.expires_at),
		{
		    xtype: 'component',
		    margin: '10 0 0 0',
		    html: `<i class="fa fa-warning"></i> ${gettext(
			'This password is shown only once.')}`,
		},
	    ],
	    buttons: [{ text: 'OK', handler: () => me.close() }],
	});
	me.callParent();
    },
});
/* ---------------- Seletor de caminho do backup (tree PBS) ------------- */
/* Proxmox.window.FileBrowser (widget-toolkit) é só download: não expõe
 * nenhum gancho de seleção externo. Reaproveitamos o mesmo model/proxy
 * ('proxmox-file-tree', já registrado globalmente pelo bundle do PVE)
 * numa janela própria, com um botão "Select" que devolve o filepath
 * (já em base64, mesmo formato aceito por path_b64) via callback. */
Ext.define('MM.window.FilePathPicker', {
    extend: 'Ext.window.Window',
    alias: 'widget.mmFilePathPicker',

    width: 800,
    height: 600,
    modal: true,
    layout: 'fit',

    // config: listURL, extraParams, archive, onSelect(filepathB64, text)
    initComponent: function () {
	let me = this;
	let tree = Ext.create('Ext.tree.Panel', {
	    scrollable: true,
	    rootVisible: false,
	    store: {
		autoLoad: false,
		model: 'proxmox-file-tree',
		defaultRootId: '/',
		nodeParam: 'filepath',
		sorters: 'text',
		proxy: {
		    type: 'proxmox',
		    appendId: false,
		    url: me.listURL,
		    extraParams: me.extraParams || {},
		},
	    },
	    columns: [
		{ text: gettext('Name'), xtype: 'treecolumn', flex: 1, dataIndex: 'text',
		    renderer: Ext.String.htmlEncode },
		{ text: gettext('Type'), dataIndex: 'type', width: 100 },
	    ],
	});
	let selectBtn = Ext.create('Ext.Button', {
	    text: gettext('Select'),
	    disabled: true,
	    handler: () => {
		let rec = tree.getSelection()[0];
		if (!rec) { return; }
		me.onSelect?.(rec.data.filepath, atob(rec.data.filepath));
		me.close();
	    },
	});
	tree.on('selectionchange', (sm, sel) => selectBtn.setDisabled(!sel.length));
	tree.getStore().load((root) => {
	    let r = tree.getStore().getRoot();
	    r.expand();
	    if (me.archive === 'all') { r.expandChildren(false); }
	    void root;
	});
	Ext.apply(me, {
	    items: [tree],
	    buttons: [
		selectBtn,
		{ text: gettext('Cancel'), handler: () => me.close() },
	    ],
	});
	me.callParent();
    },
});


/* ---------------- Diálogo de publicação ------------------------------ */

Ext.define('MM.window.RestorePublish', {
    extend: 'Ext.window.Window',
    alias: 'widget.mmRestorePublish',

    title: gettext('Publish backup folder'),
    modal: true,
    width: 620,

    initComponent: function () {
	let me = this;
	// volid: <storage>:backup/vm/<id>/<ts>
	let volid = me.volid || '';
	let m = volid.match(/^([^:]+):backup\/vm\/(\d+)\/(.+)$/);
	let storage = m ? m[1] : '';

	let pathField = Ext.create('Ext.form.field.Text', {
	    fieldLabel: gettext('Folder path'),
	    labelWidth: 140,
	    width: 520,
	    allowBlank: false,
	    emptyText: '/drive-scsi1.img.fidx/part/2/Dados',
	    listeners: {
		// edição manual invalida o filepath (já em base64) vindo do Browse
		change: () => { me.selectedPathB64 = null; },
	    },
	});

	let vmidField = Ext.create('Ext.form.field.Number', {
	    fieldLabel: gettext('Target VM'),
	    labelWidth: 140,
	    allowBlank: true,	    // padrão: a dona do backup
	    minValue: 100,
	    maxValue: 9999999,
	    value: m ? parseInt(m[2], 10) : null,
	});

	let hoursField = Ext.create('Ext.form.field.Number', {
	    fieldLabel: gettext('Duration (hours)'),
	    labelWidth: 140,
	    allowBlank: false,
	    minValue: 1,
	    value: me.defaultHours || 24,
	});

	let ticketField = Ext.create('Ext.form.field.Text', {
	    fieldLabel: gettext('GLPI ticket'),
	    labelWidth: 140,
	    regex: /^GLPI-\d+$/,
	    regexText: 'GLPI-<número>',
	});

	let vmIpField = Ext.create('Ext.form.field.Text', {
	    fieldLabel: gettext('VM IP (if no guest agent)'),
	    labelWidth: 140,
	    vtype: 'IPAddress',
	    allowBlank: true,
	});

	let submit = () => {
	    let spec = {
		backup: volid,
		path_b64: me.selectedPathB64 || MM.Restore.utils.b64path(pathField.getValue().trim()),
		vmid: vmidField.getValue() || undefined,
		hours: hoursField.getValue(),
		ticket: ticketField.getValue() || undefined,
		vm_ip: vmIpField.getValue() || undefined,
	    };
	    MM.Api.request({
		method: 'POST',
		url: '/nodes/localhost/mm-tools/restore/publish',
		params: spec,
		success: (res) => {
		    let task = res?.data || res;
		    let upid = task?.upid;
		    let resultKey = task?.result_key;
		    if (!upid || !resultKey) { return; }
		    me.close();
		    Ext.create('Proxmox.window.TaskViewer', {
			upid,
			autoShow: true,
			listeners: {
			    // busca única do resultado quando a janela fecha
			    destroy: () => MM.Restore.fetchResult(resultKey),
			},
		    });
		},
		failure: (msg) => MM.Restore.utils.failureAlert(msg, spec),
	    });
	};

	Ext.apply(me, {
	    layout: { type: 'vbox', align: 'stretch' },
	    defaults: { margin: '4 8' },
	    items: [
		{
		    xtype: 'component',
		    html: `<b>${Ext.String.htmlEncode(volid)}</b>`,
		    margin: '8 8 4 8',
		},
		{
		    xtype: 'container',
		    layout: 'hbox',
		    items: [
			pathField,
			{
			    xtype: 'button',
			    margin: '0 0 0 8',
			    text: gettext('Browse'),
			    iconCls: 'fa fa-folder-o',
			    disabled: !storage,
			    handler: () => {
				Ext.create('MM.window.FilePathPicker', {
				    title: gettext('Browse backup') + ' - ' + volid,
				    listURL:
					`/api2/json/nodes/localhost/storage/${storage}/file-restore/list`,
				    extraParams: { volume: volid },
				    archive: 'all',
				    onSelect: (filepathB64, text) => {
					me.selectedPathB64 = filepathB64;
					pathField.suspendEvent('change');
					pathField.setValue(text);
					pathField.resumeEvent('change');
				    },
				    autoShow: true,
				});
			    },
			},
		    ],
		},
		vmidField,
		hoursField,
		ticketField,
		vmIpField,
	    ],
	    buttons: [
		{
		    text: gettext('Publish'),
		    iconCls: 'fa fa-fw fa-share-square-o',
		    handler: submit,
		},
		{ text: gettext('Cancel'), handler: () => me.close() },
	    ],
	});
	me.callParent();
    },
});

/* GET restore/results/<result_key> — uma única vez; arquivo apagado no servidor */
MM.Restore.fetchResult = function (resultKey, attempt = 0) {
    MM.Api.request({
	url: `/nodes/localhost/mm-tools/restore/results/${encodeURIComponent(resultKey)}`,
	success: (res) => {
	    Ext.create('MM.window.RestoreResult', {
		autoShow: true,
		result: res?.data || res,
	    });
	},
	failure: (msg, response) => {
	    // tarefa pode ainda estar em execução quando o TaskViewer fecha
	    if (response?.status === 503 && attempt < 30) {
		Ext.defer(() => MM.Restore.fetchResult(resultKey, attempt + 1), 2000);
		return;
	    }
	    if (response?.status !== 404 && response?.status !== 403) {
		MM.Restore.utils.failureAlert(msg);
	    }
	},
    });
};

/* ---------------- Publicações ativas (aba Restore) -------------------- */

Ext.define('MM.panel.Restore', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.mmPanelRestore',

    title: gettext('Restore'),
    layout: 'fit',

    initComponent: function () {
	let me = this;

	let reload = () => {
	    me.store.setData([]);
	    MM.Api.request({
		url: '/nodes/localhost/mm-tools/restore/sessions',
		success: (res) => {
		    me.store.setData(res?.data || res || []);
		},
	    });
	};

	let revoke = () => {
	    let rec = me.getSelection()[0];
	    if (!rec) { return; }
	    let id = rec.get('id');
	    Proxmox.Utils.API2Request({
		method: 'POST',
		url: '/nodes/localhost/mm-tools/restore/revoke',
		params: { id },
		waitMsgTarget: me,
		success: (res) => {
		    if (res?.result?.data) {
			Ext.create('Proxmox.window.TaskViewer', {
			    upid: res.result.data,
			    autoShow: true,
			    listeners: { destroy: reload },
			});
		    } else {
			reload();
		    }
		},
	    });
	};

	Ext.apply(me, {
	    store: {
		fields: ['id', 'vmid', 'vlan', 'expires_at', 'path', 'ticket'],
	    },
	    columns: [
		{ text: 'ID', dataIndex: 'id', width: 130 },
		{ text: gettext('VM'), dataIndex: 'vmid', width: 80 },
		{ text: 'VLAN', dataIndex: 'vlan', width: 80 },
		{ text: gettext('Expires'), dataIndex: 'expires_at', width: 180 },
		{ text: gettext('Folder'), dataIndex: 'path', flex: 1 },
		{ text: 'GLPI', dataIndex: 'ticket', width: 110 },
	    ],
	    tbar: [
		{
		    xtype: 'proxmoxButton',
		    text: gettext('Revoke'),
		    disabled: true,
		    selModel: () => me.getSelectionModel(),
		    handler: revoke,
		},
		{ xtype: 'tbspacer', width: 10 },
		{
		    xtype: 'button',
		    text: gettext('Reload'),
		    iconCls: 'fa fa-fw fa-refresh',
		    handler: reload,
		},
		'->',
		{
		    xtype: 'button',
		    text: gettext('Test gateway'),
		    iconCls: 'fa fa-fw fa-heartbeat',
		    handler: () => {
			MM.Api.request({
			    url: '/nodes/localhost/mm-tools/restore/test-gateway',
			    success: (res) => {
				let data = res.data || {};
				let lines = (data.items || [])
				    .map((it) => (it.ok ? '✔ ' : '✘ ') + it.line)
				    .join('\n');
				Ext.Msg.alert(
				    gettext('Gateway selfcheck'),
				    lines || gettext('no output'),
				);
			    },
			});
		    },
		},
	    ],
	});
	me.callParent();
	me.on('activate', reload);
    },
});

MM.registerTab({ xtype: 'mmPanelRestore', title: gettext('Restore') });

/* -------- Botão "Publicar pasta…" na janela de Backups (PBS) --------- */

Ext.define('PVE.grid.BackupView', {
    override: 'PVE.grid.BackupView',
    initComponent: function () {
	let me = this;
	// o tbar precisa existir ANTES do callParent: Ext.panel.Panel converte
	// a config tbar num docked toolbar real durante o próprio initComponent
	// do pai, então empurrar depois (push no array) não aparece mais —
	// o array já foi consumido.
	me.tbar = me.tbar || [];
	me.tbar.push({
	    xtype: 'proxmoxButton',
	    text: gettext('Publish folder…'),
	    disabled: true,
	    selModel: () => me.getSelectionModel(),
	    handler: function (b, e, rec) {
		let volid = rec?.data?.volid || '';
		if (!volid.match(/:backup\/vm\//)) {
		    Ext.Msg.alert(
			gettext('Error'),
			gettext('Select a PBS backup (storage:backup/vm/...).'),
		    );
		    return;
		}
		// VLAN e IP são resolvidos no servidor (Restore.pm); o diálogo
		// não lê a config (evita exigir Sys.Audit de quem só publica).
		Ext.create('MM.window.RestorePublish', { autoShow: true, volid });
	    },
	});
	me.callParent(arguments);
    },
});
