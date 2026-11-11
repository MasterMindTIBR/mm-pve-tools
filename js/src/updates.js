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
		? MM.t('updates.guests_running', { guests: guests.map((g) => `${g.type}/${g.vmid}`).join(', ') })
		: MM.t('updates.no_guests');
	if (ha) { details += `\n${MM.t('updates.ha', { ha: JSON.stringify(ha) })}`; }
	let understood = Ext.create('Ext.form.field.Checkbox', {
		boxLabel: MM.t('updates.understand_reboot'),
	});
	let name = Ext.create('Ext.form.field.Text', { fieldLabel: MM.t('updates.node_name'), allowBlank: false });
	let win = Ext.create('Ext.window.Window', {
		title: MM.t('updates.confirm_reboot', { node }), modal: true, width: 560, bodyPadding: 12,
		items: [{ xtype: 'displayfield', value: MM.Utils.html(details).replace(/\n/g, '<br>') }, understood, name],
		buttons: [{ text: MM.t('updates.cancel'), handler: () => win.close() }, {
			text: MM.t('updates.reboot'), itemId: 'mm-confirm-reboot', disabled: true,
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
	    title: MM.t('tabs.updates'),

    initComponent: function () {
	let me = this;
	let mode = Ext.create('Proxmox.form.KVComboBox', {
		width: 150, comboItems: [['sequential', MM.t('updates.sequential')], ['parallel', MM.t('updates.parallel')]], value: 'sequential',
	});
	let selected = () => me.getSelection().map((r) => r.get('node'));
	let activeStates = ['queued', 'launching', 'running'];
	let jobStates = ['queued', 'running'];
	me.activeBulk = null;
	me.refreshTimer = null;

	me.bulkReason = function () {
		return me.activeBulk ? MM.t('updates.other_in_progress', { id: me.activeBulk.id }) : '';
	};
	me.formatElapsed = function (seconds) {
		seconds = Number(seconds || 0);
		let minutes = Math.floor(seconds / 60);
		let rest = seconds % 60;
		return MM.t('updates.elapsed_value', { minutes, seconds: String(rest).padStart(2, '0') });
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
		return ({ queued: MM.t('updates.state_queued'), running: MM.t('updates.state_updating'), updating: MM.t('updates.state_updating'),
			succeeded: MM.t('updates.state_completed'), completed: MM.t('updates.state_completed'), warning: MM.t('updates.state_warning'),
			failed: MM.t('updates.state_failed'), skipped: MM.t('diagnostics.skipped'), cancelled: MM.t('updates.cancelled'),
			ready: MM.t('updates.ready'), loading: MM.t('updates.loading'), offline: MM.t('updates.node_offline') }[state] || state || '—');
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
		let summary = `<b>${MM.t('updates.progress_running')}</b><br>`
			+ `${MM.t('updates.mode')} ${MM.Utils.html(bulk.mode || 'sequential')}<br>`
			+ `${MM.t('updates.current_node')}: ${MM.Utils.html(current)}<br>`
			+ `${MM.t('updates.phase')}: ${MM.Utils.html(phase)}<br>`
			+ `${MM.t('updates.elapsed')}: ${me.formatElapsed(bulk.elapsed_seconds)}<br>${lines}`;
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
		if (!record.get('online')) { record.set({ last_result: MM.t('common.offline'), update_state: 'offline' }); return; }
		MM.Api.request({ url: MM.Updates.path(node, 'status'),
			success: (res) => me.applyStatus(record, res.data || {}),
			failure: (msg) => {
				let active = jobStates.includes(record.get('job')?.state)
					|| activeStates.includes(record.get('bulk')?.state);
				if (active) {
					record.set({ last_result: 'updating', update_state: 'updating', online: true });
				} else { record.set({ last_result: MM.t('updates.error', { message: msg }), update_state: 'failed', online: false }); }
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
				last_result: n.online ? (previous?.get('last_result') || MM.t('updates.loading')) : MM.t('updates.node_offline') };
			}));
			nodes.forEach((n) => { let r = me.getStore().findRecord('node', n.name); if (r) { reloadRow(r); } });
		}, failure: (msg) => Ext.Msg.alert(MM.t('common.error'), msg) });
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
		if (!record.get('online')) { Ext.Msg.alert(MM.t('tabs.updates'), MM.t('updates.node_offline')); return; }
		record.set({ starting: true, update_state: 'starting', last_result: MM.t('updates.starting_state') });
		MM.Api.request({ method: 'POST', url: MM.Updates.path(node, 'run'),
			success: () => { record.set({ starting: false, job: { state: 'running' }, update_state: 'updating' }); me.reload(); me.ensurePolling(); },
			failure: (msg) => { record.set({ starting: false }); Ext.Msg.alert(MM.t('common.error'), msg); me.reload(); },
		});
	};
	me.refreshRow = function (record) {
		let node = record.get('node');
		if (!record.get('online')) { Ext.Msg.alert(MM.t('tabs.updates'), MM.t('updates.node_offline')); return; }
		MM.Api.request({ method: 'POST', url: MM.Updates.path(node, 'refresh'),
			success: () => reloadRow(record), failure: (msg) => Ext.Msg.alert(MM.t('common.error'), msg) });
	};
	me.refreshSelected = function () {
		let nodes = selected();
		if (!nodes.length) { Ext.Msg.alert(MM.t('tabs.updates'), MM.t('updates.select_one')); return; }
		nodes.forEach((node) => MM.Api.request({ method: 'POST', url: MM.Updates.path(node, 'refresh'),
			success: () => { let record = me.getStore().findRecord('node', node); if (record) { reloadRow(record); } },
			failure: (msg) => Ext.Msg.alert(MM.t('common.error'), msg) }));
	};
	me.cancelBulk = function () {
		if (!me.activeBulk) { return; }
		let id = me.activeBulk.id;
		MM.Api.request({ method: 'POST', url: MM.Updates.path('localhost', 'bulk/cancel'),
			params: { bulk: id },
			success: () => me.reload(), failure: (msg) => Ext.Msg.alert(MM.t('common.error'), msg) });
	};
	me.updateSelected = function () {
		if (me.activeBulk) { return; }
		let nodes = selected();
		if (!nodes.length) { Ext.Msg.alert(MM.t('tabs.updates'), MM.t('updates.select_one')); return; }
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
						Ext.Msg.confirm(MM.t('updates.preflight_title'),
							MM.t('updates.preflight_question', { message: msg }), (answer) => {
								if (answer === 'yes') { launch(true); }
							});
					} else { Ext.Msg.alert(MM.t('common.error'), msg); }
				} });
		};
		if (mode.getValue() === 'parallel') {
			Ext.Msg.confirm(MM.t('updates.parallel_title'), MM.t('updates.parallel_question'), (answer) => {
				if (answer === 'yes') { launch(); }
			});
		} else { launch(); }
	};
	me.showPending = function (record) {
		let rows = record.get('pending') || [];
		Ext.create('Ext.window.Window', { title: MM.t('updates.pending_title', { node: record.get('node') }), modal: true,
			width: 720, height: 420, layout: 'fit', items: [{ xtype: 'grid', store: { data: rows },
				columns: [{ text: MM.t('updates.package'), dataIndex: 'Package', flex: 1 }, { text: MM.t('updates.version'), dataIndex: 'Version', flex: 1 }] }],
		}).show();
	};
	me.showLog = function (record) {
		let job = record.get('job')?.id;
		if (!job) { Ext.Msg.alert(MM.t('updates.log'), MM.t('updates.no_job')); return; }
		MM.Api.request({ url: MM.Updates.path(record.get('node'), `log?job=${encodeURIComponent(job)}`),
			success: (res) => Ext.create('Ext.window.Window', { title: MM.t('updates.log_title', { job }), modal: true, width: 820, height: 500,
				layout: 'fit', items: [{ xtype: 'textarea', value: (res.data?.lines || []).join('\n'), readOnly: true }] }).show(),
		});
	};
	me.progressPanel = Ext.create('Ext.panel.Panel', {
		itemId: 'mm-updates-progress', hidden: true, bodyPadding: 8, layout: 'hbox',
		items: [{ xtype: 'component', itemId: 'mm-updates-progress-text', flex: 1 },
			{ xtype: 'button', itemId: 'mm-updates-cancel', text: MM.t('updates.cancel'), handler: () => me.cancelBulk() }],
	});
	Ext.apply(me, {
		store: { fields: ['node', 'online', 'pending', 'kernel', 'reboot_suggested', 'job', 'bulk', 'results',
			'last_result', 'reboot_context', 'orchestrator_lost', 'update_state', 'starting'] },
		selModel: { selType: 'checkboxmodel', mode: 'MULTI', checkOnly: true },
		dockedItems: [me.progressPanel],
		columns: [
			{ text: MM.t('updates.node'), dataIndex: 'node', width: 150 },
			{ text: MM.t('updates.status'), dataIndex: 'online', width: 90, renderer: (v) => v ? MM.t('common.online') : MM.t('common.offline') },
			{ text: MM.t('updates.update'), dataIndex: 'update_state', width: 110, renderer: (v) => MM.Utils.html(me.stateLabel(v)) },
			{ text: MM.t('updates.pending'), dataIndex: 'pending', width: 90, renderer: (v) => (v || []).length },
			{ text: MM.t('updates.kernel'), dataIndex: 'kernel', flex: 1, renderer: (v) => MM.Utils.html(v?.running || '-') },
			{ text: MM.t('updates.reboot_column'), dataIndex: 'reboot_suggested', width: 110, renderer: (v) => v ? MM.t('updates.suggested') : '—' },
			{ text: MM.t('updates.job'), dataIndex: 'job', width: 120, renderer: (v) => MM.Utils.html(me.stateLabel(v?.state || '-')) },
			{ text: MM.t('updates.orchestrator'), dataIndex: 'orchestrator_lost', width: 120,
				renderer: (v) => v ? MM.t('updates.lost') : '—' },
			{ text: MM.t('updates.last_result'), dataIndex: 'last_result', width: 150 },
			{ xtype: 'actioncolumn', width: 330, items: [
				{ tooltip: MM.t('updates.refresh_node'), iconCls: 'fa fa-download',
					getClass: (v, meta, record) => record.get('starting') ? 'fa fa-spinner fa-spin' : 'fa fa-download',
					getTip: (v, meta, record) => record.get('starting') ? MM.t('updates.starting') : (me.bulkReason() || MM.t('updates.refresh_node')),
					isDisabled: (view, row, col, item, record) => !!record.get('starting') || !!me.activeBulk,
					handler: (grid, row) => me.runRow(grid.getStore().getAt(row)) },
				{ tooltip: MM.t('updates.refresh_packages'), iconCls: 'fa fa-refresh', handler: (grid, row) => me.refreshRow(grid.getStore().getAt(row)) },
				{ tooltip: MM.t('updates.pending_packages'), iconCls: 'fa fa-list', handler: (grid, row) => me.showPending(grid.getStore().getAt(row)) },
				{ tooltip: MM.t('updates.view_log'), iconCls: 'fa fa-file-text-o', handler: (grid, row) => me.showLog(grid.getStore().getAt(row)) },
				{ tooltip: MM.t('updates.restart'), iconCls: 'fa fa-power-off', isDisabled: (view, row, col, item, record) => !record.get('reboot_suggested'),
					handler: (grid, row) => MM.Updates.tripleReboot(grid.getStore().getAt(row), (node) => MM.Api.request({
						method: 'POST', url: MM.Updates.path(node, 'reboot'), params: { confirm: node },
						success: () => me.reload(), failure: (msg) => Ext.Msg.alert(MM.t('common.error'), msg),
					})) },
			] },
		],
		tbar: [{ xtype: 'button', text: MM.t('updates.refresh_list'), iconCls: 'fa fa-refresh', handler: () => me.reload() },
			{ xtype: 'checkbox', boxLabel: MM.t('updates.select_all'), handler: (box, checked) => checked ? me.getSelectionModel().selectAll() : me.getSelectionModel().deselectAll() },
			{ xtype: 'tbtext', text: MM.t('updates.mode') }, mode,
			{ xtype: 'button', text: MM.t('updates.refresh_selected_packages'), iconCls: 'fa fa-refresh', handler: () => me.refreshSelected() },
			{ xtype: 'button', itemId: 'mm-updates-start-selected', text: MM.t('updates.update_selected'), iconCls: 'fa fa-download', handler: () => me.updateSelected() }],
		listeners: { activate: () => me.reload(), destroy: () => me.stopPolling() },
	});
	me.callParent();
	MM.ModuleState.bind(me, 'updates');
	me.reload();
    },
});

MM.registerTab({ xtype: 'mmPanelUpdates', title: MM.t('tabs.updates') });
