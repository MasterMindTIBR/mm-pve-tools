const { chromium } = require('playwright');

const port = Number(process.argv[2]);
const TIMEOUT = 30_000;

async function withTimeout(operation, label) {
    let timer;
    try {
        return await Promise.race([
            operation,
            new Promise((resolve, reject) => {
                timer = setTimeout(() => reject(new Error(`${label} timed out`)), TIMEOUT);
            }),
        ]);
    } finally {
        clearTimeout(timer);
    }
}

async function main() {
    const stallUi = process.env.MM_GUI_STALL_UI === '1';
    const flags = process.getuid && process.getuid() === 0
        ? ['--no-sandbox', '--disable-setuid-sandbox'] : [];
    console.log(`GUI: launching Chromium (flags=${flags.join(',') || 'sandbox'})`);
    const browser = await chromium.launch({ headless: true, timeout: TIMEOUT, args: flags });
    const context = await browser.newContext();
    context.setDefaultTimeout(TIMEOUT);
    context.setDefaultNavigationTimeout(TIMEOUT);
    await context.addCookies([{
        name: 'PVEAuthCookie',
        value: 'PVE:root@pam:harness',
        domain: '127.0.0.1',
        path: '/',
    }]);
    const page = await context.newPage();
    const browserConsole = [];
    const pageErrors = [];
    const assetFailures = [];
    let mmRequests = 0;
    let updateRequests = [];
    let poolRequests = [];
    let moduleConfigPuts = [];
    let applyRequests = [];
    let brandingRequests = [];
    let brandingResponses = [];
    page.on('console', (message) => browserConsole.push(`${message.type()}: ${message.text()}`));
    page.on('pageerror', (error) => pageErrors.push(error.stack || String(error)));
    page.on('response', (response) => {
        const url = new URL(response.url());
        if (url.pathname === '/pve2/js/mm-branding.json') { brandingResponses.push(response.status()); }
        if (url.pathname.endsWith('.js') && response.status() >= 400) {
            assetFailures.push(`${response.status()} ${response.url()}`);
        }
    });
    page.on('requestfailed', (request) => {
        const url = new URL(request.url());
        if (url.pathname.endsWith('.js')) {
            assetFailures.push(`request failed ${request.url()}: ${request.failure()?.errorText || 'unknown'}`);
        }
    });
    page.on('request', (request) => {
        const url = new URL(request.url());
        if (url.pathname === '/pve2/js/mm-tools.js') { mmRequests++; }
        if (url.pathname === '/pve2/js/mm-branding.json') { brandingRequests.push(request.url()); }
        if (url.pathname.endsWith('/mm-tools/config/modules') && request.method() === 'PUT') {
            moduleConfigPuts.push({ url: request.url(), postData: request.postData() || '' });
        }
        if (url.pathname.endsWith('/mm-tools/apply') && request.method() === 'POST') {
            applyRequests.push(request.url());
        }
        if (url.pathname.includes('/mm-tools/updates/')) {
            updateRequests.push({ url: request.url(), path: url.pathname,
                postData: request.postData() || '' });
        }
        if (url.pathname.includes('/mm-tools/poollimits/')) {
            poolRequests.push({ method: request.method(), url: request.url(),
                path: url.pathname, postData: request.postData() || '' });
        }
    });
    try {
        await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load', timeout: TIMEOUT });
        console.log('GUI: page loaded');
        if (assetFailures.length) {
            throw new Error(`referenced JavaScript asset failed: ${assetFailures.join('; ')}`);
        }
        await page.waitForFunction(
            () => window.__MM_HARNESS_READY__ && window.Ext,
            undefined,
            { timeout: TIMEOUT },
        );
        console.log('GUI: harness ready');
        await page.waitForFunction(
            () => window.MM?.Ui?.staticReady,
            undefined,
            { timeout: TIMEOUT },
        );
        await page.evaluate(() => MM.Ui.loadUser());
        await page.waitForFunction(
            () => window.MM?.Ui?.userReady,
            undefined,
            { timeout: TIMEOUT },
        );
        if (brandingRequests.length !== 1 || brandingResponses.some((status) => status >= 400)) {
            throw new Error(`branding JSON estático inválido: ${JSON.stringify({ brandingRequests, brandingResponses })}`);
        }
        await withTimeout(page.evaluate(() => {
            // pvemanagerlib reads every cap group (caps.storage, caps.access,
            // caps.sdn, caps.mapping, …) while building these panels, so a
            // partial GuiCap crashes upstream code, not ours.
            Ext.state.Manager.set('GuiCap', {
                dc: { 'Sys.Audit': 1, 'Sys.Modify': 1 },
                vms: { 'VM.Audit': 1, 'VM.Backup': 1, 'VM.Allocate': 1 },
                nodes: { 'Sys.Audit': 1, 'Sys.Modify': 1 },
                storage: { 'Datastore.Audit': 1, 'Datastore.Allocate': 1, 'Datastore.AllocateSpace': 1 },
                access: { 'User.Modify': 1, 'Group.Allocate': 1, 'Permissions.Modify': 1 },
                sdn: { 'SDN.Audit': 1, 'SDN.Allocate': 1 },
                mapping: { 'Mapping.Audit': 1, 'Mapping.Modify': 1 },
            });
            window.__mmDcConfig = Ext.create('PVE.dc.Config', {
                renderTo: Ext.getBody(),
                width: 1100,
                height: 700,
                pveSelNode: { data: { node: 'localhost', type: 'node' } },
            });
            Ext.create('PVE.grid.BackupView', {
                renderTo: Ext.getBody(),
                width: 1100,
                height: 500,
                pveSelNode: { data: { node: 'localhost', vmid: 100, type: 'qemu', name: 'harness' } },
            });
            window.__mmPoolConfig = Ext.create('PVE.pool.Config', {
                renderTo: Ext.getBody(),
                width: 1100,
                height: 700,
                pveSelNode: { data: { pool: 'labpool', type: 'pool' } },
            });
            window.__mmPoolAudit = Ext.create('PVE.pool.Config', {
                renderTo: Ext.getBody(),
                width: 1100,
                height: 700,
                pveSelNode: { data: { pool: 'auditpool', type: 'pool' } },
            });
            window.__mmPoolOff = Ext.create('PVE.pool.Config', {
                renderTo: Ext.getBody(),
                width: 1100,
                height: 700,
                pveSelNode: { data: { pool: 'offpool', type: 'pool' } },
            });
            window.__mmPoolConflict = Ext.create('PVE.pool.Config', {
                renderTo: Ext.getBody(),
                width: 1100,
                height: 700,
                pveSelNode: { data: { pool: 'conflictpool', type: 'pool' } },
            });
        }), 'GUI component creation');
        if (pageErrors.length) {
            throw new Error(`uncaught page errors: ${pageErrors.join('; ')}`);
        }
        // PVE.panel.Config keeps its navigation in a TreeStore (me.store) shown
        // by an Ext.list.Tree; assert on that store, then on the rendered item.
        const navTexts = await page.evaluate(() => {
            const panel = window.__mmDcConfig;
            if (!panel || !panel.store) { return null; }
            const texts = [];
            panel.store.getRoot().cascade((node) => { texts.push(node.get('text')); });
            return texts;
        });
        if (!navTexts) { throw new Error('Datacenter navigation store not found'); }
        if (!navTexts.includes('MM Tools')) {
            throw new Error(`MM Tools missing from Datacenter navigation: ${navTexts.join(', ')}`);
        }
        await page.locator('.x-treelist-item-text', { hasText: 'MM Tools' }).first()
            .waitFor({ state: 'visible', timeout: TIMEOUT });
        console.log('GUI: tree found');
        const about = await page.evaluate(() => {
            const tools = Ext.create('MM.panel.Tools', { renderTo: Ext.getBody(), width: 1000, height: 600 });
            const tabs = tools.items.getRange();
            const last = tabs[tabs.length - 1];
            tools.setActiveTab(last);
            const html = last.body ? last.body.dom.innerHTML : '';
            const result = {
                title: tools.title, last: last.title, itemId: last.itemId,
                version: !!last.body?.dom.querySelector('.mm-about-version')?.textContent,
                repo: html.includes('https://github.com/MasterMindTIBR/mm-pve-tools'),
                license: html.includes('AGPL'),
                credits: html.includes('MasterMindTI') && !html.includes('MasterMind TI')
                    && html.includes('https://github.com/junglivre') && !html.includes('mailto:'),
                blank: [...last.body.dom.querySelectorAll('a[target="_blank"]')]
                    .every((a) => a.rel.includes('noopener')),
            };
            tools.destroy();
            return result;
        });
        if (about.title !== 'MM Tools' || about.last !== 'Sobre' || about.itemId !== 'about'
            || !about.version || !about.repo || !about.license || !about.credits || !about.blank) {
            throw new Error(`aba Sobre incompleta: ${JSON.stringify(about)}`);
        }
        console.log('GUI: MM Tools com a aba Sobre por último (versão, repositório, créditos, licença)');
        const general = await page.evaluate(async (assertionTimeout) => {
            const wait = async (what, ok) => {
                const started = Date.now();
                while (!ok()) {
                    if (Date.now() - started > assertionTimeout) { throw new Error(`General: ${what}`); }
                    await new Promise((resolve) => setTimeout(resolve, 20));
                }
            };
            let applied = 0;
            const confirms = [];
            const realApply = MM.applyAll;
            const realConfirm = Ext.Msg.confirm;
            const realClusterNodesAll = MM.Api.clusterNodesAll;
            MM.applyAll = (done) => { applied += 1; if (done) { done(); } };
            MM.Api.clusterNodesAll = (callback) => callback([
                { type: 'node', node: 'localhost', name: 'localhost', online: 1 },
                { type: 'node', node: 'failing-node', name: 'failing-node', online: 1 },
            ]);
            Ext.Msg.confirm = (title, text, callback) => { confirms.push(String(text)); callback('yes'); };
            try {
                const panel = Ext.create('MM.panel.General', { renderTo: Ext.getBody(), width: 900, height: 400 });
                const grid = panel.down('#modules');
                const store = grid.getStore();
                await wait('módulos não carregaram', () => store.getCount() === 6);
                const order = store.getRange().map((r) => r.get('name'));
                const onAll = panel.down('#module-on-all');
                const offAll = panel.down('#module-off-all');
                const record = (name) => store.findRecord('name', name, 0, false, true, true);
                await wait('status inicial dos nodes não carregou', () =>
                    record('ui').get('nodesApplied') === 2
                    && record('ui').get('nodesTotal') === 2
                    && record('poollimits').get('nodesApplied') === 2
                    && record('branding').get('nodesUnknown')?.includes('failing-node'));
                const initialNodes = {
                    ui: `${record('ui').get('nodesApplied')}/${record('ui').get('nodesTotal')}`,
                    brandingUnknown: record('branding').get('nodesUnknown'),
                };
                const noApplyAll = !panel.down('button[text=Apply on all nodes]');
                onAll.handler();
                await wait('Ligar todos não ligou todos', () =>
                    store.getRange().every((r) => r.get('enabled'))
                    && record('poollimits').get('nodesApplied') === 1
                    && record('poollimits').get('nodesIssues')?.includes('failing-node'));
                const onNodes = `${record('poollimits').get('nodesApplied')}/${record('poollimits').get('nodesTotal')}`;
                offAll.handler();
                await wait('Desligar todos não desligou todos', () =>
                    store.getRange().every((r) => !r.get('enabled')));
                panel.destroy();
                return { order, noApplyAll, initialNodes, onNodes, applied, confirms,
                         info: !!MM.Modules.info.poollimits };
            } finally {
                MM.applyAll = realApply;
                MM.Api.clusterNodesAll = realClusterNodesAll;
                Ext.Msg.confirm = realConfirm;
            }
        }, TIMEOUT);
        if (general.order.join(',') !== 'ui,updates,poollimits,renumber,restore,branding'
            || !general.noApplyAll || general.initialNodes.ui !== '2/2'
            || !general.initialNodes.brandingUnknown.includes('failing-node')
            || general.onNodes !== '1/2' || general.applied !== 2
            || general.confirms.length !== 2 || !/Limites de pool/.test(general.confirms[0])
            || !/gateway/.test(general.confirms[0]) || !/logo/.test(general.confirms[0])
            || !/revertidos/.test(general.confirms[1]) || !general.info) {
            throw new Error(`General liga/desliga incompleto: ${JSON.stringify(general)}`);
        }
        const modulePutData = moduleConfigPuts.map((request) => {
            const params = new URL(request.url).searchParams;
            for (const [key, value] of new URLSearchParams(request.postData)) {
                params.set(key, value);
            }
            return { modules: JSON.parse(params.get('value')), digest: params.get('digest') };
        });
        if (modulePutData.length !== 2 || modulePutData.some((item) => item.digest !== `sha256=${'0'.repeat(64)}`
            && item.digest !== `sha256:${'0'.repeat(64)}`)) {
            throw new Error(`PUT de módulos não usou um digest por ação: ${JSON.stringify(modulePutData)}`);
        }
        if (applyRequests.length !== 0) {
            throw new Error(`o teste mockado deveria chamar MM.applyAll sem POST de apply: ${applyRequests.length}`);
        }
        console.log('GUI OK: General sem Apply-all, todos em um PUT + um apply e Nodes 2/2, 1/2, unknown');

        const moduleTabs = await page.evaluate(async (assertionTimeout) => {
            const wait = async (what, ok) => {
                const started = Date.now();
                while (!ok()) {
                    if (Date.now() - started > assertionTimeout) { throw new Error(`abas: ${what}`); }
                    await new Promise((resolve) => setTimeout(resolve, 20));
                }
            };
            const tools = Ext.create('MM.panel.Tools', { renderTo: Ext.getBody(), width: 1100, height: 600 });
            const panels = [
                ['ui', 'mmPanelUi'], ['updates', 'mmPanelUpdates'], ['restore', 'mmPanelRestore'],
                ['renumber', 'mmPanelVmid'], ['branding', 'mmPanelBranding'],
            ].map(([name, xtype]) => [name, tools.down(xtype)]);
            await wait('faixas não carregaram', () => panels.every(([, panel]) => panel.moduleBanner));
            await wait('estado das faixas não carregou', () => panels.every(([, panel]) =>
                panel.moduleEnabled === false));
            const visible = Object.fromEntries(panels.map(([name, panel]) =>
                [name, !panel.moduleBanner.isHidden()]));
            const branding = tools.down('mmPanelBranding');
            const general = tools.down('mmPanelGeneral');
            await wait('General não carregou para o link', () => general.down('#modules').getStore().getCount() === 6);
            branding.moduleBanner.down('button').handler();
            await wait('link não abriu General', () => tools.getActiveTab() === general
                && general.down('#modules').getSelection()[0]?.get('name') === 'branding');
            tools.destroy();
            return visible;
        }, TIMEOUT);
        if (!moduleTabs.ui || !moduleTabs.updates || !moduleTabs.restore
            || !moduleTabs.renumber || !moduleTabs.branding) {
            throw new Error(`faixas incorretas: ${JSON.stringify(moduleTabs)}`);
        }
        console.log('GUI OK: abas desligadas mostram faixa, link seleciona General e branding não pede JSON ausente');
        const updatesAssertions = await page.evaluate(async (assertionTimeout) => {
            let panel = Ext.create('MM.panel.Updates', { renderTo: Ext.getBody(), width: 1200, height: 500 });
            let started = Date.now();
            while (panel.getStore().getCount() < 2) {
                if (Date.now() - started > assertionTimeout) { throw new Error('grade de updates não carregou todos os nodes'); }
                await new Promise((resolve) => setTimeout(resolve, 20));
            }
            let local = panel.getStore().findRecord('node', 'localhost');
            let offline = panel.getStore().findRecord('node', 'offline-node');
            if (!local || !offline || local.get('reboot_suggested') !== true || offline.get('online') !== false) {
                throw new Error('status de updates por node incompleto');
            }
            if (!local.get('reboot_context')?.running_guests?.some((guest) => guest.vmid === 100)) {
                throw new Error('contexto de reboot não expõe guest ligado');
            }
            let mode = panel.down('combo').setValue('parallel');
            Ext.Msg.confirm = (title, text, callback) => callback('yes');
            panel.getSelectionModel().select(local);
            panel.runRow(local);
            panel.refreshRow(local);
            panel.refreshSelected();
            panel.down('button[text=Atualizar selecionados]').handler();
            let rebootDone = false;
            MM.Updates.tripleReboot(local, () => { rebootDone = true; });
            let win = Ext.WindowManager.getActive();
            let contextVisible = win.down('displayfield').getValue().includes('100');
            let understand = win.down('checkbox');
            let field = win.down('textfield');
            let rebootButton = win.down('#mm-confirm-reboot');
            let blocked = rebootButton.isDisabled();
            understand.setValue(true); field.setValue('outro');
            let wrongNameBlocked = rebootButton.isDisabled();
            field.setValue('localhost');
            let exactNameEnabled = !rebootButton.isDisabled();
            rebootButton.handler();
            return { rows: panel.getStore().getCount(), blocked, wrongNameBlocked, exactNameEnabled,
                rebootDone, contextVisible };
        }, TIMEOUT);
        if (updatesAssertions.rows !== 2 || !updatesAssertions.blocked
            || !updatesAssertions.wrongNameBlocked || !updatesAssertions.exactNameEnabled
            || !updatesAssertions.rebootDone || !updatesAssertions.contextVisible) {
            throw new Error(`updates assertions failed: ${JSON.stringify(updatesAssertions)}`);
        }
        await page.waitForTimeout(100);
        const updateRuns = updateRequests.filter((request) => request.path.endsWith('/updates/run'));
        const updateRefreshes = updateRequests.filter((request) => request.path.endsWith('/updates/refresh'));
        const bulkRequests = updateRequests.filter((request) => request.path.endsWith('/updates/bulk'));
        if (updateRuns.length < 1 || updateRefreshes.length < 2 || bulkRequests.length < 2
            || !bulkRequests.some((request) => request.url.includes('override_preflight=1')
                || request.postData.includes('override_preflight=1'))
            || !bulkRequests.some((request) => request.url.includes('mode=parallel')
                || request.postData.includes('mode=parallel'))
            || !bulkRequests.some((request) => request.path.endsWith('/updates/bulk')
            && (/(?:^|[?&])mode=parallel(?:&|$)/.test(request.url)
                || /(?:^|&)mode=parallel(?:&|$)/.test(request.postData)))) {
            throw new Error(`bulk paralelo não foi enviado: ${JSON.stringify(updateRequests)}`);
        }
        console.log('GUI OK: grade Updates, ações de linha/seleção, override de preflight, contexto e confirmação tripla');
        await page.locator('.x-btn-inner', { hasText: 'Publicar pasta…' }).first()
            .waitFor({ state: 'visible', timeout: TIMEOUT });
        console.log('GUI: button found');

        const uiAssertions = await page.evaluate(async (assertionTimeout) => {
            // Nos bundles reais, nenhum override pode ter sido recusado e a
            // preferência do usuário tem que ter carregado pela API.
            let installIncompatibilities = MM.Ui.incompatibilities.slice();
            let userLoaded = MM.Ui.userReady === true;
            let settings = Ext.create('PVE.window.Settings');
            settings.show();
            let settingsFields = !!settings.down('[reference=mmUiQemu]')
                && !!settings.down('[reference=mmUiLxc]')
                && MM.Ui.incompatibilities.length === installIncompatibilities.length;
            settings.close();
            let opened = [];
            let originalOpen = PVE.Utils.openConsoleWindow;
            PVE.Utils.openConsoleWindow = (...args) => opened.push(args);

            // The authenticated user override wins over the cluster default.
            MM.Ui.user = { qemu: 'html5' };
            MM.Ui.cluster = { qemu: 'vv', lxc: 'xtermjs' };
            PVE.Utils.openDefaultConsoleWindow({ spice: true, xtermjs: true },
                'kvm', 100, 'localhost', 'harness');
            let qemuUser = opened.pop()?.[0];

            // If the selected xterm.js viewer is unavailable, use PVE's fallback order.
            PVE.Utils.openDefaultConsoleWindow({ spice: false, xtermjs: false },
                'lxc', 100, 'localhost', 'harness');
            let lxcFallback = opened.pop()?.[0];

            // The explicit split-menu choice remains an explicit choice.
            let button = Ext.create('PVE.button.ConsoleButton', {
                consoleType: 'kvm', vmid: 100, nodename: 'localhost', consoleName: 'harness',
            });
            button.openConsole('vv');
            let explicitMenu = opened.pop()?.[0];

            // Following the cluster default is a real API/UI reset, not a
            // second viewer value.
            MM.Ui.user = { qemu: 'html5' };
            let resetDone = await new Promise((resolve, reject) => {
                MM.Ui.saveUser('qemu', 'cluster');
                let started = Date.now();
                let poll = () => {
                    if (!MM.Ui.user.qemu) { resolve(true); return; }
                    if (Date.now() - started > assertionTimeout) { reject(new Error('cluster reset timed out')); return; }
                    setTimeout(poll, 10);
                };
                poll();
            });
            MM.Ui.cluster = { qemu: 'xtermjs', lxc: 'xtermjs' };
            MM.Ui.user = { qemu: 'xtermjs', lxc: 'html5' };
            let embeddedLxc = Ext.create('PVE.noVncConsole', {
                consoleType: 'lxc', vmid: 100, nodename: 'localhost',
            });
            let embeddedQemu = Ext.create('PVE.noVncConsole', {
                consoleType: 'kvm', vmid: 100, nodename: 'localhost',
            });
            MM.Ui.user = { qemu: 'vv' };
            let embeddedQemuVv = Ext.create('PVE.noVncConsole', {
                consoleType: 'kvm', vmid: 100, nodename: 'localhost',
            });
            // Renderizado como na aba real: o activate do PVE carrega o iframe.
            embeddedQemuVv.render(Ext.getBody());
            embeddedQemuVv.fireEvent('activate');
            embeddedQemuVv.destroy();
            PVE.Utils.openConsoleWindow = originalOpen;
            let beforeIncompatibility = MM.Ui.incompatibilities.length;
            let rejected = MM.Ui.recognized({ defaultViewer: function () { return 'html5'; } },
                'defaultViewer', ['marker-from-an-unrecognized-bundle']);
            return {
                installIncompatibilities, userLoaded, settingsFields,
                qemuUser, lxcFallback, explicitMenu,
                resetDone,
                embeddedLxcNoVnc: !embeddedLxc.xtermjs,
                embeddedQemuNoSerialNoVnc: !embeddedQemu.xtermjs,
                embeddedQemuVvNoSpice: opened.length === 0 && !embeddedQemuVv.xtermjs,
                defaultIsCurrent: MM.Ui.viewerFor('kvm') === 'vv',
                overrideRejected: rejected === null,
                incompatibilityRecorded: MM.Ui.incompatibilities.length > beforeIncompatibility,
            };
        }, TIMEOUT);
        if (uiAssertions.installIncompatibilities.length !== 0
            || !uiAssertions.userLoaded
            || !uiAssertions.settingsFields
            || uiAssertions.qemuUser !== 'html5'
            || uiAssertions.lxcFallback !== 'html5'
            || uiAssertions.explicitMenu !== 'vv'
            || !uiAssertions.resetDone
            || !uiAssertions.embeddedLxcNoVnc
            || !uiAssertions.embeddedQemuNoSerialNoVnc
            || !uiAssertions.embeddedQemuVvNoSpice
            || !uiAssertions.defaultIsCurrent
            || !uiAssertions.overrideRejected
            || !uiAssertions.incompatibilityRecorded) {
            throw new Error(`console assertions failed: ${JSON.stringify(uiAssertions)}`);
        }
        const popupAssertions = await page.evaluate(async (stall) => {
            let callback = 0;
            let shown = 0;
            let oldShow = Ext.Msg.show;
            Ext.Msg.show = (config) => {
                shown++;
                if (stall && config.callback) { config.callback('ok'); }
            };
            if (stall) {
                MM.Ui.staticReady = false;
                MM.Ui.loadStatic();
                Proxmox.Utils.checked_command(() => { callback++; });
                await new Promise((resolve) => setTimeout(resolve, 3500));
                await new Promise((resolve) => setTimeout(resolve, 100));
                Ext.Msg.show = oldShow;
                return { timeout: true, callback, shown, hide: MM.Ui.hideSubscriptionPopup };
            }
            MM.Ui.applyStatic({ console: { qemu: 'default', lxc: 'default' },
                hide_subscription_popup: true });
            Proxmox.Utils.checked_command(() => { callback++; });
            let hidden = { callback, shown };
            MM.Ui.applyStatic({ console: { qemu: 'default', lxc: 'default' },
                hide_subscription_popup: false });
            Proxmox.Utils.checked_command(() => { callback++; });
            await new Promise((resolve) => setTimeout(resolve, 50));
            Ext.Msg.show = oldShow;
            return { hidden, callback, shown };
        }, stallUi);
        if (stallUi
            ? (popupAssertions.timeout !== true || popupAssertions.hide !== false
                || popupAssertions.shown < 1 || popupAssertions.callback !== 1)
            : (popupAssertions.hidden.callback !== 1 || popupAssertions.hidden.shown !== 0
                || popupAssertions.callback !== 1 || popupAssertions.shown < 1)) {
            throw new Error(`subscription popup assertions failed: ${JSON.stringify(popupAssertions)}`);
        }
        console.log(`GUI OK: console inventory, cluster reset, embedded viewer, popup ${stallUi ? 'timeout fallback' : 'toggle'}`);
        const poolAssertions = await page.evaluate(async (assertionTimeout) => {
            let started = Date.now();
            let limits;
            while (!limits) {
                limits = window.__mmPoolConfig.down('#poollimits');
                if (limits) { break; }
                if (Date.now() - started > assertionTimeout) { throw new Error('aba Limites não carregou'); }
                await new Promise((resolve) => setTimeout(resolve, 20));
            }
            let rows = limits.down('#usage-grid').getStore().getRange().map((record) => record.getData());
            let warning = limits.down('#accounting-warning').getValue();
            let save = limits.down('button[text=Salvar]');
            let selector = limits.down('#storage-selector');
            let storageStarted = Date.now();
            while (selector.getStore().findExact('storage', 'local') < 0) {
                if (Date.now() - storageStarted > assertionTimeout) {
                    throw new Error('storage local não carregou no seletor');
                }
                await new Promise((resolve) => setTimeout(resolve, 20));
            }
            limits.down('#mode').setValue('allocated');
            limits.down('#cpu-enabled').setValue(false);
            limits.down('#memory-max').setValue(4096);
            limits.down('#disk-total-enabled').setValue(false);
            limits.down('#disk-storage-enabled').setValue(true);
            selector.setValue('local');
            limits.down('#add-storage').click();
            limits.down('#storage-local-max').setValue(6);
            save.click();
            await new Promise((resolve) => setTimeout(resolve, 120));
            let addedEditor = !!limits.down('#storage-local-max');
            limits.down('#storage-local-remove').click();
            limits.down('#disk-storage-enabled').setValue(false);
            save.click();
            await new Promise((resolve) => setTimeout(resolve, 120));
            let auditStarted = Date.now();
            while (!window.__mmPoolAudit.down('#poollimits')) {
                if (Date.now() - auditStarted > assertionTimeout) { throw new Error('pool audit não carregou'); }
                await new Promise((resolve) => setTimeout(resolve, 20));
            }
            let auditLimits = window.__mmPoolAudit.down('#poollimits');
            let conflictStarted = Date.now();
            while (!window.__mmPoolConflict.down('#poollimits')) {
                if (Date.now() - conflictStarted > assertionTimeout) { throw new Error('pool concorrente não carregou'); }
                await new Promise((resolve) => setTimeout(resolve, 20));
            }
            let conflict = window.__mmPoolConflict.down('#poollimits');
            let conflictMessages = [];
            let oldAlert = Ext.Msg.alert;
            Ext.Msg.alert = (title, message) => conflictMessages.push(String(message));
            conflict.down('button[text=Salvar]').click();
            let messageStarted = Date.now();
            while (!conflictMessages.length && Date.now() - messageStarted <= assertionTimeout) {
                await new Promise((resolve) => setTimeout(resolve, 20));
            }
            Ext.Msg.alert = oldAlert;
            return {
                rows,
                warning,
                hasSave: !!save,
                addedEditor,
                removedEditor: !limits.down('#storage-local-max'),
                mode: limits.down('#mode-display').getValue(),
                auditMode: auditLimits.down('#mode-display').getValue(),
                auditHasSave: !!auditLimits.down('button[text=Salvar]'),
                auditHasEditor: !!auditLimits.down('#editor'),
                offHasTab: !!window.__mmPoolOff.down('#poollimits'),
                conflictMessage: conflictMessages[0] || '',
            };
        }, TIMEOUT);
        if (!poolAssertions.hasSave
            || !poolAssertions.addedEditor
            || !poolAssertions.removedEditor
            || poolAssertions.auditHasSave
            || poolAssertions.auditHasEditor
            || poolAssertions.offHasTab
            || poolAssertions.auditMode !== 'Ligado'
            || !poolAssertions.rows.some((row) => row.resource === 'Disco — local')
            || !poolAssertions.rows.some((row) => row.resource === 'Disco — fast')
            || !poolAssertions.rows.some((row) => row.resource === 'Disco total'
                && row.value.includes('3 GiB') && row.value.includes('8 GiB'))
            || !poolAssertions.rows.some((row) => row.resource === 'Disco — local'
                && row.value.includes('2 GiB') && row.value.includes('desligado'))
            || !poolAssertions.rows.some((row) => ['vCPU', 'RAM'].includes(row.resource)
                && row.value.includes('indisponível'))
            || !poolAssertions.warning.includes('Contabilidade indisponível')) {
            throw new Error(`poollimits assertions failed: ${JSON.stringify(poolAssertions)}`);
        }
        await page.waitForTimeout(100);
        const poolPuts = poolRequests.filter((request) => request.method === 'PUT');
        if (poolPuts.length < 3 || !poolPuts.some((request) => {
            let data = JSON.parse(request.postData || '{}');
            return data.mode === 'allocated' && data.digest === 'sha256:' + '0'.repeat(64)
                && data.cpu?.enabled === false && data.memory_mib?.max === 4096
                && data.disk_total_gib?.enabled === false
                && data.disk_storage?.enabled === true
                && data.disk_storage?.limits?.local === 6
                && data.disk_storage?.limits?.fast === undefined;
        }) || !poolPuts.some((request) => {
            let data = JSON.parse(request.postData || '{}');
            return data.disk_storage?.enabled === false
                && Object.keys(data.disk_storage?.limits || {}).length === 0;
        }) || !poolPuts.some((request) => request.path.endsWith('/conflictpool')
            && JSON.parse(request.postData || '{}').digest === 'sha256:' + '0'.repeat(64))) {
            throw new Error(`poollimits PUT incorreto: ${JSON.stringify(poolRequests)}`);
        }
        if (!poolAssertions.conflictMessage.includes('DIGEST_MISMATCH')
            || !poolAssertions.conflictMessage.includes('configuração do pool mudou')) {
            throw new Error(`erro concorrente não chegou à GUI: ${JSON.stringify(poolAssertions)}`);
        }
        console.log('GUI OK: aba Limites, uso x limite, storages, warning, CAS, edição e modo leitura');
        const nativeErrorAssertions = await page.evaluate(async (assertionTimeout) => {
            let messages = [];
            let oldAlert = Ext.Msg.alert;
            Ext.Msg.alert = (title, message) => messages.push(String(message));
            let hardware = Ext.create('PVE.qemu.MemoryEdit', {
                url: '/api2/extjs/nodes/localhost/qemu/100/config',
                pveSelNode: { data: { node: 'localhost', vmid: 100, type: 'qemu' } },
                hotplug: 'memory',
            });
            hardware.submit();
            let resize = Ext.create('PVE.window.HDResize', {
                nodename: 'localhost', vmid: 100, disk: 'scsi0',
            });
            resize.resize_disk('scsi0', 2);
            let started = Date.now();
            while (messages.length < 2) {
                if (Date.now() - started > assertionTimeout) { break; }
                await new Promise((resolve) => setTimeout(resolve, 20));
            }
            Ext.Msg.alert = oldAlert;
            hardware.destroy(); resize.destroy();
            return messages;
        }, TIMEOUT);
        if (!nativeErrorAssertions.some((message) => message.includes('limite de RAM excedido'))
            || !nativeErrorAssertions.some((message) => message.includes('limite de disco total excedido'))) {
            throw new Error(`mensagens nativas de poollimits perdidas: ${JSON.stringify(nativeErrorAssertions)}`);
        }
        console.log('GUI OK: hardware edit e resize exibem a mensagem de limite do servidor');
        if (mmRequests !== 1) { throw new Error(`mm-tools.js requests=${mmRequests}, esperado 1`); }
        console.log('GUI OK: script inserido, MM Tools na árvore, Publicar pasta… na toolbar');
    } catch (error) {
        console.error(`GUI PAGE ERRORS:\n${pageErrors.join('\n') || '(empty)'}`);
        console.error(`GUI FAIL: ${error.stack || error}`);
        console.error(`GUI BROWSER CONSOLE:\n${browserConsole.join('\n') || '(empty)'}`);
        throw error;
    } finally {
        await browser.close();
    }
}

main().catch((error) => {
    if (!error) { console.error('GUI FAIL: unknown error'); }
    process.exitCode = 1;
});
