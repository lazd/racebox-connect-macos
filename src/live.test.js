const assert = require("node:assert/strict");
const fs = require("node:fs");
const { EventEmitter } = require("node:events");
const { test } = require("node:test");
const vm = require("node:vm");
const { calculateChecksum } = require("./racebox-protocol");

function frame(
  messageId = 0x01,
  payload = Buffer.from(
    "a0e70c07e607010a08330837190000002aad4d0e0301ea0b" +
      "c693e10d3b376f19618c09000f0109009c0300002c0700002300000000000000" +
      "d000000088a9dd002c010059fdff7100ce032fff5600fcff",
    "hex",
  ),
) {
  const header = Buffer.from([0xb5, 0x62, 0xff, messageId, 0, 0]);
  header.writeUInt16LE(payload.length, 4);
  const body = Buffer.concat([header, payload]);
  return Buffer.concat([body, calculateChecksum(body.subarray(2))]);
}

function createCapture(outputFile, isTTY = false) {
  const files = new Map();
  const timers = new Map();
  const terminalOutput = [];
  let now = 0;
  let timerId = 0;
  const noble = new EventEmitter();
  noble.startScanning = (services, duplicates, callback) => callback();
  noble.stopScanning = () => {};
  const fakeProcess = new EventEmitter();
  fakeProcess.argv = outputFile ? ["node", "live.js", outputFile] : ["node", "live.js"];
  fakeProcess.stdout = {
    isTTY,
    columns: 100,
    rows: 24,
    write: (text) => terminalOutput.push(text),
  };
  fakeProcess.exit = (code) => {
    fakeProcess.exitCode = code;
  };
  const fakeFs = {
    mkdirSync() {},
    openSync(filename, flags) {
      assert.equal(flags, "wx");
      if (files.has(filename)) throw new Error("File already exists");
      files.set(filename, "");
      return filename;
    },
    writeSync(filename, text) {
      files.set(filename, files.get(filename) + text);
    },
    closeSync() {},
  };
  const context = vm.createContext({
    require: (name) =>
      name === "@abandonware/noble" ? noble : name === "fs" ? fakeFs : require(name),
    Buffer,
    Date: { now: () => now },
    console: { log() {}, error() {} },
    process: fakeProcess,
    setTimeout(callback) {
      timers.set(++timerId, callback);
      return timerId;
    },
    clearTimeout: (id) => timers.delete(id),
  });
  vm.runInContext(fs.readFileSync(require.resolve("./live.js"), "utf8"), context);
  const peripheral = new EventEmitter();
  const txChar = new EventEmitter();
  txChar.uuid = "6e400003b5a3f393e0a9e50e24dcca9e";
  txChar.subscribe = (callback) => callback();
  txChar.write = () => assert.fail("Live capture must not write device commands");
  peripheral.advertisement = { localName: "RaceBox Mini S test" };
  peripheral.connect = (callback) => callback();
  peripheral.disconnect = () => peripheral.emit("disconnect");
  peripheral.discoverSomeServicesAndCharacteristics = (services, characteristics, callback) => {
    assert.deepEqual(Array.from(characteristics), [txChar.uuid]);
    callback(null, [], [txChar]);
  };
  noble.emit("stateChange", "poweredOn");
  noble.emit("discover", peripheral);
  return {
    files,
    fakeProcess,
    peripheral,
    terminalOutput,
    advanceTime: (milliseconds) => {
      now += milliseconds;
    },
    receive: (data) => txChar.emit("data", data),
    stop: () => fakeProcess.emit("SIGINT"),
    timeout: () => [...timers.values()].at(-1)(),
    capture: () => JSON.parse([...files.values()][0]),
  };
}

test("streams live points immediately, ignores history, and finalizes on Ctrl+C", () => {
  const capture = createCapture();
  capture.receive(frame(0x21));
  assert.equal(capture.files.size, 0);
  const live = frame();
  capture.receive(live.subarray(0, 13));
  assert.equal(capture.files.size, 0);
  capture.receive(Buffer.concat([live.subarray(13), live]));
  assert.ok([...capture.files.values()][0].includes('"latitude":42.6719035'));
  assert.match([...capture.files.keys()][0], /^racebox_live\/2022-01-10\/live-08-51-08-.+\.json$/);
  capture.stop();
  const json = capture.capture();
  assert.equal(json.source, "live");
  assert.equal(json.pointCount, 2);
  assert.equal(json.points[0].longitude, 23.2887238);
  assert.equal(json.points[0].altMslM, 590.095);
  assert.ok(Math.abs(json.points[0].speedKmh - 0.126) < 1e-12);
  assert.equal(json.complete, true);
  assert.equal(capture.fakeProcess.exitCode, 0);
});

for (const interruption of ["disconnect", "timeout"]) {
  test(`${interruption} preserves valid JSON marked incomplete`, () => {
    const capture = createCapture();
    capture.receive(frame());
    if (interruption === "disconnect") capture.peripheral.emit("disconnect");
    else capture.timeout();
    assert.equal(capture.capture().pointCount, 1);
    assert.equal(capture.capture().complete, false);
    assert.equal(capture.fakeProcess.exitCode, 1);
  });
}

test("recovers after a bad checksum and marks capture incomplete", () => {
  const capture = createCapture();
  const corrupt = frame();
  corrupt[10] ^= 0x01;
  capture.receive(Buffer.concat([corrupt, frame()]));
  capture.stop();
  assert.equal(capture.capture().pointCount, 1);
  assert.equal(capture.capture().invalidFrames, 1);
  assert.equal(capture.capture().complete, false);
});

test("resynchronizes after an oversized frame length", () => {
  const capture = createCapture();
  capture.receive(Buffer.concat([Buffer.from("b562ff01ffff", "hex"), frame()]));
  capture.stop();
  assert.equal(capture.capture().pointCount, 1);
  assert.equal(capture.capture().invalidFrames, 1);
});

test("supports an explicit output file without overwriting existing files", () => {
  const capture = createCapture("captures/drive.json");
  capture.files.set("captures/drive.json", "original recording");
  capture.receive(frame());
  assert.equal(capture.files.get("captures/drive.json"), "original recording");
  assert.equal(capture.fakeProcess.exitCode, 1);
});

test("stopping before data arrives does not create an empty file", () => {
  const capture = createCapture();
  capture.stop();
  assert.equal(capture.files.size, 0);
  assert.equal(capture.fakeProcess.exitCode, 0);
});

function frameWithFix(status, flags) {
  const payload = Buffer.from(frame().subarray(6, -2));
  payload[20] = status;
  payload[21] = flags;
  return frame(0x01, payload);
}

for (const [status, flags] of [
  [0, 1],
  [2, 1],
  [3, 0],
  [3, 2],
]) {
  test(`does not create a file before a valid 3D fix (status=${status}, flags=${flags})`, () => {
    const capture = createCapture();
    capture.receive(frameWithFix(status, flags));
    assert.equal(capture.files.size, 0);
    assert.equal(capture.fakeProcess.exitCode, undefined);
    capture.receive(frameWithFix(3, 1));
    capture.stop();
    assert.equal(capture.capture().pointCount, 1);
    assert.equal(capture.capture().points[0].fixStatus, 3);
    assert.equal(capture.capture().complete, true);
  });
}

test("pauses logging on fix loss and resumes in the same file when fix returns", () => {
  const capture = createCapture();
  capture.receive(frameWithFix(3, 1));
  const before = [...capture.files.values()][0];
  capture.receive(frameWithFix(0, 0));
  capture.receive(frameWithFix(3, 0));
  assert.equal([...capture.files.values()][0], before);
  capture.receive(frameWithFix(3, 1));
  capture.stop();
  assert.equal(capture.files.size, 1);
  assert.equal(capture.capture().pointCount, 2);
  assert.equal(capture.capture().complete, true);
});

test("stopping while waiting for a fix leaves no file", () => {
  const capture = createCapture();
  capture.receive(frameWithFix(0, 0));
  capture.stop();
  assert.equal(capture.files.size, 0);
  assert.equal(capture.fakeProcess.exitCode, 0);
});

test("captures satellite count, accuracy, PDOP, and battery from the manufacturer sample", () => {
  const capture = createCapture();
  capture.receive(frame());
  capture.stop();
  const point = capture.capture().points[0];
  assert.equal(point.satellites, 11);
  assert.equal(point.horizontalAccuracyM, 0.924);
  assert.equal(point.verticalAccuracyM, 1.836);
  assert.equal(point.pdop, 3);
  assert.equal(point.altWgsM, 625.761);
  assert.equal(point.batteryPercent, 89);
  assert.equal(point.charging, false);
  assert.equal(point.timeAccuracyNs, 25);
  assert.equal(point.utcValid, true);
  assert.ok(Math.abs(point.speedAccuracyKmh - 0.7488) < 1e-12);
  assert.equal(point.headingAccuracyDeg, 145.26856);
});

test("refreshes the emoji dashboard in place while acquiring a fix without writing data", () => {
  const capture = createCapture(undefined, true);
  capture.receive(frameWithFix(0, 0));
  assert.equal(capture.files.size, 0);
  assert.match(capture.terminalOutput[0], /Acquiring fix/);
  assert.match(capture.terminalOutput[0], /Satellites used\s+11/);
  assert.match(capture.terminalOutput[0], /Horizontal acc\.\s+-- m/);
  assert.match(capture.terminalOutput[0], /Battery\s+89 %/);
  assert.ok(capture.terminalOutput[0].startsWith("\x1b[?25l\r\x1b[J"));
  assert.ok(
    capture.terminalOutput[0].endsWith(
      `\x1b[${capture.terminalOutput[0].split("\n").length - 1}A\r`,
    ),
  );
  capture.receive(frameWithFix(0, 0));
  assert.equal(capture.terminalOutput.length, 1);
  capture.advanceTime(250);
  capture.receive(frameWithFix(0, 0));
  assert.equal(capture.terminalOutput.length, 2);
  capture.receive(frame());
  assert.equal(capture.terminalOutput.length, 4);
  assert.match(capture.terminalOutput[3], /3D fix · Recording/);
  assert.match(
    capture.terminalOutput[3],
    /Horizontal acc\.\s+0\.92 m\s+\| Vertical acc\.\s+1\.84 m/,
  );
  assert.match(capture.terminalOutput[3], /PDOP\s+3\.00/);
  capture.receive(frameWithFix(3, 0));
  assert.match(capture.terminalOutput.at(-1), /Fix lost · Logging paused/);
  assert.match(capture.terminalOutput.at(-1), /Horizontal acc\.\s+-- m/);
  capture.receive(frame());
  assert.match(capture.terminalOutput.at(-1), /3D fix · Recording/);
  capture.stop();
  assert.equal(capture.capture().pointCount, 2);
  assert.ok(capture.terminalOutput.includes("\x1b[?25h"));
});

test("shows charging and keeps terminal output within narrow viewport bounds", () => {
  const capture = createCapture(undefined, true);
  const payload = Buffer.from(frame().subarray(6, -2));
  payload[67] = 0x80 | 42;
  capture.receive(frame(0x01, payload));
  assert.match(capture.terminalOutput[0], /Battery\s+42 %\s+\| Charging\s+Yes/);
  capture.fakeProcess.stdout.columns = 40;
  capture.fakeProcess.stdout.rows = 10;
  capture.advanceTime(250);
  capture.receive(frame(0x01, payload));
  const display = capture.terminalOutput.at(-1);
  assert.equal(display.split("\n").length, 8);
  assert.ok(display.endsWith("\x1b[7A\r"));
  for (const line of display
    .replace(/\x1b\[[?\d;]*[A-Za-z]/g, "")
    .replace(/\r/g, "")
    .split("\n")) {
    assert.ok(Array.from(line).length <= 36);
  }
  capture.stop();
  assert.equal(capture.capture().points[0].batteryPercent, 42);
  assert.equal(capture.capture().points[0].charging, true);
});

test("does not emit dashboard escape sequences when stdout is redirected", () => {
  const capture = createCapture();
  capture.receive(frame());
  capture.stop();
  assert.equal(capture.terminalOutput.length, 0);
});

test("keeps numeric precision and column positions stable across magnitudes, signs, and fix loss", () => {
  const capture = createCapture(undefined, true);
  capture.fakeProcess.stdout.columns = 120;
  const displays = [];
  const clocks = [];
  for (const large of [false, true]) {
    const payload = Buffer.from(frame().subarray(6, -2));
    payload[23] = large ? 100 : 1;
    payload.writeInt32LE(large ? -1234567890 : 1234567, 24);
    payload.writeInt32LE(large ? -876543210 : 1234567, 28);
    payload.writeInt32LE(large ? -10000000 : 1000, 36);
    payload.writeUInt32LE(large ? 12345000 : 1000, 40);
    payload.writeUInt16LE(large ? 12345 : 100, 64);
    payload.writeInt32LE(large ? 100000000 : 1000, 48);
    payload.writeInt32LE(large ? 12345000 : 100000, 52);
    payload.writeInt16LE(large ? -32768 : 1, 68);
    payload.writeInt16LE(large ? -32768 : 1, 74);
    payload[67] = large ? 100 : 1;
    payload.writeUInt32LE(large ? 4294967295 : 1, 12);
    capture.receive(frame(0x01, payload));
    displays.push(
      capture.terminalOutput
        .at(-1)
        .split("\n")
        .map((line) => line.replace(/^\S+ {2}/u, ""))
        .filter((line) =>
          /^(Satellites used|Horizontal acc\.|Speed |Heading |Latitude |Altitude MSL|G-force [XYZ]|Battery |Points saved)/.test(
            line,
          ),
        ),
    );
    clocks.push(
      capture.terminalOutput
        .at(-1)
        .split("\n")
        .map((line) => line.replace(/^\S+ {2}/u, ""))
        .find((line) => line.startsWith("UTC")),
    );
    capture.advanceTime(250);
  }
  const [small, large] = displays;
  assert.equal(small.length, 11);
  assert.equal(large.length, 11);
  assert.match(small[4], /Latitude\s+0\.1234567 °\s+\| Longitude\s+0\.1234567/);
  assert.match(large[4], /Latitude\s+-87\.6543210 °\s+\| Longitude\s+-123\.4567890/);
  assert.equal(clocks[0].length, clocks[1].length);
  assert.equal(clocks[0].indexOf("|"), small[0].indexOf("|"));
  assert.equal(clocks[1].indexOf("|"), large[0].indexOf("|"));
  assert.match(small[6], /G-force X\s+0\.001 g\s+\| Roll rate\s+0\.01/);
  assert.match(large[6], /G-force X\s+-32\.768 g\s+\| Roll rate\s+-327\.68/);
  for (let row = 0; row < small.length; row++) {
    assert.equal(small[row].length, 71, `row ${row} table width`);
    assert.equal(small[row].length, large[row].length, `row ${row} width`);
    assert.deepEqual(
      [...small[row].matchAll(/[|±%°]/g)].map((match) => match.index),
      [...large[row].matchAll(/[|±%°]/g)].map((match) => match.index),
      `row ${row} separators`,
    );
  }
  capture.receive(frameWithFix(0, 0));
  const waiting = capture.terminalOutput
    .at(-1)
    .split("\n")
    .map((line) => line.replace(/^\S+ {2}/u, ""))
    .filter((line) => /^(Horizontal acc\.|Speed |Heading |Latitude |Altitude MSL)/.test(line));
  assert.equal(waiting.length, 5);
  const validRows = large.filter((line) =>
    /^(Horizontal acc\.|Speed |Heading |Latitude |Altitude MSL)/.test(line),
  );
  for (let row = 0; row < waiting.length; row++) {
    assert.equal(waiting[row].length, validRows[row].length, `no-fix row ${row} width`);
  }
  capture.stop();
  assert.equal(capture.capture().points[0].gForceX, 0.001);
  assert.equal(capture.capture().points[1].gForceX, -32.768);
});

test("fits the complete table and footer in an 80 by 24 terminal", () => {
  const capture = createCapture(undefined, true);
  capture.fakeProcess.stdout.columns = 80;
  capture.receive(frame());
  const display = capture.terminalOutput.at(-1);
  const lines = display.split("\n");
  assert.equal(lines.length, 22);
  assert.match(display, /Measurement\s+Value Unit\s+\| Measurement\s+Value Unit/);
  assert.match(display, /🌟  Satellites used/);
  assert.match(display, /🎯  Horizontal acc\./);
  assert.match(display, /💨  Speed/);
  assert.match(display, /🧭  Heading/);
  assert.match(display, /🌍  Latitude\s+42\.6719035 °\s+\| Longitude\s+23\.2887238 °/);
  assert.match(display, /⛰️  Altitude MSL/);
  assert.match(display, /🫧  G-force X/);
  assert.match(display, /🔋  Battery/);
  assert.match(display, /💾  Points saved/);
  assert.match(display, /Points saved\s+1\s+\| Rejected frames\s+0/);
  assert.match(display, /UTC\s+2022-01-10 08:51:08 \| Time accuracy\s+25 ns/);
  assert.match(lines.at(-1), /Ctrl\+C to finish recording/);
  assert.ok(display.endsWith("\x1b[21A\r"));
  capture.stop();
});
