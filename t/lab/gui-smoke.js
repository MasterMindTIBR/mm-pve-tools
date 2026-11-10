// Smoke de GUI contra o pveproxy real do lab (Rock 7). Roda na imagem do
// Playwright do t/gui. Uso: node gui-smoke.js pool|offline URL POOL VMID NODE OFFLINE_NODE
// Os tickets (admin e auditor) vêm de /secrets/{admin,audit}.ticket e nunca são impressos.
const fs = require('fs');
const { chromium } = require('playwright');

const [phase, url, pool, vmid, node, offlineNode] = process.argv.slice(2);
const TIMEOUT = 45_000;
const host = new URL(url).hostname;

function ticket(name) {
    return fs.readFileSync(`/secrets/${name}.ticket`, 'utf8').trim();
}

async function openAs(browser, who) {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    context.setDefaultTimeout(TIMEOUT);
    await context.addCookies([{ name: 'PVEAuthCookie', value: encodeURIComponent(ticket(who)),
        domain: host, path: '/', secure: true }]);
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (error) => errors.push(String(error)));
    await page.goto(url, { waitUntil: 'load' });
    await page.waitForFunction(() => window.Ext && window.MM && window.Proxmox && Proxmox.UserName
        && Ext.ClassManager.get('PVE.pool.Config') && MM.PoolLimits, null, { timeout: TIMEOUT });
    const user = await page.evaluate(() => Proxmox.UserName);
    // Sem passar pela tela de login o GuiCap (permissões da GUI) não existe no
    // navegador novo e o painel Datacenter do próprio PVE quebra ao carregar
    // (o padrão do PVE não tem "mapping"). Faz o que o login faz: renova o
    // ticket e grava o GuiCap; só então passa a contar os erros de página.
    const caps = await page.evaluate(async () => {
        const body = new URLSearchParams({ username: Proxmox.UserName,
            password: decodeURIComponent(Ext.util.Cookies.get('PVEAuthCookie')) });
        const res = await fetch('/api2/json/access/ticket', { method: 'POST', body });
        const data = (await res.json()).data;
        Ext.state.Manager.set('GuiCap', data.cap);
        return Object.keys(data.cap || {});
    });
    if (errors.length) { console.log(`GUI: erros do carregamento sem GuiCap (do PVE, antes do login simulado): ${errors.join('; ')}`); }
    errors.length = 0;
    console.log(`GUI: ${who} logado como ${user}; GuiCap ${caps.join(',')}`);
    return { context, page, errors, user };
}

async function poolTab(page, poolName) {
    return page.evaluate(async ({ poolName, timeout }) => {
        const panel = Ext.create('PVE.pool.Config', {
            renderTo: Ext.getBody(), width: 1100, height: 700,
            pveSelNode: { data: { pool: poolName, type: 'pool' } },
        });
        const started = Date.now();
        let tab;
        while (!(tab = panel.down('#poollimits'))) {
            if (Date.now() - started > timeout) { throw new Error('aba Limites não apareceu'); }
            await new Promise((resolve) => setTimeout(resolve, 100));
        }
        panel.setActiveTab ? panel.setActiveTab(tab) : null;
        let rows = [];
        while (Date.now() - started < timeout) {
            rows = tab.down('#usage-grid').getStore().getRange().map((r) => r.getData());
            if (rows.length && !rows.some((r) => String(r.value).includes('indisponível'))) { break; }
            await new Promise((resolve) => setTimeout(resolve, 200));
        }
        return {
            rows,
            mode: tab.down('#mode-display').getValue(),
            save: !!tab.down('#save'),
            readOnly: !tab.down('#editor'),
            warning: tab.down('#accounting-warning').getValue(),
        };
    }, { poolName, timeout: TIMEOUT });
}

async function phasePool(browser) {
    const admin = await openAs(browser, 'admin');
    const tab = await poolTab(admin.page, pool);
    console.log(`GUI: admin vê ${JSON.stringify(tab)}`);
    if (!tab.save || tab.readOnly) { throw new Error('admin sem edição na aba Limites'); }
    const vcpu = tab.rows.find((r) => r.resource === 'vCPU');
    if (!vcpu || !/× 2 vCPU/.test(vcpu.value)) { throw new Error(`linha de vCPU inesperada: ${JSON.stringify(vcpu)}`); }

    const message = await admin.page.evaluate(async ({ vmid, node, timeout }) => {
        const messages = [];
        Ext.Msg.alert = (title, text) => messages.push(String(text));
        const win = Ext.create('PVE.qemu.MemoryEdit', {
            url: `/api2/extjs/nodes/${node}/qemu/${vmid}/config`,
            pveSelNode: { data: { node, vmid, type: 'qemu' } },
        });
        win.show();
        const started = Date.now();
        let field;
        while (!(field = win.down('field[name=memory]')) || Number(field.getValue()) !== 256) {
            if (Date.now() - started > timeout) { throw new Error('edição de memória não carregou a config real'); }
            await new Promise((resolve) => setTimeout(resolve, 100));
        }
        field.setValue(1024);
        win.submit();
        while (!messages.length && Date.now() - started < timeout) {
            await new Promise((resolve) => setTimeout(resolve, 100));
        }
        win.destroy();
        return messages.join(' | ');
    }, { vmid, node, timeout: TIMEOUT });
    console.log(`GUI: erro mostrado no hardware edit: ${message}`);
    if (!/limite de RAM MiB excedido/.test(message)) { throw new Error('mensagem do limite não chegou à GUI'); }

    const audit = await openAs(browser, 'audit');
    const ro = await poolTab(audit.page, pool);
    console.log(`GUI: auditor vê ${JSON.stringify(ro)}`);
    if (ro.save || !ro.readOnly) { throw new Error('auditor recebeu controles de edição'); }
    if (!ro.mode) { throw new Error('auditor não vê o modo'); }
    for (const s of [admin, audit]) {
        if (s.errors.length) { throw new Error(`erros de página (${s.user}): ${s.errors.join('; ')}`); }
    }
    console.log('GUI LAB OK: aba Limites (admin edita, auditor só lê) e erro de limite do servidor no hardware edit');
}

async function phaseOffline(browser) {
    const admin = await openAs(browser, 'admin');
    const rows = await admin.page.evaluate(async ({ timeout, offlineNode }) => {
        const panel = Ext.create('MM.panel.Updates', { renderTo: Ext.getBody(), width: 1200, height: 500 });
        const started = Date.now();
        while (Date.now() - started < timeout) {
            const rec = panel.getStore().findRecord('node', offlineNode);
            if (rec) { break; }
            await new Promise((resolve) => setTimeout(resolve, 200));
        }
        await new Promise((resolve) => setTimeout(resolve, 3000));
        return panel.getStore().getRange().map((r) => ({ node: r.get('node'), online: r.get('online'),
            last: r.get('last_result') }));
    }, { timeout: TIMEOUT, offlineNode });
    console.log(`GUI: dashboard de updates ${JSON.stringify(rows)}`);
    const off = rows.find((r) => r.node === offlineNode);
    if (!off || off.online !== false || off.last !== 'offline') { throw new Error(`${offlineNode} não aparece offline`); }
    if (rows.filter((r) => r.online).length !== rows.length - 1) { throw new Error('outros nodes deviam estar online'); }
    if (admin.errors.length) { throw new Error(`erros de página: ${admin.errors.join('; ')}`); }
    console.log(`GUI LAB OK: dashboard de updates mostra ${offlineNode} offline e os demais online`);
}

(async () => {
    const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
    try {
        if (phase === 'pool') { await phasePool(browser); }
        else if (phase === 'offline') { await phaseOffline(browser); }
        else { throw new Error(`fase desconhecida: ${phase}`); }
    } finally {
        await browser.close();
    }
})().catch((error) => {
    console.error(`GUI LAB FAIL: ${error.message}`);
    process.exit(1);
});
