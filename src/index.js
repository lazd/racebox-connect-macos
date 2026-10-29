const noble = require("@abandonware/noble");
const fs = require("fs");
const path = require("path");
const { calculateChecksum, parseDataFrame } = require("./racebox-protocol");

// Official RaceBox Nordic UART UUIDs (Strip dashes for Noble)
const UART_SERVICE_UUID = "6e400001b5a3f393e0a9e50e24dcca9e";
const UART_RX_CHAR_UUID = "6e400002b5a3f393e0a9e50e24dcca9e"; // Write commands here
const UART_TX_CHAR_UUID = "6e400003b5a3f393e0a9e50e24dcca9e"; // Read data stream here

let recordsSaved = 0;
let sessionsSaved = 0;
let sessionsSkipped = 0;
let sessionsFound = 0;
const OUTPUT_DIRECTORY = "racebox_sessions";
let session;
let recordingState = null;
let receiveBuffer = Buffer.alloc(0);
let downloadState = "idle";
let expectedRecords = null;
let storedRecords = null;
let recordingActive = false;
let invalidFrames = 0;
let watchdog;
let device;

function saveSession(complete, endReason) {
  if (!session) return;
  if (session.skipped) {
    session = null;
    return;
  }
  complete = complete && invalidFrames === 0;
  fs.writeSync(
    session.fd,
    `\n],"pointCount":${session.count},"complete":${complete},"endReason":${JSON.stringify(endReason)}}\n`,
  );
  fs.closeSync(session.fd);
  console.log(
    `\n${complete ? "💾" : "⚠️"} Saved ${session.filename} (${session.count.toLocaleString()} points, ${complete ? "complete" : "incomplete; will retry next run"}).`,
  );
  session = null;
}

function recordingFilename(point) {
  const pad = (value) => String(value).padStart(2, "0");
  const date = `${String(point.year).padStart(4, "0")}-${pad(point.month)}-${pad(point.day)}`;
  const time = `${pad(point.hour)}-${pad(point.minute)}-${pad(point.second)}`;
  return path.join(OUTPUT_DIRECTORY, date, `session-${time}-${point.timestampMs}.json`);
}

function isCompleteRecording(filename) {
  try {
    return JSON.parse(fs.readFileSync(filename, "utf8"))?.complete === true;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    if (error instanceof SyntaxError) {
      console.log(`⚠️ Invalid JSON in ${filename}; downloading a replacement.`);
      return false;
    }
    throw error;
  }
}

function savePoint(point) {
  if (recordingState === 2) recordingState = 1;
  if (!session) {
    const filename = recordingFilename(point);
    sessionsFound++;
    if (isCompleteRecording(filename)) {
      sessionsSkipped++;
      session = { filename, count: 0, skipped: true };
      console.log(`\n\n⏭️  Skipping ${filename}: already complete.`);
    } else {
      fs.mkdirSync(path.dirname(filename), { recursive: true });
      const fd = fs.openSync(filename, "w");
      session = { fd, filename, count: 0, skipped: false };
      sessionsSaved++;
      fs.writeSync(fd, `{"session":${sessionsFound},"points":[\n`);
      console.log(`\n\n📥 Recording to ${filename}...`);
    }
  }
  if (!session.skipped)
    fs.writeSync(session.fd, `${session.count ? ",\n" : ""}${JSON.stringify(point)}`);
  session.count++;
  recordsSaved++;
  if (process.stdout.isTTY && (recordsSaved % 250 === 0 || recordsSaved === expectedRecords)) {
    process.stdout.write(
      `\r📡 Received ${recordsSaved.toLocaleString()}${expectedRecords === null ? "" : ` / up to ${expectedRecords.toLocaleString()}`} points; ${sessionsSaved} saved, ${sessionsSkipped} skipped.\x1b[K`,
    );
  }
}

function finishDownload(complete, reason, exitCode = 0) {
  if (downloadState === "done") return;
  downloadState = "done";
  clearTimeout(watchdog);
  saveSession(complete && !recordingActive, reason);
  console.log(
    `\n\n${complete ? "✅" : "❌"} ${reason}\n📊 ${recordsSaved.toLocaleString()} points received · ${sessionsSaved} recordings saved · ${sessionsSkipped} already complete\n📁 Output: ${OUTPUT_DIRECTORY}/YYYY-MM-DD/`,
  );
  if (device) device.disconnect();
  noble.stopScanning();
  process.exit(exitCode);
}

function resetWatchdog() {
  clearTimeout(watchdog);
  watchdog = setTimeout(() => finishDownload(false, "Download timed out", 1), 30000);
}

process.on("SIGINT", () => finishDownload(false, "Interrupted", 130));
process.on("SIGTERM", () => finishDownload(false, "Terminated", 143));

// 2. Construct a valid binary command frame
function buildRaceBoxCommand(msgClass, msgId, payload = Buffer.alloc(0)) {
  const header = Buffer.alloc(6);
  header.writeUInt8(0xb5, 0);
  header.writeUInt8(0x62, 1);
  header.writeUInt8(msgClass, 2);
  header.writeUInt8(msgId, 3);
  header.writeUInt16LE(payload.length, 4);

  const body = Buffer.concat([header.subarray(2), payload]);
  const checksum = calculateChecksum(body);

  return Buffer.concat([header, payload, checksum]);
}

// 3. Decode incoming binary flash payloads on the fly
function parseFlashPayload(data) {
  return parseDataFrame(data, 0x21);
}

function parseRecordingStatus(payload) {
  if (payload.length !== 12) return null;
  return {
    recording: payload[0] !== 0,
    memoryUsedPercent: payload[1],
    securityEnabled: (payload[2] & 0x01) !== 0,
    memoryUnlocked: (payload[2] & 0x02) !== 0,
    storedRecords: payload.readUInt32LE(4),
    capacityRecords: payload.readUInt32LE(8),
  };
}

function receiveData(data, rxChar) {
  receiveBuffer = Buffer.concat([receiveBuffer, data]);
  while (receiveBuffer.length >= 2 && downloadState !== "done") {
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
    if (receiveBuffer.length < length) return;
    const frame = receiveBuffer.subarray(0, length);
    if (!calculateChecksum(frame.subarray(2, -2)).equals(frame.subarray(-2))) {
      invalidFrames++;
      console.error("⚠️ Ignoring frame with invalid checksum.");
      receiveBuffer = receiveBuffer.subarray(1);
      continue;
    }
    receiveBuffer = receiveBuffer.subarray(length);
    handleFrame(frame, rxChar);
  }
}

function writeCommand(rxChar, msgId, payload) {
  resetWatchdog();
  rxChar.write(buildRaceBoxCommand(0xff, msgId, payload), false, (error) => {
    if (error) finishDownload(false, `Command failed: ${error.message}`, 1);
  });
}

function handleFrame(frame, rxChar) {
  if (frame[2] !== 0xff) return;
  const msgId = frame[3];
  const payload = frame.subarray(6, -2);
  if (process.env.RACEBOX_DEBUG && [0x22, 0x23].includes(msgId)) {
    console.log(
      `🔎 RaceBox 0xFF/0x${msgId.toString(16)}: ${payload.length} bytes, payload=${payload.toString("hex")}`,
    );
  }
  if (msgId === 0x03 && payload[0] === 0xff && [0x30, 0x22, 0x23].includes(payload[1])) {
    finishDownload(false, `Device rejected command 0x${payload[1].toString(16)}`, 1);
  } else if (msgId === 0x02 && payload[0] === 0xff) {
    if (payload[1] === 0x30 && downloadState === "unlocking") {
      downloadState = "checking-status";
      console.log("🗂️ Checking recorded-memory status...");
      writeCommand(rxChar, 0x22);
    } else if (payload[1] === 0x23 && downloadState === "downloading") {
      if (recordsSaved === 0) {
        finishDownload(
          false,
          `No history received (memory status reported ${storedRecords} stored records). The zero-count response does not confirm that your recordings were downloaded`,
          1,
        );
        return;
      }
      const complete =
        expectedRecords !== null && recordsSaved <= expectedRecords && invalidFrames === 0;
      finishDownload(
        complete,
        complete
          ? "Download complete"
          : "Download ended with invalid frames or an unexpected record count",
        complete ? 0 : 1,
      );
    }
  } else if (downloadState === "checking-status" && msgId === 0x22) {
    const status = parseRecordingStatus(payload);
    if (!status) {
      finishDownload(false, `Unexpected recording-status layout: ${payload.toString("hex")}`, 1);
      return;
    }
    storedRecords = status.storedRecords;
    recordingActive = status.recording;
    console.log(
      `📦 Memory: ${status.memoryUsedPercent}% used; ${storedRecords.toLocaleString()} / ${status.capacityRecords.toLocaleString()} records. ${status.memoryUnlocked ? "🔓 Unlocked" : "🔒 Locked"}; recording ${status.recording ? "active" : "stopped"}.`,
    );
    if (status.securityEnabled && !status.memoryUnlocked) {
      finishDownload(
        false,
        "Memory is locked; supply the device security code using RACEBOX_SECURITY_CODE",
        1,
      );
      return;
    }
    downloadState = "downloading";
    console.log("📥 Reading stored history; complete local recordings will be skipped.");
    writeCommand(rxChar, 0x23);
  } else if (downloadState === "downloading") {
    if (msgId === 0x23 && payload.length === 4) {
      expectedRecords = payload.readUInt32LE(0);
      console.log(`📡 Expecting up to ${expectedRecords.toLocaleString()} history points.`);
      resetWatchdog();
    } else if (msgId === 0x26 && payload.length >= 1) {
      const nextState = payload[0];
      if (nextState === 0) saveSession(true, "recording-stopped");
      else if (nextState === 1 && recordingState !== 2) saveSession(true, "recording-started");
      recordingState = nextState;
      resetWatchdog();
    } else if (msgId === 0x21) {
      const point = parseFlashPayload(frame);
      if (!point) {
        finishDownload(false, "Unexpected history payload length", 1);
        return;
      }
      savePoint(point);
      resetWatchdog();
    }
  }
}

// 4. BLE State Engine Orchestration
noble.on("stateChange", async (state) => {
  if (state === "poweredOn") {
    console.log("🔎 Scanning for RaceBox Mini S hardware...");
    noble.startScanning([UART_SERVICE_UUID], false);
  } else {
    noble.stopScanning();
  }
});

noble.on("discover", async (peripheral) => {
  const name = peripheral.advertisement.localName;
  if (name && name.startsWith("RaceBox Mini S")) {
    if (device) return;
    device = peripheral;
    peripheral.on("disconnect", () => finishDownload(false, "Device disconnected", 1));
    console.log(`📡 Found ${name}. Connecting...`);
    noble.stopScanning();

    peripheral.connect((error) => {
      if (error) {
        finishDownload(false, `Connection failed: ${error.message}`, 1);
        return;
      }
      console.log("🔗 Connected. Subscribing to the RaceBox data stream...");

      peripheral.discoverSomeServicesAndCharacteristics(
        [UART_SERVICE_UUID],
        [UART_RX_CHAR_UUID, UART_TX_CHAR_UUID],
        handleCharacteristics,
      );
    });
  }
});

function handleCharacteristics(error, services, characteristics) {
  if (error) {
    finishDownload(false, `Error discovering characteristics: ${error.message}`, 1);
    return;
  }

  const rxChar = characteristics.find((c) => c.uuid === UART_RX_CHAR_UUID);
  const txChar = characteristics.find((c) => c.uuid === UART_TX_CHAR_UUID);

  if (!rxChar || !txChar) {
    finishDownload(false, "Required RaceBox UART characteristics missing", 1);
    return;
  }

  txChar.on("data", (data) => receiveData(data, rxChar));

  txChar.subscribe((err) => {
    if (err) {
      finishDownload(false, `Subscription error: ${err.message}`, 1);
      return;
    }
    const securityCode = Number(process.env.RACEBOX_SECURITY_CODE || 0);
    if (!Number.isInteger(securityCode) || securityCode < 0 || securityCode > 0xffffffff) {
      finishDownload(false, "RACEBOX_SECURITY_CODE must be an unsigned 32-bit integer", 1);
      return;
    }
    const unlockPayload = Buffer.alloc(4);
    unlockPayload.writeUInt32LE(securityCode);
    downloadState = "unlocking";
    console.log("\n🔓 Unlocking recorded memory...");
    writeCommand(rxChar, 0x30, unlockPayload);
  });
}
