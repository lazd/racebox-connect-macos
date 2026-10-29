const noble = require("@abandonware/noble");
const fs = require("fs");
const path = require("path");
const { randomUUID } = require("crypto");
const { calculateChecksum, parseDataFrame } = require("./racebox-protocol");

const UART_SERVICE_UUID = "6e400001b5a3f393e0a9e50e24dcca9e";
const UART_TX_CHAR_UUID = "6e400003b5a3f393e0a9e50e24dcca9e";

let device;
let receiveBuffer = Buffer.alloc(0);
let filename;
let fileDescriptor = null;
let pointCount = 0;
let invalidFrames = 0;
let hasFix = false;
let lastStatusAt = -Infinity;
let statusVisible = false;
let stopped = false;
let watchdog;

function clearStatus() {
  if (!statusVisible) return;
  process.stdout.write("\r\x1b[J");
  statusVisible = false;
}

function report(message, error = false) {
  clearStatus();
  if (error) console.error(message);
  else console.log(message);
}

function renderStatus(point, fixValid, force = false) {
  if (!process.stdout.isTTY) return;
  const now = Date.now();
  if (!force && now - lastStatusAt < 250) return;
  lastStatusAt = now;
  const numeric = (number, digits, valid = true) => (valid ? number.toFixed(digits) : "--");
  const value = (number, digits = 2) => numeric(number, digits, fixValid);
  const cell = (label, reading, unit = "") =>
    `${label.padEnd(15)} ${String(reading).padStart(13)} ${unit.padEnd(4)}`;
  const row = (emoji, left, right) => `${emoji}  ${cell(...left)} | ${cell(...right)}`;
  const count = (number) => number.toLocaleString("en-US");
  const pad = (number) => String(number).padStart(2, "0");
  const utc = point.utcValid
    ? `${point.year}-${pad(point.month)}-${pad(point.day)} ${pad(point.hour)}:${pad(point.minute)}:${pad(point.second)}`
    : "Waiting for UTC";
  const lines = [
    "\n🎥 RaceBox Mini S · Live Capture\n",
    `🛰️  ${fixValid ? "3D fix · Recording" : pointCount ? "Fix lost · Logging paused" : "Acquiring fix · Waiting to record"}`,
    "",
    `    ${cell("Measurement", "Value", "Unit")} | ${cell("Measurement", "Value", "Unit")}`,
    `    ${"-".repeat(34)}-+-${"-".repeat(34)}`,
    row("🌟", ["Satellites used", point.satellites], ["PDOP", value(point.pdop)]),
    row(
      "🎯",
      ["Horizontal acc.", value(point.horizontalAccuracyM), "m"],
      ["Vertical acc.", value(point.verticalAccuracyM), "m"],
    ),
    row(
      "💨",
      ["Speed", value(point.speedKmh, 1), "km/h"],
      ["Speed accuracy", value(point.speedAccuracyKmh, 1), "km/h"],
    ),
    row(
      "🧭",
      ["Heading", value(point.headingDeg, 1), "°"],
      ["Heading acc.", value(point.headingAccuracyDeg, 1), "°"],
    ),
    row(
      "🌍",
      ["Latitude", value(point.latitude, 7), "°"],
      ["Longitude", value(point.longitude, 7), "°"],
    ),
    row(
      "⛰️ ",
      ["Altitude MSL", value(point.altMslM, 1), "m"],
      ["Altitude WGS84", value(point.altWgsM, 1), "m"],
    ),
    row(
      "🫧",
      ["G-force X", numeric(point.gForceX, 3), "g"],
      ["Roll rate", numeric(point.rollRate, 2), "°/s"],
    ),
    row(
      "🫧",
      ["G-force Y", numeric(point.gForceY, 3), "g"],
      ["Pitch rate", numeric(point.pitchRate, 2), "°/s"],
    ),
    row(
      "🫧",
      ["G-force Z", numeric(point.gForceZ, 3), "g"],
      ["Yaw rate", numeric(point.yawRate, 2), "°/s"],
    ),
    row("🔋", ["Battery", point.batteryPercent, "%"], ["Charging", point.charging ? "Yes" : "No"]),
    row("💾", ["Points saved", count(pointCount)], ["Rejected frames", count(invalidFrames)]),
    `🕰️   ${"UTC".padEnd(14)} ${utc.padStart(19)} | ${cell("Time accuracy", numeric(point.timeAccuracyNs, 0, point.utcValid), "ns")}`,
    "\n🎀 Ctrl+C to finish recording",
  ];
  const width = Math.max(0, (process.stdout.columns || 80) - 4);
  const visible = lines
    .flatMap((line) => line.split("\n"))
    .slice(0, Math.max(1, (process.stdout.rows || 24) - 2))
    .map((line) => Array.from(line).slice(0, width).join(""));
  process.stdout.write(
    `\x1b[?25l\r\x1b[J${visible.join("\n")}${visible.length > 1 ? `\x1b[${visible.length - 1}A` : ""}\r`,
  );
  statusVisible = true;
}

function finishCapture(complete, reason, exitCode = 0) {
  if (stopped) return;
  stopped = true;
  clearTimeout(watchdog);
  clearStatus();
  if (process.stdout.isTTY) process.stdout.write("\x1b[?25h");
  complete = complete && invalidFrames === 0;
  if (fileDescriptor !== null) {
    try {
      fs.writeSync(
        fileDescriptor,
        `\n],"pointCount":${pointCount},"complete":${complete},"invalidFrames":${invalidFrames},"endReason":${JSON.stringify(reason)}}\n`,
      );
    } catch (error) {
      report(`❌ Could not finalize JSON: ${error.message}`, true);
      exitCode = 1;
    } finally {
      fs.closeSync(fileDescriptor);
      fileDescriptor = null;
    }
  }
  console.log(
    `\n${complete && exitCode === 0 ? "✅" : "⚠️"} ${reason}\n📊 ${pointCount.toLocaleString()} live points saved${invalidFrames ? `; ${invalidFrames} invalid frames rejected` : ""}.${filename ? `\n📁 ${filename}` : "\n📁 No file created: no points with a valid GNSS fix received."}`,
  );
  if (device) device.disconnect();
  noble.stopScanning();
  process.exit(exitCode);
}

function resetWatchdog() {
  clearTimeout(watchdog);
  watchdog = setTimeout(
    () => finishCapture(false, "No live data received for 30 seconds", 1),
    30000,
  );
}

function savePoint(point) {
  if (fileDescriptor === null) {
    const pad = (value) => String(value).padStart(2, "0");
    const date = `${String(point.year).padStart(4, "0")}-${pad(point.month)}-${pad(point.day)}`;
    const time = `${pad(point.hour)}-${pad(point.minute)}-${pad(point.second)}`;
    filename =
      process.argv[2] || path.join("racebox_live", date, `live-${time}-${randomUUID()}.json`);
    fs.mkdirSync(path.dirname(filename), { recursive: true });
    fileDescriptor = fs.openSync(filename, "wx");
    fs.writeSync(fileDescriptor, '{"source":"live","points":[\n');
    report(`📥 Streaming live points to ${filename}`);
  }
  fs.writeSync(fileDescriptor, `${pointCount ? ",\n" : ""}${JSON.stringify(point)}`);
  pointCount++;
}

function receiveData(data) {
  receiveBuffer = Buffer.concat([receiveBuffer, data]);
  while (receiveBuffer.length >= 2 && !stopped) {
    const syncIndex = receiveBuffer.indexOf(Buffer.from([0xb5, 0x62]));
    if (syncIndex < 0) {
      receiveBuffer = receiveBuffer.subarray(
        receiveBuffer.length - (receiveBuffer.at(-1) === 0xb5 ? 1 : 0),
      );
      return;
    }
    receiveBuffer = receiveBuffer.subarray(syncIndex);
    if (receiveBuffer.length < 6) return;
    const length = receiveBuffer.readUInt16LE(4) + 8;
    if (length > 512) {
      invalidFrames++;
      report("⚠️ Invalid frame length; resynchronizing.", true);
      receiveBuffer = receiveBuffer.subarray(1);
      continue;
    }
    if (receiveBuffer.length < length) return;
    const frame = receiveBuffer.subarray(0, length);
    if (!calculateChecksum(frame.subarray(2, -2)).equals(frame.subarray(-2))) {
      invalidFrames++;
      report("⚠️ Ignoring frame with invalid checksum.", true);
      receiveBuffer = receiveBuffer.subarray(1);
      continue;
    }
    receiveBuffer = receiveBuffer.subarray(length);
    const point = parseDataFrame(frame, 0x01);
    if (point) {
      resetWatchdog();
      Object.assign(point, {
        satellites: frame.readUInt8(29),
        horizontalAccuracyM: frame.readUInt32LE(46) / 1000,
        verticalAccuracyM: frame.readUInt32LE(50) / 1000,
        speedAccuracyKmh: (frame.readUInt32LE(62) * 3.6) / 1000,
        headingAccuracyDeg: frame.readUInt32LE(66) / 100000,
        pdop: frame.readUInt16LE(70) / 100,
        altWgsM: frame.readInt32LE(38) / 1000,
        batteryPercent: frame.readUInt8(73) & 0x7f,
        charging: (frame.readUInt8(73) & 0x80) !== 0,
        utcValid: (frame.readUInt8(17) & 0x03) === 0x03,
        timeAccuracyNs: frame.readUInt32LE(18),
      });
      const fixValid = point.fixStatus === 3 && (frame[27] & 0x01) !== 0;
      const fixChanged = fixValid !== hasFix;
      if (!fixValid) {
        if (hasFix && !process.stdout.isTTY) report("🛰️ GNSS fix lost. Logging paused...");
        hasFix = false;
        renderStatus(point, false, fixChanged || !statusVisible);
        continue;
      }
      if (!hasFix && !process.stdout.isTTY)
        report("🛰️ Valid 3D GNSS fix acquired. Logging live data...");
      hasFix = true;
      try {
        savePoint(point);
        renderStatus(point, true, fixChanged || !statusVisible);
      } catch (error) {
        finishCapture(false, `File write failed: ${error.message}`, 1);
      }
    } else if (frame[2] === 0xff && frame[3] === 0x01) {
      invalidFrames++;
      report("⚠️ Ignoring live frame with unexpected payload length.", true);
    }
  }
}

process.on("SIGINT", () => finishCapture(true, "Live recording stopped", 0));
process.on("SIGTERM", () => finishCapture(true, "Live recording stopped", 0));

noble.on("stateChange", (state) => {
  if (stopped) return;
  if (state === "poweredOn") {
    console.log("🔎 Scanning for RaceBox Mini S hardware...");
    resetWatchdog();
    noble.startScanning([UART_SERVICE_UUID], false, (error) => {
      if (error) finishCapture(false, `Scan failed: ${error.message}`, 1);
    });
  } else {
    noble.stopScanning();
    if (device) finishCapture(false, `Bluetooth unavailable: ${state}`, 1);
  }
});

noble.on("discover", (peripheral) => {
  const name = peripheral.advertisement.localName;
  if (stopped || device || !name?.startsWith("RaceBox Mini S")) return;
  device = peripheral;
  noble.stopScanning();
  console.log(`📡 Found ${name}. Connecting...`);
  peripheral.on("disconnect", () => finishCapture(false, "Device disconnected", 1));
  peripheral.connect((error) => {
    if (stopped) return;
    if (error) {
      finishCapture(false, `Connection failed: ${error.message}`, 1);
      return;
    }
    peripheral.discoverSomeServicesAndCharacteristics(
      [UART_SERVICE_UUID],
      [UART_TX_CHAR_UUID],
      (error, services, characteristics) => {
        if (stopped) return;
        if (error) {
          finishCapture(false, `Characteristic discovery failed: ${error.message}`, 1);
          return;
        }
        const txChar = characteristics.find(
          (characteristic) => characteristic.uuid === UART_TX_CHAR_UUID,
        );
        if (!txChar) {
          finishCapture(false, "RaceBox data characteristic missing", 1);
          return;
        }
        txChar.on("data", receiveData);
        txChar.subscribe((error) => {
          if (stopped) return;
          if (error) {
            finishCapture(false, `Subscription failed: ${error.message}`, 1);
            return;
          }
          resetWatchdog();
          console.log(
            "🔗 Live stream connected. Waiting for a valid 3D GNSS fix. Press Ctrl+C to finish recording.",
          );
        });
      },
    );
  });
});
