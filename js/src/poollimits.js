/* Módulo poollimits — aba Limites no painel nativo de pools do PVE. */

Ext.define('MM.PoolLimits', {
    singleton: true,

    path: function (pool) {
	return `/nodes/localhost/mm-tools/poollimits/${encodeURIComponent(pool)}`;
    },

    number: function (value, digits) {
	let number = Number(value);
	if (!Number.isFinite(number)) { return 'indisponível'; }
	return number.toFixed(digits).replace(/\.0+$/, '').replace(/(\.\d*?)0+$/, '$1');
    },

    memory: function (mib) {
	let value = Number(mib);
	if (!Number.isFinite(value)) { return 'indisponível'; }
	return value >= 1024 && value % 1024 === 0
	    ? `${MM.PoolLimits.number(value / 1024, 2)} GiB`
	    : `${MM.PoolLimits.number(value, 0)} MiB`;
    },

    disk: function (bytes) {
	let value = Number(bytes);
	if (!Number.isFinite(value)) { return 'indisponível'; }
	return `${MM.PoolLimits.number(value / (1024 ** 3), 2)} GiB`;
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
	return mode === 'running' ? 'Ligado' : 'Alocado';
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
    title: 'Limites',
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
	    fieldLabel: 'Aviso',
	});
	let modeDisplay = Ext.create('Ext.form.field.Display', {
	    itemId: 'mode-display', fieldLabel: 'Modo', value: 'Alocado',
	});
	let grid = Ext.create('Ext.grid.Panel', {
	    itemId: 'usage-grid', flex: 0, minHeight: 190,
	    store: { fields: ['resource', 'value'], data: [] },
	    columns: [
		{ text: 'Recurso', dataIndex: 'resource', flex: 1 },
		{ text: 'Uso × limite', dataIndex: 'value', flex: 1 },
	    ],
	});
	let limits = MM.PoolLimits.limits(me.poolData);
	let mode = Ext.create('Proxmox.form.KVComboBox', {
	    itemId: 'mode', fieldLabel: 'Modo',
	    comboItems: [['allocated', 'Alocado'], ['running', 'Ligado']],
	    value: me.poolData.mode || 'allocated',
	});
	let storageContainer = Ext.create('Ext.container.Container', {
	    itemId: 'storage-editors', layout: { type: 'vbox', align: 'stretch' },
	});
	let storageSelector = Ext.create('Ext.form.field.ComboBox', {
	    itemId: 'storage-selector', fieldLabel: 'Storage', width: 300,
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
		itemId: `storage-${storage}-max`, fieldLabel: `${storage} máximo (GiB)`,
		minValue: 1, allowDecimals: false, value: max, width: 260,
	    });
	    let removeButton = Ext.create('Ext.button.Button', {
		itemId: `storage-${storage}-remove`, text: 'Remover',
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
		itemId: 'cpu-enabled', boxLabel: 'Limite de vCPU ligado',
		checked: !!limits.cpu.enabled,
	    });
	    let cpuMax = Ext.create('Ext.form.field.Number', {
		itemId: 'cpu-max', fieldLabel: 'vCPU máximo', minValue: 1,
		allowDecimals: false, value: limits.cpu.max,
	    });
	    let memoryEnabled = Ext.create('Ext.form.field.Checkbox', {
		itemId: 'memory-enabled', boxLabel: 'Limite de RAM ligado',
		checked: !!limits.memory_mib.enabled,
	    });
	    let memoryMax = Ext.create('Ext.form.field.Number', {
		itemId: 'memory-max', fieldLabel: 'RAM máxima (MiB)', minValue: 1,
		allowDecimals: false, value: limits.memory_mib.max,
	    });
	    let diskTotalEnabled = Ext.create('Ext.form.field.Checkbox', {
		itemId: 'disk-total-enabled', boxLabel: 'Limite de disco total ligado',
		checked: !!limits.disk_total_gib.enabled,
	    });
	    let diskTotalMax = Ext.create('Ext.form.field.Number', {
		itemId: 'disk-total-max', fieldLabel: 'Disco total máximo (GiB)', minValue: 1,
		allowDecimals: false, value: limits.disk_total_gib.max,
	    });
	    let addButton = Ext.create('Ext.button.Button', {
		itemId: 'add-storage', text: 'Adicionar storage',
		handler: () => {
		    addStorage(storageSelector.getValue());
		    storageSelector.reset();
		},
	    });
	    let diskStorageEnabled = Ext.create('Ext.form.field.Checkbox', {
		itemId: 'disk-storage-enabled', boxLabel: 'Limites por storage ligados',
		checked: !!limits.disk_storage.enabled,
	    });
	    let storageAdd = Ext.create('Ext.container.Container', {
		layout: { type: 'hbox', align: 'middle' },
		items: [storageSelector, addButton],
	    });
	    editor = Ext.create('Ext.form.FieldSet', {
		title: 'Editar limites', itemId: 'editor', flex: 0,
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
		`${unavailable ? 'indisponível' : usedText(used)} × ${limit.enabled ? limitText(limit.max) : 'desligado'}`;
	    let rows = [
		{ resource: 'vCPU', value: pair(usage.cpu, currentLimits.cpu, MM.PoolLimits.number,
		    (value) => `${MM.PoolLimits.number(value, 0)} vCPU`, errors.length > 0) },
		{ resource: 'RAM', value: pair(usage.memory_mib, currentLimits.memory_mib,
		    MM.PoolLimits.memory, MM.PoolLimits.memory, errors.length > 0) },
		{ resource: 'Disco total', value: pair(usage.disk_total_bytes, currentLimits.disk_total_gib,
		    MM.PoolLimits.disk, (value) => `${MM.PoolLimits.number(value, 2)} GiB`, diskErrors.length > 0) },
	    ];
	    storageNames(current).forEach((storage) => {
		let hasLimit = Object.prototype.hasOwnProperty.call(
		    currentLimits.disk_storage.limits || {}, storage,
		);
		let storeUsage = usage.disk_storage_bytes?.[storage];
		rows.push({ resource: `Disco — ${storage}`,
		    value: pair(storeUsage, { enabled: !!currentLimits.disk_storage.enabled && hasLimit,
			max: currentLimits.disk_storage.limits?.[storage] }, MM.PoolLimits.disk,
			(value) => `${MM.PoolLimits.number(value, 2)} GiB`, diskErrors.length > 0) });
	    });
	    grid.getStore().setData(rows);
	    modeDisplay.setValue(MM.PoolLimits.modeLabel(current.mode));
	    let warningLines = [
		...errors.map((error) => `Recursos: ${error}`),
		...diskErrors.map((error) => `Disco: ${error}`),
	    ];
	    warning.setVisible(warningLines.length > 0);
	    warning.setValue(warningLines.length ? `⚠ Contabilidade indisponível: ${warningLines.join('; ')}` : '');
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
		failure: (msg) => Ext.Msg.alert('Erro', msg),
	    });
	};

	let toolbar = me.poolData.can_edit ? [{
	    text: 'Salvar', itemId: 'save', iconCls: 'fa fa-fw fa-check', handler: () => me.save(),
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
