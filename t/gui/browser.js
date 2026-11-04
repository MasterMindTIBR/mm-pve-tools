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
    page.on('console', (message) => browserConsole.push(`${message.type()}: ${message.text()}`));
    page.on('pageerror', (error) => pageErrors.push(error.stack || String(error)));
    page.on('response', (response) => {
        const url = new URL(response.url());
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
        if (new URL(request.url()).pathname === '/pve2/js/mm-tools.js') { mmRequests++; }
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
        if (!navTexts.includes('MasterMind')) {
            throw new Error(`MasterMind missing from Datacenter navigation: ${navTexts.join(', ')}`);
        }
        await page.locator('.x-treelist-item-text', { hasText: 'MasterMind' }).first()
            .waitFor({ state: 'visible', timeout: TIMEOUT });
        console.log('GUI: tree found');
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
        if (mmRequests !== 1) { throw new Error(`mm-tools.js requests=${mmRequests}, esperado 1`); }
        console.log('GUI OK: script inserido, MasterMind na árvore, Publicar pasta… na toolbar');
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
