#!/usr/bin/env node
/* Static i18n guard.
 *
 * Allowlist for literals outside MM.t(): PVE-owned gettext() strings, the
 * File Restore label supplied by PVE, punctuation-only toolbar markers, and
 * '-' used as an empty value. Technical literals such as URLs, CSS, itemId,
 * dataIndex, API paths, enum values and backend messages are not user copy.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
const languages = ['en', 'pt_BR', 'es'];
const context = { MM: { i18n: { catalogs: {} } } };
vm.createContext(context);
for (const language of languages) {
    const file = path.join(root, 'js', 'src', 'i18n', `${language}.js`);
    if (!fs.existsSync(file)) { throw new Error(`missing catalog: ${file}`); }
    vm.runInContext(fs.readFileSync(file, 'utf8'), context, { filename: file });
}

const catalogs = context.MM.i18n.catalogs;
const keySets = Object.fromEntries(languages.map((language) => [
    language, new Set(Object.keys(catalogs[language] || {})),
]));
const baseKeys = keySets.en;
for (const language of languages.slice(1)) {
    const missing = [...baseKeys].filter((key) => !keySets[language].has(key));
    const extra = [...keySets[language]].filter((key) => !baseKeys.has(key));
    if (missing.length || extra.length) {
        throw new Error(`${language} catalog differs; missing=${missing.join(',')} extra=${extra.join(',')}`);
    }
}

const sources = fs.readdirSync(path.join(root, 'js', 'src'))
    .filter((name) => name.endsWith('.js'))
    .map((name) => path.join(root, 'js', 'src', name));
const used = new Set();
const missing = [];
const visible = [];
for (const file of sources) {
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    lines.forEach((line, index) => {
        for (const match of line.matchAll(/MM\.t\(\s*['"]([^'"]+)['"]/g)) {
            used.add(match[1]);
            if (!baseKeys.has(match[1])) { missing.push(`${file}:${index + 1}: ${match[1]}`); }
        }
        const property = line.match(/\b(?:text|title|tooltip|fieldLabel|boxLabel|emptyText|regexText|html)\s*:\s*(['"])(.*?)\1/);
        if (!property) { return; }
        const value = property[2];
        const allowed = value === '-' || value === '—' || value === '->'
            || /gettext\(['"]File Restore['"]\)/.test(line)
            || /^[\s\p{P}\p{S}]*$/u.test(value);
        if (!allowed) { visible.push(`${file}:${index + 1}: ${value}`); }
    });
}
if (missing.length) { throw new Error(`MM.t() keys missing from en catalog:\n${missing.join('\n')}`); }
if (visible.length) {
    throw new Error(`visible literals outside MM.t() (see allowlist in this file):\n${visible.join('\n')}`);
}

console.log(`UI i18n catalogs OK: ${baseKeys.size} keys, ${used.size} source keys, languages en/pt_BR/es`);
