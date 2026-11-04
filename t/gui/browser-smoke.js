const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(__dirname, 'browser.js'), 'utf8');
const required = [
    'chromium.launch',
    'timeout: TIMEOUT',
    'page.goto',
    'waitForFunction',
    'locator',
    "page.on('console'",
    'main().catch',
];

for (const marker of required) {
    if (!source.includes(marker)) {
        throw new Error(`browser.js sem marcador estrutural: ${marker}`);
    }
}
if (source.includes('})();')) {
    throw new Error('browser.js contém o fechamento executável inválido');
}
console.log('browser driver smoke: OK');
