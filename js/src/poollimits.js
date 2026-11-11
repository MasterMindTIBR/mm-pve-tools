/* Módulo poollimits — aba Limites no painel nativo de pools do PVE. */

Ext.define('MM.PoolLimits', {
    singleton: true,

    path: function (pool) {
	return `/nodes/localhost/mm-tools/poollimits/${encodeURIComponent(pool)}`;
    },

    number: function (value, digits) {
	let number = Number(value);
	if (!Number.isFinite(number)) { return MM.t('pool.unavailable'); }
	return number.toFixed(digits).replace(/\.0+$/, '').replace(/(\.\d*?)0+$/, '$1');
    },

    memory: function (mib) {
	let value = Number(mib);
	if (!Number.isFinite(value)) { return MM.t('pool.unavailable'); }
	    return value >= 1024 && value % 1024 === 0
		? `${MM.PoolLimits.number(value / 1024, 2)} ${MM.t('pool.gib')}`
		: `${MM.PoolLimits.number(value, 0)} ${MM.t('pool.mib')}`;
    },

    disk: function (bytes) {
	let value = Number(bytes);
	if (!Number.isFinite(value)) { return MM.t('pool.unavailable'); }
	return `${MM.PoolLimits.number(value / (1024 ** 3), 2)} ${MM.t('pool.gib')}`;
    },

    limits: function (data) {
	let limits = data?.limits || {};
	return {
	    cpu: limits.cpu || { enabled: false },
	    memory_mib: limits.memory_mib || { enabled: false },
	    disk_total_gib: limits.disk_total_gib || { enabled: false },
	    disk_storage: limits.disk_storage || { enabled: false, limits: {} },
	};
    },

    modeLabel: function (mode) {
	return mode === 'running' ? MM.t('pool.running') : MM.t('pool.allocated');
    },

    install: function () {
	if (!Ext.ClassManager || typeof Ext.ClassManager.get !== 'function'
	    || !Ext.ClassManager.get('PVE.pool.Config')) {
	    return;
	}

	Ext.define('MM.override.PoolConfig', {
	    override: 'PVE.pool.Config',

	    initComponent: function () {
		let me = this;
		let pool = me.pveSelNode?.data?.pool;
		this.callParent(arguments);
		if (!pool || !MM.Api) { return; }
		MM.Api.request({
		    url: MM.PoolLimits.path(pool),
		    success: (res) => {
			let poolData = res.data || {};
			if (!poolData.module_enabled || me.destroyed || me.isDestroyed) { return; }
			me.add({ xtype: 'mmPoolLimits', itemId: 'poollimits', pool, poolData });
		    },
		    // Pool.Audit is checked by the server. A pool the user cannot audit
		    // keeps the native PVE panel intact and simply has no extra tab.
		    failure: () => undefined,
		});
	    },
	});
    },
});

Ext.define('MM.panel.PoolLimits', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.mmPoolLimits',
    config: { pool: null, poolData: null },
	title: MM.t('tabs.poollimits'),
    iconCls: 'fa fa-fw fa-tachometer',
    layout: { type: 'vbox', align: 'stretch' },
    scrollable: true,

    initComponent: function () {
	let me = this;
	me.poolData = me.poolData || {};
	me.digest = me.poolData.digest || '';
	me.storageEditors = {};
	let warning = Ext.create('Ext.form.field.Display', {
	    itemId: 'accounting-warning', hidden: true, cls: 'mm-poollimits-warning',
	    fieldLabel: MM.t('pool.warning'),
	});
	let modeDisplay = Ext.create('Ext.form.field.Display', {
	    itemId: 'mode-display', fieldLabel: MM.t('pool.mode'), value: MM.t('pool.allocated'),
	});
	let grid = Ext.create('Ext.grid.Panel', {
	    itemId: 'usage-grid', flex: 0, minHeight: 190,
	    store: { fields: ['resource', 'value'], data: [] },
	    columns: [
		{ text: MM.t('pool.resource'), dataIndex: 'resource', flex: 1 },
		{ text: MM.t('pool.usage_limit'), dataIndex: 'value', flex: 1 },
	    ],
	});
	let limits = MM.PoolLimits.limits(me.poolData);
	let mode = Ext.create('Proxmox.form.KVComboBox', {
	    itemId: 'mode', fieldLabel: MM.t('pool.mode'),
	    comboItems: [['allocated', MM.t('pool.allocated')], ['running', MM.t('pool.running')]],
	    value: me.poolData.mode || 'allocated',
	});
	let storageContainer = Ext.create('Ext.container.Container', {
	    itemId: 'storage-editors', layout: { type: 'vbox', align: 'stretch' },
	});
	let storageSelector = Ext.create('Ext.form.field.ComboBox', {
	    itemId: 'storage-selector', fieldLabel: MM.t('pool.storage'), width: 300,
	    store: { fields: ['storage'], data: [] }, displayField: 'storage',
	    valueField: 'storage', queryMode: 'local', editable: false,
	});

	let removeStorage = function (storage) {
	    let editor = me.storageEditors[storage];
	    if (!editor) { return; }
	    storageContainer.remove(editor.row, true);
	    delete me.storageEditors[storage];
	};
	let addStorage = function (storage, max) {
	    if (!storage || me.storageEditors[storage]) { return; }
	    let maxField = Ext.create('Ext.form.field.Number', {
		itemId: `storage-${storage}-max`, fieldLabel: MM.t('pool.storage_max', { storage }),
		minValue: 1, allowDecimals: false, value: max, width: 260,
	    });
	    let removeButton = Ext.create('Ext.button.Button', {
		itemId: `storage-${storage}-remove`, text: MM.t('pool.remove'),
		handler: () => removeStorage(storage),
	    });
	    let row = Ext.create('Ext.container.Container', {
		layout: { type: 'hbox', align: 'middle' },
		items: [maxField, removeButton],
	    });
	    me.storageEditors[storage] = { max: maxField, row };
	    storageContainer.add(row);
    };
	let storageNames = function (data) {
	    let currentLimits = MM.PoolLimits.limits(data);
	    let usage = data?.usage?.disk_storage_bytes || {};
	    return [...new Set([
		...Object.keys(currentLimits.disk_storage.limits || {}), ...Object.keys(usage),
	    ])].sort();
    };
	let syncStorageEditors = function (data) {
	    let currentLimits = MM.PoolLimits.limits(data);
	    let configuredStorages = Object.keys(currentLimits.disk_storage.limits || {});
	    Object.keys(me.storageEditors).filter((storage) => !configuredStorages.includes(storage))
		.forEach(removeStorage);
	    configuredStorages.forEach((storage) => {
		if (!me.storageEditors[storage]) {
		    addStorage(storage, currentLimits.disk_storage.limits[storage]);
		}
		let editor = me.storageEditors[storage];
		editor.max.setValue(currentLimits.disk_storage.limits[storage]);
	    });
	};
	me.addStorage = addStorage;
	me.removeStorage = removeStorage;

	let editor;
	if (me.poolData.can_edit) {
	    let cpuEnabled = Ext.create('Ext.form.field.Checkbox', {
		itemId: 'cpu-enabled', boxLabel: MM.t('pool.cpu_limit'),
		checked: !!limits.cpu.enabled,
	    });
	    let cpuMax = Ext.create('Ext.form.field.Number', {
		itemId: 'cpu-max', fieldLabel: MM.t('pool.cpu_max'), minValue: 1,
		allowDecimals: false, value: limits.cpu.max,
	    });
	    let memoryEnabled = Ext.create('Ext.form.field.Checkbox', {
		itemId: 'memory-enabled', boxLabel: MM.t('pool.ram_limit'),
		checked: !!limits.memory_mib.enabled,
	    });
	    let memoryMax = Ext.create('Ext.form.field.Number', {
		itemId: 'memory-max', fieldLabel: MM.t('pool.ram_max'), minValue: 1,
		allowDecimals: false, value: limits.memory_mib.max,
	    });
	    let diskTotalEnabled = Ext.create('Ext.form.field.Checkbox', {
		itemId: 'disk-total-enabled', boxLabel: MM.t('pool.disk_limit'),
		checked: !!limits.disk_total_gib.enabled,
	    });
	    let diskTotalMax = Ext.create('Ext.form.field.Number', {
		itemId: 'disk-total-max', fieldLabel: MM.t('pool.disk_max'), minValue: 1,
		allowDecimals: false, value: limits.disk_total_gib.max,
	    });
	    let addButton = Ext.create('Ext.button.Button', {
		itemId: 'add-storage', text: MM.t('pool.add_storage'),
		handler: () => {
		    addStorage(storageSelector.getValue());
		    storageSelector.reset();
		},
	    });
	    let diskStorageEnabled = Ext.create('Ext.form.field.Checkbox', {
		itemId: 'disk-storage-enabled', boxLabel: MM.t('pool.storage_limits'),
		checked: !!limits.disk_storage.enabled,
	    });
	    let storageAdd = Ext.create('Ext.container.Container', {
		layout: { type: 'hbox', align: 'middle' },
		items: [storageSelector, addButton],
	    });
	    editor = Ext.create('Ext.form.FieldSet', {
		title: MM.t('pool.edit_limits'), itemId: 'editor', flex: 0,
		items: [mode, cpuEnabled, cpuMax, memoryEnabled, memoryMax,
		    diskTotalEnabled, diskTotalMax, diskStorageEnabled, storageAdd, storageContainer],
	    });
	}

	me.renderData = function (data) {
	    let current = data || {};
	    me.poolData = current;
	    me.digest = current.digest || me.digest || '';
	    let currentLimits = MM.PoolLimits.limits(current);
	    let usage = current.usage || {};
	    let errors = current.errors || [];
	    let diskErrors = current.disk_errors || [];
	    let pair = (used, limit, usedText, limitText, unavailable) =>
		`${unavailable ? MM.t('pool.unavailable') : usedText(used)} × ${limit.enabled ? limitText(limit.max) : MM.t('pool.disabled')}`;
	    let rows = [
		{ resource: MM.t('pool.cpu'), value: pair(usage.cpu, currentLimits.cpu, MM.PoolLimits.number,
		    (value) => `${MM.PoolLimits.number(value, 0)} ${MM.t('pool.vcpu')}`, errors.length > 0) },
		{ resource: MM.t('pool.ram'), value: pair(usage.memory_mib, currentLimits.memory_mib,
		    MM.PoolLimits.memory, MM.PoolLimits.memory, errors.length > 0) },
		{ resource: MM.t('pool.total_disk'), value: pair(usage.disk_total_bytes, currentLimits.disk_total_gib,
		    MM.PoolLimits.disk, (value) => `${MM.PoolLimits.number(value, 2)} ${MM.t('pool.gib')}`, diskErrors.length > 0) },
	    ];
	    storageNames(current).forEach((storage) => {
		let hasLimit = Object.prototype.hasOwnProperty.call(
		    currentLimits.disk_storage.limits || {}, storage,
		);
		let storeUsage = usage.disk_storage_bytes?.[storage];
		rows.push({ resource: MM.t('pool.disk_storage', { storage }),
		    value: pair(storeUsage, { enabled: !!currentLimits.disk_storage.enabled && hasLimit,
			max: currentLimits.disk_storage.limits?.[storage] }, MM.PoolLimits.disk,
			(value) => `${MM.PoolLimits.number(value, 2)} ${MM.t('pool.gib')}`, diskErrors.length > 0) });
	    });
	    grid.getStore().setData(rows);
	    modeDisplay.setValue(MM.PoolLimits.modeLabel(current.mode));
	    let warningLines = [
		...errors.map((error) => `${MM.t('pool.resources_prefix')}: ${error}`),
		...diskErrors.map((error) => `${MM.t('pool.disk_prefix')}: ${error}`),
	    ];
	    warning.setVisible(warningLines.length > 0);
		warning.setValue(warningLines.length ? `⚠ ${MM.t('pool.accounting_unavailable')}: ${warningLines.join('; ')}` : '');
	    if (me.poolData.can_edit && editor) {
		mode.setValue(current.mode || 'allocated');
		let cpu = me.down('#cpu-enabled');
		let cpuMax = me.down('#cpu-max');
		let memory = me.down('#memory-enabled');
		let memoryMax = me.down('#memory-max');
		let diskTotal = me.down('#disk-total-enabled');
		let diskTotalMax = me.down('#disk-total-max');
		let diskStorage = me.down('#disk-storage-enabled');
		cpu.setValue(!!currentLimits.cpu.enabled); cpuMax.setValue(currentLimits.cpu.max);
		memory.setValue(!!currentLimits.memory_mib.enabled); memoryMax.setValue(currentLimits.memory_mib.max);
		diskTotal.setValue(!!currentLimits.disk_total_gib.enabled);
		diskTotalMax.setValue(currentLimits.disk_total_gib.max);
		diskStorage.setValue(!!currentLimits.disk_storage.enabled);
		syncStorageEditors(current);
	    }
	};

	me.loadStorages = function () {
	    MM.Api.request({
		url: '/storage',
		success: (res) => {
		    let storages = (res.data || []).filter((item) => item.storage)
			.map((item) => ({ storage: item.storage }));
		    storageSelector.getStore().setData(storages);
		},
		failure: () => undefined,
	    });
	};
	me.reload = function () {
	    MM.Api.request({
		url: MM.PoolLimits.path(me.pool),
		success: (res) => me.renderData(res.data || {}),
		failure: (msg) => { warning.setVisible(true); warning.setValue(`⚠ ${msg}`); },
	    });
	};
	me.save = function () {
	    let get = (id) => me.down(`#${id}`);
	    let resource = (enabled, max) => {
		let value = { enabled: !!enabled.getValue() };
		if (value.enabled) { value.max = Number(max.getValue()); }
		return value;
	    };
	    let storageLimits = {};
	    Object.keys(me.storageEditors).forEach((storage) => {
		let row = me.storageEditors[storage];
		storageLimits[storage] = Number(row.max.getValue());
	    });
	    let body = {
		mode: mode.getValue(),
		cpu: resource(get('cpu-enabled'), get('cpu-max')),
		memory_mib: resource(get('memory-enabled'), get('memory-max')),
		disk_total_gib: resource(get('disk-total-enabled'), get('disk-total-max')),
		disk_storage: { enabled: !!get('disk-storage-enabled').getValue(), limits: storageLimits },
		digest: me.digest,
	    };
	    MM.Api.request({
		method: 'PUT', url: MM.PoolLimits.path(me.pool), jsonData: body,
		success: () => me.reload(),
		failure: (msg) => Ext.Msg.alert(MM.t('common.error'), msg),
	    });
	};

	let toolbar = me.poolData.can_edit ? [{
	    text: MM.t('pool.save'), itemId: 'save', iconCls: 'fa fa-fw fa-check', handler: () => me.save(),
	}] : [];
	Ext.apply(me, {
	    tbar: toolbar,
	    items: [modeDisplay, warning, grid, editor].filter(Boolean),
	    listeners: { activate: () => me.reload() },
	});
	me.callParent();
	me.renderData(me.poolData);
	if (me.poolData.can_edit) { me.loadStorages(); }
    },
});

MM.PoolLimits.install();
