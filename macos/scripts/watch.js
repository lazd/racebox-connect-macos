const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const app = path.join(root, 'dist/RaceBox Connect.app');
const inputs = new Set(['Package.swift', 'Package.resolved', 'Info.plist', 'scripts/build.sh', 'scripts/icon.swift']);
let timer;
let rebuilding = false;
let pending = false;
let stopped = false;

const quitScript = `
on run argv
    set appPath to item 1 of argv
    if application appPath is running then
        with timeout of 120 seconds
            tell application appPath to quit
        end timeout
        repeat 100 times
            if not (application appPath is running) then return
            delay 0.1
        end repeat
        error "App is still running. Confirm Quit rather than Keep Open, then save again to retry."
    end if
end run
`;

function run(command, args) {
    return new Promise((resolve, reject) => {
        const child = spawn(command, args, { cwd: root, stdio: 'inherit' });
        child.once('error', reject);
        child.once('exit', (code, signal) => {
            if (code === 0) resolve();
            else reject(new Error(`${command} ${args[0]} exited with ${signal || code}`));
        });
    });
}

function schedule() {
    if (stopped) return;
    pending = true;
    clearTimeout(timer);
    timer = setTimeout(rebuild, 300);
}

async function rebuild() {
    if (stopped || rebuilding || !pending) return;
    pending = false;
    rebuilding = true;
    console.log('[watch:mac] Rebuilding; allow the app to quit if a confirmation appears.');
    try {
        await run('osascript', ['-e', quitScript, app]);
        if (stopped) return;
        await run('bash', ['macos/scripts/build.sh', '--app-only']);
        if (stopped) return;
        await run('open', [app]);
        console.log('[watch:mac] App ready; watching for changes.');
    } catch (error) {
        console.error(`[watch:mac] Build/relaunch failed: ${error.message}. Save a watched file to retry.`);
    } finally {
        rebuilding = false;
        if (pending && !stopped) schedule();
    }
}

if (process.platform !== 'darwin') {
    console.error('[watch:mac] This task requires macOS.');
    process.exitCode = 1;
} else {
    const watcher = fs.watch(path.join(root, 'macos'), { recursive: true }, (_, filename) => {
        if (!filename || filename.startsWith('Sources/') || inputs.has(filename)) schedule();
    });
    function stop() {
        stopped = true;
        clearTimeout(timer);
        watcher.close();
        console.log('[watch:mac] Stopping; any current command will finish without relaunching the app.');
    }
    watcher.on('error', error => {
        console.error(`[watch:mac] File watcher failed: ${error.message}`);
        process.exitCode = 1;
        stop();
    });
    process.once('SIGINT', stop);
    process.once('SIGTERM', stop);
    console.log('[watch:mac] Watching macOS sources, package configuration, app metadata, and icon/build scripts.');
    schedule();
}
