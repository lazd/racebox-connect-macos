const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const directory = path.resolve(__dirname, '../docs');
const html = fs.readFileSync(path.join(directory, 'index.html'), 'utf8');

test('website assets and links work under a GitHub Pages project path', () => {
    const base = new URL('https://lazd.github.io/racebox-connect-macos/');
    const attributes = [...html.matchAll(/\b(?:href|src)="([^"]+)"/g)];
    assert.ok(attributes.length > 0);
    for (const [, value] of attributes) {
        const url = new URL(value, base);
        if (url.origin !== base.origin) continue;
        assert.ok(url.pathname.startsWith(base.pathname), `${value} escapes the project path`);
        const relative = decodeURIComponent(url.pathname.slice(base.pathname.length));
        const file = path.join(directory, relative || 'index.html');
        assert.ok(fs.statSync(file).isFile(), `${value} must resolve to a file`);
    }
});

test('website navigation targets exist and screenshots have alt text', () => {
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(([, id]) => id);
    assert.equal(new Set(ids).size, ids.length, 'IDs must be unique');
    for (const [, target] of html.matchAll(/\bhref="#([^"]+)"/g)) {
        assert.ok(ids.includes(target), `Missing navigation target ${target}`);
    }
    for (const [image] of html.matchAll(/<img\b[^>]*>/g)) {
        assert.match(image, /\balt="[^"]*"/);
    }
    for (const view of ['dashboard', 'recordings', 'session', 'preferences', 'charts']) {
        assert.ok(html.includes(`src="./assets/${view}.png"`), `Missing ${view} screenshot thumbnail`);
    }
});

test('download buttons target the latest release DMG produced by the native build', () => {
    const buttons = [...html.matchAll(/<a\s+class="button primary"\s+href="([^"]+)"/g)];
    assert.equal(buttons.length, 2);
    for (const [, href] of buttons) {
        const url = new URL(href);
        assert.equal(url.origin, 'https://github.com');
        assert.equal(decodeURIComponent(url.pathname),
            '/lazd/racebox-connect-macos/releases/latest/download/RaceBoxConnect.dmg');
    }
    const build = fs.readFileSync(path.resolve(__dirname, '../macos/scripts/build.sh'), 'utf8');
    assert.ok(build.includes('$DIST/RaceBoxConnect.dmg'), 'Release asset must match the build output');
});

test('both download buttons track file downloads without blocking navigation', () => {
    const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
    const links = [...html.matchAll(/<a\s+class="button primary"\s+href="([^"]+)"/g)]
        .map(([, href]) => ({
            href,
            textContent: '\n Download   for macOS \n',
            addEventListener(type, handler) {
                assert.equal(type, 'click');
                this.click = handler;
            },
        }));
    const events = [];
    const window = { gtag: (...args) => events.push(args) };
    vm.runInNewContext(scripts.at(-1)[1], {
        window,
        document: {
            querySelectorAll(selector) {
                assert.equal(selector, 'a.button.primary');
                return links;
            },
        },
    });
    assert.equal(links.length, 2);
    for (const link of links) {
        link.click({ currentTarget: link });
        const [command, name, parameters] = events.at(-1);
        assert.equal(command, 'event');
        assert.equal(name, 'file_download');
        assert.deepEqual({ ...parameters }, {
            file_name: 'RaceBoxConnect.dmg',
            file_extension: 'dmg',
            link_url: link.href,
            link_text: 'Download for macOS',
            transport_type: 'beacon',
        });
    }
    assert.equal(events.length, 2);
    delete window.gtag;
    for (const link of links) {
        assert.doesNotThrow(() => link.click({ currentTarget: link }));
    }
    assert.equal(events.length, 2);
});
