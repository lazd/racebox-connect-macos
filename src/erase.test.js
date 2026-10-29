const assert = require("node:assert/strict");
const fs = require("node:fs");
const { EventEmitter } = require("node:events");
const { test } = require("node:test");
const vm = require("node:vm");
const { calculateChecksum } = require("./racebox-protocol");

function frame(messageId, payload = Buffer.alloc(0)) {
  const header = Buffer.from([0xb5, 0x62, 0xff, messageId, 0, 0]);
  header.writeUInt16LE(payload.length, 4);
  const body = Buffer.concat([header, payload]);
  return Buffer.concat([body, calculateChecksum(body.subarray(2))]);
}

function createErase({ isTTY = true, securityCode } = {}) {
  const writes = [];
  const messages = [];
  const timers = new Map();
  let answer;
  let bluetoothLoads = 0;
  let scans = 0;
  let timerId = 0;
  const prompt = new EventEmitter();
  prompt.question = (question, callback) => { answer = callback; };
  prompt.close = () => prompt.emit("close");
  const fakeProcess = new EventEmitter();
  fakeProcess.env = securityCode === undefined ? {} : { RACEBOX_SECURITY_CODE: securityCode };
  fakeProcess.stdin = { isTTY };
  fakeProcess.stdout = {};
  fakeProcess.exit = code => { fakeProcess.exitCode = code; };
  const noble = new EventEmitter();
  noble.startScanning = (services, duplicates, callback) => { scans++; callback(); };
  noble.stopScanning = () => {};
  const rxChar = {
    uuid: "6e400002b5a3f393e0a9e50e24dcca9e",
    write(data, withoutResponse, callback) { writes.push(data); callback(); },
  };
  const txChar = new EventEmitter();
  txChar.uuid = "6e400003b5a3f393e0a9e50e24dcca9e";
  txChar.subscribe = callback => callback();
  const peripheral = new EventEmitter();
  peripheral.advertisement = { localName: "RaceBox Mini S test" };
  peripheral.connect = callback => callback();
  peripheral.disconnect = () => peripheral.emit("disconnect");
  peripheral.discoverSomeServicesAndCharacteristics = (services, characteristics, callback) => callback(null, [], [rxChar, txChar]);
  const context = vm.createContext({
    require(name) {
      if (name === "@abandonware/noble") { bluetoothLoads++; return noble; }
      if (name === "node:readline") return { createInterface: () => prompt };
      if (name === "./racebox-protocol") return { calculateChecksum };
      assert.fail(`Unexpected dependency: ${name}`);
    },
    Buffer,
    process: fakeProcess,
    console: { log: message => messages.push(message), error: message => messages.push(message) },
    setTimeout(callback, delay) { timers.set(++timerId, { callback, delay }); return timerId; },
    clearTimeout: id => timers.delete(id),
  });
  vm.runInContext(fs.readFileSync(require.resolve("./erase.js"), "utf8"), context);
  const receive = data => txChar.emit("data", data);
  return {
    writes, messages, fakeProcess, prompt, peripheral,
    get bluetoothLoads() { return bluetoothLoads; },
    get scans() { return scans; },
    confirm(text = "ERASE") { answer(text); },
    connect() { noble.emit("stateChange", "poweredOn"); noble.emit("discover", peripheral); },
    receive,
    ack: command => receive(frame(0x02, Buffer.from([0xff, command]))),
    status({ recording = 0, flags = 2, count = 100 } = {}) {
      const payload = Buffer.alloc(12);
      payload[0] = recording;
      payload[2] = flags;
      payload.writeUInt32LE(count, 4);
      receive(frame(0x22, payload));
    },
    timeout() { [...timers.values()].at(-1).callback(); },
    get timeoutDelay() { return [...timers.values()].at(-1)?.delay; },
  };
}

test("requires exact interactive confirmation before loading Bluetooth", () => {
  for (const text of ["", "yes", "erase"]) {
    const erase = createErase();
    assert.equal(erase.bluetoothLoads, 0);
    erase.confirm(text);
    assert.equal(erase.bluetoothLoads, 0);
    assert.equal(erase.fakeProcess.exitCode, 0);
  }
  const erase = createErase();
  erase.prompt.close();
  assert.equal(erase.bluetoothLoads, 0);
  assert.equal(erase.fakeProcess.exitCode, 0);
});

test("refuses noninteractive input and invalid security codes without Bluetooth", () => {
  for (const options of [{ isTTY: false }, { securityCode: "-1" }, { securityCode: "4294967296" }, { securityCode: "nope" }]) {
    const erase = createErase(options);
    assert.equal(erase.fakeProcess.exitCode, 1);
    assert.equal(erase.bluetoothLoads, 0);
  }
});

test("unlocks, checks stopped memory, sends the literal erase command, and verifies empty memory", () => {
  const erase = createErase({ securityCode: "123456" });
  erase.confirm();
  erase.connect();
  assert.equal(erase.scans, 1);
  assert.equal(erase.writes[0][3], 0x30);
  assert.equal(erase.writes[0].readUInt32LE(6), 123456);
  erase.ack(0x30);
  assert.equal(erase.writes[1][3], 0x22);
  erase.status();
  assert.equal(erase.writes[2].toString("hex"), "b562ff2400002368");
  assert.equal(erase.timeoutDelay, 180000);
  const progress = frame(0x24, Buffer.from([100]));
  erase.receive(progress.subarray(0, 5));
  erase.receive(progress.subarray(5));
  assert.equal(erase.fakeProcess.exitCode, undefined);
  erase.ack(0x24);
  assert.equal(erase.writes[3][3], 0x22);
  assert.equal(erase.fakeProcess.exitCode, undefined);
  erase.status({ count: 0 });
  assert.equal(erase.fakeProcess.exitCode, 0);
  assert.ok(erase.messages.some(message => message.includes("verified empty")));
});

test("never erases active, paused, locked, malformed, or rejected memory", () => {
  for (const condition of ["active", "paused", "locked", "malformed", "rejected", "bad-checksum"]) {
    const erase = createErase();
    erase.confirm();
    erase.connect();
    if (condition === "rejected") erase.receive(frame(0x03, Buffer.from([0xff, 0x30])));
    else {
      erase.ack(0x30);
      if (condition === "malformed") erase.receive(frame(0x22, Buffer.alloc(11)));
      else if (condition === "bad-checksum") {
        const corrupt = frame(0x22, Buffer.alloc(12));
        corrupt[6] ^= 1;
        erase.receive(corrupt);
      } else erase.status({ recording: condition === "active" ? 1 : condition === "paused" ? 2 : 0, flags: condition === "locked" ? 1 : 2 });
    }
    assert.equal(erase.fakeProcess.exitCode, 1, condition);
    assert.ok(erase.writes.every(command => command[3] !== 0x24), condition);
  }
});

test("does not claim success on interruption, timeout, invalid progress, rejection, or failed verification", () => {
  for (const condition of ["interrupt", "disconnect", "timeout", "progress", "rejected", "not-empty"]) {
    const erase = createErase();
    erase.confirm();
    erase.connect();
    erase.ack(0x30);
    erase.status();
    if (condition === "interrupt") erase.fakeProcess.emit("SIGINT");
    else if (condition === "disconnect") erase.peripheral.emit("disconnect");
    else if (condition === "timeout") erase.timeout();
    else if (condition === "progress") erase.receive(frame(0x24, Buffer.from([101])));
    else if (condition === "rejected") erase.receive(frame(0x03, Buffer.from([0xff, 0x24])));
    else { erase.ack(0x24); erase.status({ count: 1 }); }
    assert.ok(erase.fakeProcess.exitCode > 0, condition);
    assert.ok(!erase.messages.some(message => message.includes("verified empty")), condition);
    assert.ok(erase.messages.some(message => message.includes("unverified")), condition);
  }
});