const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

function harness({ failBuild = false, holdBuild = false } = {}) {
    const commands = [];
    const timers = new Map();
    const messages = [];
    const watcher = new EventEmitter();
    watcher.close = () => { watcher.closed = true; };
    const process = new EventEmitter();
    process.platform = 'darwin';
    let changed;
    let held;
    let timerId = 0;
    const context = {
        __dirname,
        process,
        console: { log: text => messages.push(text), error: text => messages.push(text) },
        setTimeout(callback) { timers.set(++timerId, callback); return timerId; },
        clearTimeout(id) { timers.delete(id); },
        require(name) {
            if (name === 'node:fs') return {
                watch(directory, options, callback) {
                    assert.equal(directory, path.resolve(__dirname, '..'));
                    assert.equal(options.recursive, true);
                    changed = callback;
                    return watcher;
                }
            };
            if (name === 'node:child_process') return {
                spawn(command, args) {
                    commands.push({ command, args });
                    const child = new EventEmitter();
                    if (command === 'bash' && holdBuild) held = child;
                    else queueMicrotask(() => child.emit('exit', command === 'bash' && failBuild ? 1 : 0));
                    return child;
                }
            };
            return require(name);
        }
    };
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'watch.js'), 'utf8'), context);
    return {
        commands, messages, process, watcher,
        change(filename) { changed('change', filename); },
        tick() {
            const callbacks = [...timers.values()];
            timers.clear();
            callbacks.forEach(callback => callback());
        },
        release() { holdBuild = false; held.emit('exit', 0); },
        recover() { failBuild = false; },
        flush: () => new Promise(resolve => setImmediate(resolve))
    };
}

test('watcher builds immediately, debounces saves, and ignores generated files', async () => {
    const h = harness();
    h.tick();
    await h.flush();
    assert.deepEqual(h.commands.map(item => item.command), ['osascript', 'bash', 'open']);
    assert.equal(h.commands[1].args[1], '--app-only');
    for (const filename of ['.build/debug/output', '.build-tests/output', 'Tests/Test.swift']) h.change(filename);
    h.tick();
    await h.flush();
    assert.equal(h.commands.length, 3);
    for (const filename of ['Sources/RaceBoxConnect/Views.swift', 'Info.plist', 'scripts/icon.swift']) h.change(filename);
    h.tick();
    await h.flush();
    assert.equal(h.commands.length, 6);
});

test('changes during a build queue one subsequent rebuild', async () => {
    const h = harness({ holdBuild: true });
    h.tick();
    await h.flush();
    h.change('Package.swift');
    h.change('Sources/RaceBoxCore/Export.swift');
    h.tick();
    await h.flush();
    assert.equal(h.commands.length, 2);
    h.release();
    await h.flush();
    h.tick();
    await h.flush();
    assert.deepEqual(h.commands.map(item => item.command), ['osascript', 'bash', 'open', 'osascript', 'bash', 'open']);
});

test('failed builds are reported, do not launch, and recover on the next save', async () => {
    const h = harness({ failBuild: true });
    h.tick();
    await h.flush();
    assert.equal(h.commands.length, 2);
    assert.ok(h.messages.some(message => message.includes('Build/relaunch failed')));
    h.recover();
    h.change('Sources/RaceBoxConnect/App.swift');
    h.tick();
    await h.flush();
    assert.equal(h.commands.at(-1).command, 'open');
});

test('stopping during a build closes the watcher and prevents relaunch', async () => {
    const h = harness({ holdBuild: true });
    h.tick();
    await h.flush();
    h.process.emit('SIGTERM');
    h.release();
    await h.flush();
    h.change('Info.plist');
    h.tick();
    await h.flush();
    assert.equal(h.watcher.closed, true);
    assert.equal(h.commands.length, 2);
});

test('file watcher errors are reported and stop watching with a failure status', () => {
    const h = harness();
    h.watcher.emit('error', new Error('Permission denied'));
    h.tick();
    assert.equal(h.process.exitCode, 1);
    assert.equal(h.watcher.closed, true);
    assert.ok(h.messages.some(message => message.includes('Permission denied')));
    assert.equal(h.commands.length, 0);
});
