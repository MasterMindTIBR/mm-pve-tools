/* Módulo ui — padrão de console por tipo e remoção somente do popup de
 * assinatura. O arquivo mm-ui.json chega antes do login; a preferência por
 * usuário é carregada depois que o PVE fixa o principal autenticado. */

Ext.define('MM.Ui', {
    singleton: true,

    viewers: ['default', 'html5', 'xtermjs', 'vv'],
    cluster: { qemu: 'default', lxc: 'default' },
    user: {},
    hideSubscriptionPopup: false,
    staticReady: false,
    userReady: false,
    pendingChecked: [],
    incompatibilities: [],
    originalCheckedCommand: null,

    typeKey: function (type) {
	return type === 'kvm' ? 'qemu' : type;
    },

    validViewer: function (value) {
	return this.viewers.includes(value);
    },

    viewerFor: function (type) {
	let key = this.typeKey(type);
	let user = this.user?.[key];
	let cluster = this.cluster?.[key];
	return user === 'cluster' ? (this.validViewer(cluster) ? cluster : 'default')
	    : this.validViewer(user)
	    ? user : (this.validViewer(cluster) ? cluster : 'default');
    },

    preferredValue: function (type) {
	let key = this.typeKey(type);
	return this.user?.[key] || 'cluster';
    },

    recordIncompatibility: function (name, detail) {
	let msg = `MM.ui: incompatibilidade em ${name}: ${detail}`;
	if (!this.incompatibilities.includes(msg)) { this.incompatibilities.push(msg); }
	// eslint-disable-next-line no-console
	console.warn(msg);
    },

    recognized: function (target, name, markers) {
	let fn = target?.[name];
	if (typeof fn !== 'function') {
	    this.recordIncompatibility(name, 'função ausente');
	    return null;
	}
	let source = String(fn);
	if (!markers.every((marker) => source.includes(marker))) {
	    this.recordIncompatibility(name, 'assinatura upstream não reconhecida');
	    return null;
	}
	return fn;
    },

    allowed: function (consoles) {
	if (consoles === true) { return { spice: true, xtermjs: true }; }
	if (consoles && typeof consoles === 'object') {
	    return { spice: !!consoles.spice, xtermjs: !!consoles.xtermjs };
}
	return { spice: false, xtermjs: false };
    },

    fallbackViewer: function (consoles, desired, original, type) {
	if (desired === 'default') { return original(consoles, type); }
	let allow = this.allowed(consoles);
	if (desired === 'vv') { return allow.spice ? 'vv' : (allow.xtermjs ? 'xtermjs' : 'html5'); }
	if (desired === 'xtermjs') {
	    return allow.xtermjs ? 'xtermjs' : (allow.spice ? 'vv' : 'html5');
}
	if (desired === 'html5') { return 'html5'; }
	return original(consoles, type);
    },

    loadUser: function () {
	let me = this;
	if (!MM.Api) { return; }
	MM.Api.request({
	    url: '/nodes/localhost/mm-tools/ui/preference',
	    success: function (res) {
		let data = res.data || {};
		me.user = data.preference || {};
		me.userReady = true;
		if (me.onUserLoaded) { me.onUserLoaded(data); }
	    },
	    failure: function (msg) {
		me.user = {};
		me.userReady = true;
		me.recordIncompatibility('preferência de usuário', msg);
	    },
	});
    },

    saveUser: function (type, value, field) {
	let me = this;
	let key = me.typeKey(type);
	let body = {};
	body[key] = value || 'cluster';
	MM.Api.request({
	    method: 'PUT',
	    url: '/nodes/localhost/mm-tools/ui/preference',
	    jsonData: body,
	    success: function (res) {
		let data = res.data || {};
		me.user = data.preference || {};
		me.userReady = true;
		if (field) { field.setValue(me.preferredValue(type)); }
	    },
	    failure: function (msg) {
		if (field) { field.setValue(me.preferredValue(type)); }
		Ext.Msg.alert('Erro', msg);
	    },
	});
    },

    flushChecked: function () {
	let pending = this.pendingChecked.splice(0);
	let original = this.originalCheckedCommand;
	pending.forEach((callback) => {
	    if (this.hideSubscriptionPopup) {
		if (typeof callback === 'function') { callback(); }
	    } else if (original) {
		original.call(Proxmox.Utils, callback);
	    }
});
    },

    loadStatic: function () {
	let me = this;
	let controller = typeof AbortController === 'function' ? new AbortController() : null;
	let timer;
	let request = fetch('/pve2/js/mm-ui.json?v=' + Date.now(), {
	    cache: 'no-store', ...(controller ? { signal: controller.signal } : {}),
	});
	let deadline = new Promise((resolve, reject) => {
	    timer = setTimeout(() => {
		if (controller) { controller.abort(); }
		reject(new Error('mm-ui.json timeout'));
	    }, 3000);
	});
	Promise.race([request, deadline])
	    .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
	    .then((cfg) => me.applyStatic(cfg))
	    .catch(() => {
		me.cluster = { qemu: 'default', lxc: 'default' };
		me.hideSubscriptionPopup = false;
		me.staticReady = true;
		me.flushChecked();
	    })
	    .finally(() => clearTimeout(timer));
    },

    applyStatic: function (cfg) {
	let consoleCfg = cfg?.console || {};
	this.cluster = {
	    qemu: this.validViewer(consoleCfg.qemu) ? consoleCfg.qemu : 'default',
	    lxc: this.validViewer(consoleCfg.lxc) ? consoleCfg.lxc : 'default',
	};
	this.hideSubscriptionPopup = !!cfg?.hide_subscription_popup;
	this.staticReady = true;
	this.flushChecked();
    },

    installDefaultViewer: function () {
	let me = this;
	if (!PVE?.Utils) { me.recordIncompatibility('PVE.Utils.defaultViewer', 'PVE.Utils ausente'); return; }
	let original = me.recognized(PVE.Utils, 'defaultViewer', [
	    'allowSpice', 'allowXtermjs', 'PVE.UIOptions.options.console',
	]);
	if (!original) { return; }
	PVE.Utils.defaultViewer = function (consoles, type) {
	    return me.fallbackViewer(consoles, me.viewerFor(type), original, type);
};
    },

    installCheckedCommand: function () {
	let me = this;
	if (!Proxmox?.Utils) { me.recordIncompatibility('Proxmox.Utils.checked_command', 'Proxmox.Utils ausente'); return; }
	let original = me.recognized(Proxmox.Utils, 'checked_command', [
	    'subscription', 'No valid subscription', 'API2Request',
]);
	if (!original) { return; }
	me.originalCheckedCommand = original;
	Proxmox.Utils.checked_command = function (callback) {
	    if (!me.staticReady) { me.pendingChecked.push(callback); return; }
	    if (me.hideSubscriptionPopup) {
		if (typeof callback === 'function') { callback(); }
	    } else {
		original.call(Proxmox.Utils, callback);
    }
};
    },

    installWorkspace: function () {
	let me = this;
	if (!PVE?.Workspace?.prototype) {
	    me.recordIncompatibility('PVE.Workspace.updateLoginData', 'classe ausente');
	    return;
}
	let original = me.recognized(PVE.Workspace.prototype, 'updateLoginData', [
	    'setAuthData', 'onLogin',
]);
	if (!original) { return; }
	Ext.define('MM.override.WorkspaceUi', {
	    override: 'PVE.Workspace',
	    updateLoginData: function (loginData) {
		this.callParent(arguments);
		if (loginData) { MM.Ui.loadUser(); }
	    },
});
    },

    installEmbeddedConsole: function () {
	let me = this;
	if (!PVE?.noVncConsole?.prototype) {
	    me.recordIncompatibility('PVE.noVncConsole.initComponent', 'classe ausente');
	    return;
}
	let original = me.recognized(PVE.noVncConsole.prototype, 'initComponent', [
	    'me.xtermjs', 'callParent', 'consoleType',
]);
	if (!original) { return; }
	Ext.define('MM.override.EmbeddedConsoleUi', {
	    override: 'PVE.noVncConsole',
	    initComponent: function () {
		let me2 = this;
		let desired = MM.Ui.viewerFor(me2.consoleType);
		me2.__mmViewer = desired;
		if (me2.consoleType === 'kvm') {
		    let serialKnown = me2.xtermjs === true || me2.serial === true || me2.hasSerial === true;
		    me2.xtermjs = desired === 'xtermjs' && serialKnown;
		} else if (me2.consoleType === 'lxc') {
		    me2.xtermjs = desired !== 'html5';
		}
		this.callParent(arguments);
    },
});
    },

    installSettings: function () {
	let me = this;
	if (!PVE?.window?.Settings?.prototype) {
	    me.recordIncompatibility('PVE.window.Settings', 'classe ausente');
	    return;
}
	// PVE.window.Settings não define initComponent (a lógica fica no
	// controller); o override confere a peça que usa ao montar a janela.
	Ext.define('MM.override.SettingsUi', {
	    override: 'PVE.window.Settings',
	    initComponent: function () {
		this.callParent(arguments);
		let me2 = this;
		// Âncora: o formulário do xterm.js (existe no 9.2.24 e no 9.2.25; o
		// grupo de escala do noVNC mudou entre eles). O fieldset próprio entra
		// na mesma coluna, depois dos fieldsets do PVE.
		let column = me2.down('[reference=xtermform]')?.up('fieldset')?.ownerCt;
		if (!column) {
		    MM.Ui.recordIncompatibility('PVE.window.Settings', 'formulário do xterm.js ausente');
		    return;
		}
		let qemu = Ext.create('Proxmox.form.KVComboBox', {
		    fieldLabel: 'Console QEMU', reference: 'mmUiQemu',
		    comboItems: [['cluster', 'Padrão do cluster'], ['default', 'Padrão do PVE'],
			['html5', 'HTML5 (noVNC)'], ['xtermjs', 'xterm.js'], ['vv', 'SPICE (remote-viewer)']],
		});
		let lxc = Ext.create('Proxmox.form.KVComboBox', {
		    fieldLabel: 'Console LXC', reference: 'mmUiLxc',
		    comboItems: [['cluster', 'Padrão do cluster'], ['default', 'Padrão do PVE'],
			['html5', 'HTML5 (noVNC)'], ['xtermjs', 'xterm.js'], ['vv', 'SPICE (remote-viewer)']],
		});
		column.add({ xtype: 'fieldset', title: 'Console padrão (MasterMind)', items: [qemu, lxc] });
		let sync = function () {
		    qemu.suspendEvents(); qemu.setValue(MM.Ui.preferredValue('qemu')); qemu.resumeEvents();
		    lxc.suspendEvents(); lxc.setValue(MM.Ui.preferredValue('lxc')); lxc.resumeEvents();
		};
		qemu.on('change', (field, value) => MM.Ui.saveUser('qemu', value, field));
		lxc.on('change', (field, value) => MM.Ui.saveUser('lxc', value, field));
		sync();
		MM.Ui.onUserLoaded = sync;
	    },
});
    },

    install: function () {
	this.installDefaultViewer();
	this.installCheckedCommand();
	this.installWorkspace();
	this.installEmbeddedConsole();
	this.installSettings();
    },
});

MM.Ui.install();
MM.Ui.loadStatic();

/* ------------------------- Aba Interface ------------------------- */

Ext.define('MM.panel.Ui', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.mmPanelUi',
    title: 'Interface',
    layout: 'fit',

    initComponent: function () {
	let me = this;
	let qemu = Ext.create('Proxmox.form.KVComboBox', {
	    fieldLabel: 'Console QEMU', comboItems: [['default', 'Padrão do PVE'],
		['html5', 'HTML5 (noVNC)'], ['xtermjs', 'xterm.js'], ['vv', 'SPICE (remote-viewer)']],
	});
	let lxc = Ext.create('Proxmox.form.KVComboBox', {
	    fieldLabel: 'Console LXC', comboItems: [['default', 'Padrão do PVE'],
		['html5', 'HTML5 (noVNC)'], ['xtermjs', 'xterm.js'], ['vv', 'SPICE (remote-viewer)']],
	});
	let hide = Ext.create('Ext.form.field.Checkbox', {
	    fieldLabel: 'Assinatura', boxLabel: 'Remover somente o popup “No valid subscription”',
	});
	let status = Ext.create('Ext.form.field.Display', { itemId: 'ui-status', value: '—' });
	me.reload = function () {
	    MM.Api.request({
		url: '/nodes/localhost/mm-tools/config',
		success: (res) => {
		    let data = res.data || {};
		    let ui = data.config?.ui || {};
		    let c = ui.console || {};
		    qemu.setValue(c.qemu || 'default'); lxc.setValue(c.lxc || 'default');
		    hide.setValue(!!ui.hide_subscription_popup); me.digest = data.digest || '';
		},
	    });
	    MM.Api.request({
		url: '/nodes/localhost/mm-tools/status',
		success: (res) => {
		    let c = res.data?.modules?.ui?.check;
		    status.setValue(c?.ok ? 'OK: símbolos compatíveis' : (c?.note || 'Incompatibilidade detectada'));
		},
	    });
	};
	let save = function () {
	    let value = JSON.stringify({
		console: { qemu: qemu.getValue(), lxc: lxc.getValue() },
		hide_subscription_popup: !!hide.getValue(),
	    });
	    MM.Api.request({
		method: 'PUT', url: '/nodes/localhost/mm-tools/config/ui',
		params: { value, digest: me.digest },
		success: () => { me.reload(); MM.applyAll(); },
		failure: (msg) => Ext.Msg.alert('Erro', msg),
	    });
	};
	Ext.apply(me, {
	    items: [{ xtype: 'form', bodyPadding: 10, border: false, items: [
		{ xtype: 'displayfield', value: 'Padrões do cluster; a preferência do usuário é definida em “My Settings”.' },
		qemu, lxc, hide, status,
	    ], buttons: [{ text: 'Salvar', iconCls: 'fa fa-fw fa-check', handler: save },
		{ text: 'Recarregar', iconCls: 'fa fa-fw fa-refresh', handler: () => me.reload() }]}],
	    listeners: { activate: () => me.reload() },
	});
	me.callParent();
	me.reload();
    },
});

MM.registerTab({ xtype: 'mmPanelUi', title: 'Interface' });
