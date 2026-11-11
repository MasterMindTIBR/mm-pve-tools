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
	let activeStates = ['queued', 'launching', 'running'];
	let jobStates = ['queued', 'running'];
	me.activeBulk = null;
	me.refreshTimer = null;

	me.bulkReason = function () {
		return me.activeBulk ? `Outra atualização em andamento: ${me.activeBulk.id}` : '';
	};
	me.formatElapsed = function (seconds) {
		seconds = Number(seconds || 0);
		let minutes = Math.floor(seconds / 60);
		let rest = seconds % 60;
		return `${minutes}m ${String(rest).padStart(2, '0')}s`;
	};
	me.nodeState = function (record) {
		let node = record.get('node');
		let bulk = record.get('bulk');
		let bulkState = bulk?.node_states?.[node]?.state;
		if (bulkState) { return bulkState; }
		let state = record.get('job')?.state;
		if (state === 'running') { return 'updating'; }
		if (state === 'queued') { return 'queued'; }
		if (state === 'warning') { return 'warning'; }
		if (state === 'succeeded') { return 'completed'; }
		if (state === 'failed' || state === 'lost') { return 'failed'; }
		return record.get('online') ? 'ready' : 'offline';
	};
	me.stateLabel = function (state) {
		return ({ queued: 'na fila', running: 'atualizando', updating: 'atualizando',
			succeeded: 'concluído', completed: 'concluído', warning: 'aviso',
			failed: 'falhou', skipped: 'ignorado', cancelled: 'cancelado',
			ready: 'pronto', offline: 'offline' }[state] || state || '—');
	};
	me.showProgress = function (bulk) {
		if (!bulk) { me.progressPanel.hide(); return; }
		let states = bulk.node_states || {};
		let lines = (bulk.nodes || []).map((node) => {
			let state = states[node]?.state || 'queued';
			return `<div>${MM.Utils.html(node)}: ${MM.Utils.html(me.stateLabel(state))}</div>`;
		}).join('');
		let current = bulk.current_node || '—';
		let phase = bulk.current_phase || states[current]?.phase || 'queued';
		let summary = `<b>Atualização em andamento</b><br>`
			+ `Modo: ${MM.Utils.html(bulk.mode || 'sequential')}<br>`
			+ `Node atual: ${MM.Utils.html(current)}<br>`
			+ `Fase: ${MM.Utils.html(phase)}<br>`
			+ `Tempo: ${me.formatElapsed(bulk.elapsed_seconds)}<br>${lines}`;
		me.progressPanel.down('#mm-updates-progress-text').update(summary);
		me.progressPanel.down('#mm-updates-cancel').setDisabled(!bulk.id || !activeStates.includes(bulk.state));
		me.progressPanel.show();
	};
	me.syncBulk = function () {
		let active = null;
		me.getStore().each((record) => {
			let bulk = record.get('bulk');
			if (bulk && activeStates.includes(bulk.state)) { active = bulk; }
		});
		me.activeBulk = active;
		if (active) { me.showProgress(active); me.ensurePolling(); }
		else {
			me.progressPanel.hide();
			let jobActive = me.getStore().findBy((r) => jobStates.includes(r.get('job')?.state)) >= 0;
			if (jobActive) { me.ensurePolling(); } else { me.stopPolling(); }
		}
		let updateButton = me.down('#mm-updates-start-selected');
		if (updateButton) {
			updateButton.setDisabled(!!active);
			updateButton.setTooltip(me.bulkReason());
		}
	};
	me.applyStatus = function (record, data) {
		data.last_result = data.results?.[0]?.state || (data.job?.state || '—');
		data.orchestrator_lost = !!data.bulk?.orchestrator_lost;
		data.job = data.job || null;
		data.bulk = data.bulk || null;
		record.set(Ext.apply({ node: record.get('node') }, data));
		record.set('update_state', me.nodeState(record));
		me.syncBulk();
	};
	let reloadRow = function (record) {
		let node = record.get('node');
		if (!record.get('online')) { record.set({ last_result: 'offline', update_state: 'offline' }); return; }
		MM.Api.request({ url: MM.Updates.path(node, 'status'),
			success: (res) => me.applyStatus(record, res.data || {}),
			failure: (msg) => {
				let active = jobStates.includes(record.get('job')?.state)
					|| activeStates.includes(record.get('bulk')?.state);
				if (active) {
					record.set({ last_result: 'updating', update_state: 'updating', online: true });
				} else { record.set({ last_result: `erro: ${msg}`, update_state: 'failed', online: false }); }
				me.syncBulk();
			},
		});
	};
	me.reloadRow = reloadRow;
	me.reload = function () {
		MM.Api.request({ url: '/cluster/status', success: (res) => {
			let nodes = (res.data || []).filter((e) => e.type === 'node');
			me.getStore().setData(nodes.map((n) => {
				let previous = me.getStore().findRecord('node', n.name);
				return { node: n.name, online: !!n.online, pending: [],
					reboot_suggested: false, job: previous?.get('job') || null, bulk: previous?.get('bulk') || null,
					update_state: previous?.get('update_state') || (n.online ? 'loading' : 'offline'),
					starting: previous?.get('starting') || false,
					last_result: n.online ? (previous?.get('last_result') || 'carregando…') : 'offline' };
			}));
			nodes.forEach((n) => { let r = me.getStore().findRecord('node', n.name); if (r) { reloadRow(r); } });
		}, failure: (msg) => Ext.Msg.alert('Erro', msg) });
	};
	me.ensurePolling = function () {
		if (me.refreshTimer || me.isDestroyed) { return; }
		me.refreshTimer = setInterval(() => {
			if (me.isDestroyed) { me.stopPolling(); return; }
			if (me.activeBulk || me.getStore().findBy((r) => jobStates.includes(r.get('job')?.state)) >= 0) {
				me.reload();
			} else { me.stopPolling(); }
		}, 5000);
	};
	me.stopPolling = function () {
		if (me.refreshTimer) { clearInterval(me.refreshTimer); me.refreshTimer = null; }
	};
	me.runRow = function (record) {
		let node = record.get('node');
		if (me.activeBulk) { return; }
		if (!record.get('online')) { Ext.Msg.alert('Updates', 'Node offline.'); return; }
		record.set({ starting: true, update_state: 'starting', last_result: 'iniciando…' });
		MM.Api.request({ method: 'POST', url: MM.Updates.path(node, 'run'),
			success: () => { record.set({ starting: false, job: { state: 'running' }, update_state: 'updating' }); me.reload(); me.ensurePolling(); },
			failure: (msg) => { record.set({ starting: false }); Ext.Msg.alert('Erro', msg); me.reload(); },
		});
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
	me.cancelBulk = function () {
		if (!me.activeBulk) { return; }
		let id = me.activeBulk.id;
		MM.Api.request({ method: 'POST', url: MM.Updates.path('localhost', 'bulk/cancel'),
			params: { bulk: id },
			success: () => me.reload(), failure: (msg) => Ext.Msg.alert('Erro', msg) });
	};
	me.updateSelected = function () {
		if (me.activeBulk) { return; }
		let nodes = selected();
		if (!nodes.length) { Ext.Msg.alert('Updates', 'Selecione ao menos um node.'); return; }
		let launch = function (override) {
			MM.Api.request({ method: 'POST', url: '/nodes/localhost/mm-tools/updates/bulk',
				params: { nodes: nodes.join(','), mode: mode.getValue(), override_preflight: override ? 1 : 0 },
				success: (res) => {
					let data = res.data || {};
					me.activeBulk = Ext.apply({ state: 'launching', elapsed_seconds: 0,
						node_states: Object.fromEntries(nodes.map((node) => [node, { state: 'queued' }])) }, data);
					me.showProgress(me.activeBulk); me.ensurePolling(); me.reload();
				}, failure: (msg) => {
					if (!override && /preflight|quorum|Ceph|offline|unknown/i.test(String(msg))) {
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
	me.progressPanel = Ext.create('Ext.panel.Panel', {
		itemId: 'mm-updates-progress', hidden: true, bodyPadding: 8, layout: 'hbox',
		items: [{ xtype: 'component', itemId: 'mm-updates-progress-text', flex: 1 },
			{ xtype: 'button', itemId: 'mm-updates-cancel', text: 'Cancelar', handler: () => me.cancelBulk() }],
	});
	Ext.apply(me, {
		store: { fields: ['node', 'online', 'pending', 'kernel', 'reboot_suggested', 'job', 'bulk', 'results',
			'last_result', 'reboot_context', 'orchestrator_lost', 'update_state', 'starting'] },
		selModel: { selType: 'checkboxmodel', mode: 'MULTI', checkOnly: true },
		dockedItems: [me.progressPanel],
		columns: [
			{ text: 'Node', dataIndex: 'node', width: 150 },
			{ text: 'Estado', dataIndex: 'online', width: 90, renderer: (v) => v ? 'online' : 'offline' },
			{ text: 'Update', dataIndex: 'update_state', width: 110, renderer: (v) => MM.Utils.html(me.stateLabel(v)) },
			{ text: 'Pendentes', dataIndex: 'pending', width: 90, renderer: (v) => (v || []).length },
			{ text: 'Kernel', dataIndex: 'kernel', flex: 1, renderer: (v) => MM.Utils.html(v?.running || '-') },
			{ text: 'Reboot', dataIndex: 'reboot_suggested', width: 110, renderer: (v) => v ? 'sugerido' : '—' },
			{ text: 'Job', dataIndex: 'job', width: 120, renderer: (v) => MM.Utils.html(v?.state || '-') },
			{ text: 'Orquestrador', dataIndex: 'orchestrator_lost', width: 120,
				renderer: (v) => v ? 'perdido' : '—' },
			{ text: 'Último resultado', dataIndex: 'last_result', width: 150 },
			{ xtype: 'actioncolumn', width: 330, items: [
				{ tooltip: 'Atualizar node', iconCls: 'fa fa-download',
					getClass: (v, meta, record) => record.get('starting') ? 'fa fa-spinner fa-spin' : 'fa fa-download',
					getTip: (v, meta, record) => record.get('starting') ? 'Iniciando…' : (me.bulkReason() || 'Atualizar node'),
					isDisabled: (view, row, col, item, record) => !!record.get('starting') || !!me.activeBulk,
					handler: (grid, row) => me.runRow(grid.getStore().getAt(row)) },
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
			{ xtype: 'button', itemId: 'mm-updates-start-selected', text: 'Atualizar selecionados', iconCls: 'fa fa-download', handler: () => me.updateSelected() }],
		listeners: { activate: () => me.reload(), destroy: () => me.stopPolling() },
	});
	me.callParent();
	MM.ModuleState.bind(me, 'updates');
	me.reload();
    },
});

MM.registerTab({ xtype: 'mmPanelUpdates', title: 'Updates' });
