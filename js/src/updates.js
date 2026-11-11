/* Dashboard de updates dos nodes. A confirmação perigosa também é repetida
 * no backend; os campos daqui só tornam o fluxo explícito para o operador. */
Ext.define('MM.Updates', {
    singleton: true,

    path: function (node, suffix) {
	return `/nodes/${encodeURIComponent(node)}/mm-tools/updates/${suffix}`;
    },

    tripleReboot: function (record, done) {
	if (!record.get('reboot_suggested')) { return; }
	let node = record.get('node');
	let guests = record.get('reboot_context')?.running_guests || [];
	let ha = record.get('reboot_context')?.ha;
	let details = guests.length
		? `VMs/CTs ligadas: ${guests.map((g) => `${g.type}/${g.vmid}`).join(', ')}`
		: 'Nenhuma VM/CT ligada neste node.';
	if (ha) { details += `\nHA: ${JSON.stringify(ha)}`; }
	let understood = Ext.create('Ext.form.field.Checkbox', {
		boxLabel: 'Entendo que o node será reiniciado e as VMs/CTs podem ficar indisponíveis.',
	});
	let name = Ext.create('Ext.form.field.Text', { fieldLabel: 'Digite o nome do node', allowBlank: false });
	let win = Ext.create('Ext.window.Window', {
		title: `Confirmar reinício de ${node}`, modal: true, width: 560, bodyPadding: 12,
		items: [{ xtype: 'displayfield', value: MM.Utils.html(details).replace(/\n/g, '<br>') }, understood, name],
		buttons: [{ text: 'Cancelar', handler: () => win.close() }, {
			text: 'Reiniciar', itemId: 'mm-confirm-reboot', disabled: true,
			handler: function () {
				if (!understood.getValue() || name.getValue() !== node) { return; }
				win.close(); done(node);
			},
		}],
	});
	let button = win.down('#mm-confirm-reboot');
	let sync = () => button.setDisabled(!understood.getValue() || name.getValue() !== node);
	understood.on('change', sync); name.on('change', sync);
	win.show();
    },
});

Ext.define('MM.panel.Updates', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.mmPanelUpdates',
    title: 'Updates',

    initComponent: function () {
	let me = this;
	let mode = Ext.create('Proxmox.form.KVComboBox', {
		width: 150, comboItems: [['sequential', 'Sequencial'], ['parallel', 'Paralelo']], value: 'sequential',
	});
	let selected = () => me.getSelection().map((r) => r.get('node'));
	let reloadRow = function (record) {
		let node = record.get('node');
		if (!record.get('online')) { record.set({ last_result: 'offline' }); return; }
		MM.Api.request({ url: MM.Updates.path(node, 'status'),
		success: (res) => {
			let data = res.data || {};
			data.last_result = data.results?.[0]?.state || (data.job?.state || '—');
			data.orchestrator_lost = !!data.bulk?.orchestrator_lost;
			record.set(Ext.apply({ node }, data));
		},
			failure: (msg) => record.set({ last_result: `erro: ${msg}`, online: false }),
		});
	};
	me.reload = function () {
		MM.Api.request({ url: '/cluster/status', success: (res) => {
			let nodes = (res.data || []).filter((e) => e.type === 'node');
			me.getStore().setData(nodes.map((n) => ({ node: n.name, online: !!n.online, pending: [],
				reboot_suggested: false, job: null, last_result: n.online ? 'carregando…' : 'offline' })));
			nodes.forEach((n) => { let r = me.getStore().findRecord('node', n.name); if (r) { reloadRow(r); } });
		}, failure: (msg) => Ext.Msg.alert('Erro', msg) });
	};
	me.runRow = function (record) {
		let node = record.get('node');
		if (!record.get('online')) { Ext.Msg.alert('Updates', 'Node offline.'); return; }
		MM.Api.request({ method: 'POST', url: MM.Updates.path(node, 'run'),
			success: () => me.reload(), failure: (msg) => Ext.Msg.alert('Erro', msg) });
	};
	me.refreshRow = function (record) {
		let node = record.get('node');
		if (!record.get('online')) { Ext.Msg.alert('Updates', 'Node offline.'); return; }
		MM.Api.request({ method: 'POST', url: MM.Updates.path(node, 'refresh'),
			success: () => reloadRow(record), failure: (msg) => Ext.Msg.alert('Erro', msg) });
	};
	me.refreshSelected = function () {
		let nodes = selected();
		if (!nodes.length) { Ext.Msg.alert('Updates', 'Selecione ao menos um node.'); return; }
		nodes.forEach((node) => MM.Api.request({ method: 'POST', url: MM.Updates.path(node, 'refresh'),
			success: () => { let record = me.getStore().findRecord('node', node); if (record) { reloadRow(record); } },
			failure: (msg) => Ext.Msg.alert('Erro', msg) }));
	};
	me.updateSelected = function () {
		let nodes = selected();
		if (!nodes.length) { Ext.Msg.alert('Updates', 'Selecione ao menos um node.'); return; }
		let launch = function (override) {
			MM.Api.request({ method: 'POST', url: '/nodes/localhost/mm-tools/updates/bulk',
				params: { nodes: nodes.join(','), mode: mode.getValue(), override_preflight: override ? 1 : 0 },
				success: () => { me.reload(); }, failure: (msg) => {
					if (!override && /preflight|quorum|Ceph|offline|desconhecido/i.test(String(msg))) {
						Ext.Msg.confirm('Preflight recusou o bulk',
							`O preflight recusou a atualização: ${msg}. Forçar mesmo assim?`, (answer) => {
								if (answer === 'yes') { launch(true); }
							});
					} else { Ext.Msg.alert('Erro', msg); }
				} });
		};
		if (mode.getValue() === 'parallel') {
			Ext.Msg.confirm('Atualização paralela', 'Atualizar vários nodes ao mesmo tempo?', (answer) => {
				if (answer === 'yes') { launch(); }
			});
		} else { launch(); }
	};
	me.showPending = function (record) {
		let rows = record.get('pending') || [];
		Ext.create('Ext.window.Window', { title: `Pacotes pendentes — ${record.get('node')}`, modal: true,
			width: 720, height: 420, layout: 'fit', items: [{ xtype: 'grid', store: { data: rows },
				columns: [{ text: 'Pacote', dataIndex: 'Package', flex: 1 }, { text: 'Versão', dataIndex: 'Version', flex: 1 }] }],
		}).show();
	};
	me.showLog = function (record) {
		let job = record.get('job')?.id;
		if (!job) { Ext.Msg.alert('Log', 'Este node ainda não tem job.'); return; }
		MM.Api.request({ url: MM.Updates.path(record.get('node'), `log?job=${encodeURIComponent(job)}`),
			success: (res) => Ext.create('Ext.window.Window', { title: `Log ${job}`, modal: true, width: 820, height: 500,
				layout: 'fit', items: [{ xtype: 'textarea', value: (res.data?.lines || []).join('\n'), readOnly: true }] }).show(),
		});
	};
	Ext.apply(me, {
		store: { fields: ['node', 'online', 'pending', 'kernel', 'reboot_suggested', 'job', 'results',
			'last_result', 'reboot_context', 'orchestrator_lost'] },
		selModel: { selType: 'checkboxmodel', mode: 'MULTI', checkOnly: true },
		columns: [
			{ text: 'Node', dataIndex: 'node', width: 150 },
			{ text: 'Estado', dataIndex: 'online', width: 90, renderer: (v) => v ? 'online' : 'offline' },
			{ text: 'Pendentes', dataIndex: 'pending', width: 90, renderer: (v) => (v || []).length },
			{ text: 'Kernel', dataIndex: 'kernel', flex: 1, renderer: (v) => MM.Utils.html(v?.running || '-') },
			{ text: 'Reboot', dataIndex: 'reboot_suggested', width: 110, renderer: (v) => v ? 'sugerido' : '—' },
			{ text: 'Job', dataIndex: 'job', width: 120, renderer: (v) => MM.Utils.html(v?.state || '-') },
			{ text: 'Orquestrador', dataIndex: 'orchestrator_lost', width: 120,
				renderer: (v) => v ? 'perdido' : '—' },
			{ text: 'Último resultado', dataIndex: 'last_result', width: 150 },
			{ xtype: 'actioncolumn', width: 330, items: [
				{ tooltip: 'Atualizar node', iconCls: 'fa fa-download', handler: (grid, row) => me.runRow(grid.getStore().getAt(row)) },
				{ tooltip: 'Atualizar lista de pacotes', iconCls: 'fa fa-refresh', handler: (grid, row) => me.refreshRow(grid.getStore().getAt(row)) },
				{ tooltip: 'Pacotes pendentes', iconCls: 'fa fa-list', handler: (grid, row) => me.showPending(grid.getStore().getAt(row)) },
				{ tooltip: 'Ver log', iconCls: 'fa fa-file-text-o', handler: (grid, row) => me.showLog(grid.getStore().getAt(row)) },
				{ tooltip: 'Reiniciar', iconCls: 'fa fa-power-off', isDisabled: (view, row, col, item, record) => !record.get('reboot_suggested'),
					handler: (grid, row) => MM.Updates.tripleReboot(grid.getStore().getAt(row), (node) => MM.Api.request({
						method: 'POST', url: MM.Updates.path(node, 'reboot'), params: { confirm: node },
						success: () => me.reload(), failure: (msg) => Ext.Msg.alert('Erro', msg),
					})) },
			] },
		],
		tbar: [{ xtype: 'button', text: 'Atualizar lista', iconCls: 'fa fa-refresh', handler: () => me.reload() },
			{ xtype: 'checkbox', boxLabel: 'Selecionar todos', handler: (box, checked) => checked ? me.getSelectionModel().selectAll() : me.getSelectionModel().deselectAll() },
			{ xtype: 'tbtext', text: 'Modo:' }, mode,
			{ xtype: 'button', text: 'Atualizar pacotes selecionados', iconCls: 'fa fa-refresh', handler: () => me.refreshSelected() },
			{ xtype: 'button', text: 'Atualizar selecionados', iconCls: 'fa fa-download', handler: () => me.updateSelected() }],
		listeners: { activate: () => me.reload() },
	});
	me.callParent();
	MM.ModuleState.bind(me, 'updates');
	me.reload();
	me.refreshTimer = setInterval(() => {
		if (me.isDestroyed) { clearInterval(me.refreshTimer); return; }
		let busy = me.getStore().findBy((r) => ['queued', 'running'].includes(r.get('job')?.state)) >= 0;
		if (busy) { me.reload(); }
	}, 5000);
    },
});

MM.registerTab({ xtype: 'mmPanelUpdates', title: 'Updates' });
