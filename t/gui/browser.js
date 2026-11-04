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
