const assert = require('node:assert/strict');
const fs = require('node:fs');
const { EventEmitter } = require('node:events');
const { test } = require('node:test');
const vm = require('node:vm');

function createDownload(files = new Map()) {
    const writes = [];
    const messages = [];
    const timers = new Map();
    let timerId = 0;
    const noble = new EventEmitter();
    noble.stopScanning = () => {};
    const fakeFs = {
        mkdirSync() {},
        readFileSync(filename) {
            if (!files.has(filename)) throw Object.assign(new Error('File not found'), { code: 'ENOENT' });
            return files.get(filename);
        },
        openSync(filename) {
            files.set(filename, '');
            return filename;
        },
        writeSync(filename, text) {
            files.set(filename, files.get(filename) + text);
        },
        closeSync() {}
    };
    const fakeProcess = new EventEmitter();
    fakeProcess.env = {};
    fakeProcess.stdout = { write() {} };
    fakeProcess.exit = code => { fakeProcess.exitCode = code; };
    const context = vm.createContext({
        require: name => name === '@abandonware/noble' ? noble : name === 'fs' ? fakeFs : require(name),
        Buffer,
        console: { log: message => messages.push(message), error: message => messages.push(message) },
        process: fakeProcess,
        setTimeout(callback) {
            timers.set(++timerId, callback);
            return timerId;
        },
        clearTimeout: id => timers.delete(id)
    });
    vm.runInContext(fs.readFileSync(require.resolve('./index.js'), 'utf8'), context);
    const api = vm.runInContext('({ buildRaceBoxCommand, handleCharacteristics, receiveData, parseRecordingStatus })', context);
    const rxChar = {
        uuid: '6e400002b5a3f393e0a9e50e24dcca9e',
        write(frame, withoutResponse, callback) {
            writes.push(frame);
            callback();
        }
    };
    const txChar = new EventEmitter();
    txChar.uuid = '6e400003b5a3f393e0a9e50e24dcca9e';
    txChar.subscribe = callback => callback();
    const frame = (msgId, payload) => api.buildRaceBoxCommand(0xFF, msgId, payload);
    const receive = data => api.receiveData(data, rxChar);
    api.handleCharacteristics(null, [], [rxChar, txChar]);

    function begin(count, storedCount = count, recording = false) {
        receive(frame(0x02, Buffer.from([0xFF, 0x30])));
        const status = Buffer.alloc(12);
        status[0] = Number(recording);
        status[2] = 2;
        status.writeUInt32LE(storedCount, 4);
        status.writeUInt32LE(1000000, 8);
        receive(frame(0x22, status));
        const payload = Buffer.alloc(4);
        payload.writeUInt32LE(count);
        receive(frame(0x23, payload));
    }

    return {
        frame, receive, begin, writes, files, fakeProcess, api, messages,
        finish: () => receive(frame(0x02, Buffer.from([0xFF, 0x23]))),
        sessions: () => [...files.values()].map(text => JSON.parse(text)),
        timeout: () => [...timers.values()].at(-1)()
    };
}

function historyPayload(timestampMs = 376368360) {
    const payload = Buffer.alloc(80);
    payload.writeUInt32LE(timestampMs, 0);
    payload.writeUInt16LE(2026, 4);
    payload.set([10, 29, 8, 32, 30], 6);
    payload.writeInt32LE(-40000000, 16);
    payload[20] = 3;
    payload.writeInt32LE(-1221234567, 24);
    payload.writeInt32LE(371234567, 28);
    payload.writeInt32LE(123450, 36);
    payload.writeInt32LE(10000, 48);
    payload.writeInt32LE(9123456, 52);
    payload.writeInt16LE(-100, 68);
    payload.writeInt16LE(200, 70);
    payload.writeInt16LE(1000, 72);
    payload.writeInt16LE(-125, 74);
    payload.writeInt16LE(150, 76);
    payload.writeInt16LE(250, 78);
    return payload;
}

test('checks memory status after unlock before requesting history', () => {
    const download = createDownload();
    assert.equal(download.writes.length, 1);
    assert.equal(download.writes[0][3], 0x30);
    assert.equal(download.writes[0].readUInt16LE(4), 4);
    download.begin(0);
    assert.equal(download.writes.length, 3);
    assert.equal(download.writes[1][3], 0x22);
    assert.equal(download.writes[1].readUInt16LE(4), 0);
    assert.equal(download.writes[2][3], 0x23);
    assert.equal(download.writes[2].readUInt16LE(4), 0);
    download.finish();
    assert.equal(download.files.size, 0);
    assert.equal(download.fakeProcess.exitCode, 1);
});

test('does not report success when memory has recordings but download returns zero', () => {
    const download = createDownload();
    download.begin(0, 2500);
    download.finish();
    assert.equal(download.files.size, 0);
    assert.equal(download.fakeProcess.exitCode, 1);
});

test('rejects unfamiliar status layouts instead of guessing download behavior', () => {
    const download = createDownload();
    download.receive(download.frame(0x02, Buffer.from([0xFF, 0x30])));
    download.receive(download.frame(0x22, Buffer.alloc(4)));
    assert.equal(download.writes.length, 2);
    assert.equal(download.fakeProcess.exitCode, 1);
});

test('decodes history offsets, ignores live data, and preserves pause/resume within sessions', () => {
    const download = createDownload();
    download.begin(3);
    const history = download.frame(0x21, historyPayload());
    download.receive(download.frame(0x01, historyPayload()));
    assert.equal(download.files.size, 0);
    download.receive(Buffer.from([0x00, 0xB5]));
    download.receive(history.subarray(0, 17));
    download.receive(Buffer.concat([
        history.subarray(17),
        download.frame(0x26, Buffer.from([2])),
        download.frame(0x26, Buffer.from([1])),
        history,
        download.frame(0x26, Buffer.from([0])),
        download.frame(0x26, Buffer.from([1])),
        download.frame(0x21, historyPayload(376369360))
    ]));
    download.finish();
    const sessions = download.sessions();
    assert.deepEqual(sessions.map(session => session.pointCount), [2, 1]);
    assert.ok(sessions.every(session => session.complete));
    assert.deepEqual(sessions[0].points[0], {
        timestampMs: 376368360, year: 2026, month: 10, day: 29,
        hour: 8, minute: 32, second: 30, nanoseconds: -40000000,
        fixStatus: 3, latitude: 37.1234567, longitude: -122.1234567,
        altMslM: 123.45, speedKmh: 36, headingDeg: 91.23456,
        gForceX: -0.1, gForceY: 0.2, gForceZ: 1,
        rollRate: -1.25, pitchRate: 1.5, yawRate: 2.5
    });
    assert.equal(download.fakeProcess.exitCode, 0);
});

test('a new recording start separates sessions even without a stop marker', () => {
    const download = createDownload();
    download.begin(2);
    download.receive(download.frame(0x21, historyPayload()));
    download.receive(download.frame(0x26, Buffer.from([1])));
    download.receive(download.frame(0x21, historyPayload(376369360)));
    download.finish();
    assert.deepEqual(download.sessions().map(session => session.pointCount), [1, 1]);
});

for (const interruption of ['SIGINT', 'timeout', 'count exceeded']) {
    test(`${interruption} leaves valid, incomplete session JSON`, () => {
        const download = createDownload();
        download.begin(interruption === 'count exceeded' ? 0 : 2);
        download.receive(download.frame(0x21, historyPayload()));
        if (interruption === 'SIGINT') download.fakeProcess.emit('SIGINT');
        else if (interruption === 'timeout') download.timeout();
        else download.finish();
        assert.equal(download.sessions()[0].complete, false);
        assert.equal(download.sessions()[0].pointCount, 1);
        assert.notEqual(download.fakeProcess.exitCode, 0);
    });
}

test('rejects bad checksums and recovers at the next valid frame', () => {
    const download = createDownload();
    download.begin(1);
    const corrupt = download.frame(0x21, historyPayload());
    corrupt[10] ^= 0x01;
    download.receive(Buffer.concat([corrupt, download.frame(0x21, historyPayload())]));
    download.finish();
    assert.equal(download.sessions()[0].pointCount, 1);
    assert.equal(download.sessions()[0].complete, false);
    assert.equal(download.fakeProcess.exitCode, 1);
});

test('a rejected download exits without creating session files', () => {
    const download = createDownload();
    download.begin(1);
    download.receive(download.frame(0x03, Buffer.from([0xFF, 0x23])));
    assert.equal(download.files.size, 0);
    assert.equal(download.fakeProcess.exitCode, 1);
});

test('manufacturer status example uses payload offsets 4 and 8 and security bits 0 and 1', () => {
    const download = createDownload();
    const frame = Buffer.from('b562ff220c00002201006506010000000300bf74', 'hex');
    const status = download.api.parseRecordingStatus(frame.subarray(6, -2));
    assert.equal(status.recording, false);
    assert.equal(status.memoryUsedPercent, 34);
    assert.equal(status.securityEnabled, true);
    assert.equal(status.memoryUnlocked, false);
    assert.equal(status.storedRecords, 67173);
    assert.equal(status.capacityRecords, 196608);
});

test('captured Mini S status means empty, unsecured, unlocked memory', () => {
    const download = createDownload();
    const frame = Buffer.from('b562ff220c0000000200000000000000030032b0', 'hex');
    const status = download.api.parseRecordingStatus(frame.subarray(6, -2));
    assert.equal(status.securityEnabled, false);
    assert.equal(status.memoryUnlocked, true);
    assert.equal(status.storedRecords, 0);
    assert.equal(status.memoryUsedPercent, 0);
    assert.equal(status.capacityRecords, 196608);
});

test('manufacturer command examples match literal wire packets', () => {
    const download = createDownload();
    assert.equal(download.frame(0x22).toString('hex'), 'b562ff2200002162');
    assert.equal(download.frame(0x23).toString('hex'), 'b562ff2300002265');
    assert.equal(download.frame(0x30, Buffer.from('40e20100', 'hex')).toString('hex'), 'b562ff30040040e201005608');
});

test('manufacturer download-count example is an upper bound, not an exact total', () => {
    const download = createDownload();
    download.begin(780);
    download.receive(Buffer.from('b562ff2304000c030000353e', 'hex'));
    download.receive(download.frame(0x21, historyPayload()));
    download.finish();
    assert.equal(download.sessions()[0].complete, true);
    assert.equal(download.fakeProcess.exitCode, 0);
});

test('history resumes implicitly after pause so the next start begins a new session', () => {
    const download = createDownload();
    download.begin(3);
    download.receive(download.frame(0x21, historyPayload()));
    download.receive(download.frame(0x26, Buffer.from([2])));
    download.receive(download.frame(0x21, historyPayload()));
    download.receive(download.frame(0x26, Buffer.from([1])));
    download.receive(download.frame(0x21, historyPayload(376369360)));
    download.finish();
    assert.deepEqual(download.sessions().map(session => session.pointCount), [2, 1]);
});

test('decodes the manufacturer telemetry sample independently of synthetic offsets', () => {
    const download = createDownload();
    const sample = Buffer.from(
        'b562ff015000a0e70c07e607010a08330837190000002aad4d0e0301ea0b' +
        'c693e10d3b376f19618c09000f0109009c0300002c0700002300000000000000' +
        'd000000088a9dd002c010059fdff7100ce032fff5600fcff06db', 'hex'
    );
    assert.equal(sample.length, 88);
    download.begin(1);
    download.receive(sample);
    assert.equal(download.files.size, 0);
    download.receive(download.frame(0x21, sample.subarray(6, -2)));
    download.finish();
    const point = download.sessions()[0].points[0];
    assert.equal(point.timestampMs, 118286240);
    assert.equal(point.nanoseconds, 239971626);
    assert.equal(point.latitude, 42.6719035);
    assert.equal(point.longitude, 23.2887238);
    assert.equal(point.altMslM, 590.095);
    assert.ok(Math.abs(point.speedKmh - 0.126) < 1e-12);
    assert.equal(point.headingDeg, 0);
    assert.equal(point.gForceX, -0.003);
    assert.equal(point.gForceY, 0.113);
    assert.equal(point.gForceZ, 0.974);
    assert.equal(point.rollRate, -2.09);
    assert.equal(point.pitchRate, 0.86);
    assert.equal(point.yawRate, -0.04);
    assert.equal(download.fakeProcess.exitCode, 0);
});

test('locked status does not proceed to download', () => {
    const download = createDownload();
    download.receive(download.frame(0x02, Buffer.from([0xFF, 0x30])));
    download.receive(Buffer.from('b562ff220c00002201006506010000000300bf74', 'hex'));
    assert.equal(download.writes.length, 2);
    assert.equal(download.fakeProcess.exitCode, 1);
});

test('uses the recording date, with zero-padded month, day, and time', () => {
    const download = createDownload();
    download.begin(1);
    const payload = historyPayload();
    payload.set([1, 2, 3, 4, 5], 6);
    download.receive(download.frame(0x21, payload));
    download.finish();
    assert.deepEqual([...download.files.keys()], ['racebox_sessions/2026-01-02/session-03-04-05-376368360.json']);
});

test('rerunning skips complete recordings without changing their contents', () => {
    const first = createDownload();
    first.begin(1);
    first.receive(first.frame(0x21, historyPayload()));
    first.finish();
    const original = [...first.files.entries()];
    const second = createDownload(first.files);
    second.begin(1);
    second.receive(second.frame(0x21, historyPayload()));
    second.finish();
    assert.deepEqual([...second.files.entries()], original);
    assert.ok(second.messages.some(message => /⏭️\s+Skipping/.test(message)));
    assert.ok(second.messages.some(message => message.includes('0 recordings saved · 1 already complete')));
    assert.equal(second.fakeProcess.exitCode, 0);
});

test('retries incomplete recordings at the same path instead of creating duplicates', () => {
    const first = createDownload();
    first.begin(2);
    first.receive(first.frame(0x21, historyPayload()));
    first.fakeProcess.emit('SIGINT');
    assert.equal(first.sessions()[0].complete, false);
    const second = createDownload(first.files);
    second.begin(2);
    second.receive(second.frame(0x21, historyPayload()));
    second.receive(second.frame(0x21, historyPayload(376368400)));
    second.finish();
    assert.equal(second.files.size, 1);
    assert.equal(second.sessions()[0].complete, true);
    assert.equal(second.sessions()[0].pointCount, 2);
});

for (const contents of ['{"points":[', 'null', '{"complete":"true"}']) {
    test(`replaces invalid or not-explicitly-complete JSON: ${contents}`, () => {
        const files = new Map([['racebox_sessions/2026-10-29/session-08-32-30-376368360.json', contents]]);
        const download = createDownload(files);
        download.begin(1);
        download.receive(download.frame(0x21, historyPayload()));
        download.finish();
        assert.equal(download.files.size, 1);
        assert.equal(download.sessions()[0].complete, true);
        assert.equal(download.sessions()[0].pointCount, 1);
    });
}

test('skips a complete session then saves a new session under its own date', () => {
    const first = createDownload();
    first.begin(1);
    first.receive(first.frame(0x21, historyPayload()));
    first.finish();
    const existing = [...first.files.values()][0];
    const second = createDownload(first.files);
    second.begin(2);
    second.receive(second.frame(0x21, historyPayload()));
    second.receive(second.frame(0x26, Buffer.from([0])));
    const nextDay = historyPayload(462768360);
    nextDay[7] = 30;
    second.receive(second.frame(0x26, Buffer.from([1])));
    second.receive(second.frame(0x21, nextDay));
    second.finish();
    assert.equal([...second.files.values()][0], existing);
    assert.equal(second.files.size, 2);
    assert.ok(second.files.has('racebox_sessions/2026-10-30/session-08-32-30-462768360.json'));
    assert.ok(second.messages.some(message => message.includes('1 recordings saved · 1 already complete')));
});

test('an ongoing recording remains incomplete so subsequent runs can fetch appended points', () => {
    const download = createDownload();
    download.begin(1, 1, true);
    download.receive(download.frame(0x21, historyPayload()));
    download.finish();
    assert.equal(download.sessions()[0].complete, false);
    assert.equal(download.fakeProcess.exitCode, 0);
});