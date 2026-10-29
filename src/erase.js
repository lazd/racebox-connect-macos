const readline = require("node:readline");
const { calculateChecksum } = require("./racebox-protocol");

const UART_SERVICE_UUID = "6e400001b5a3f393e0a9e50e24dcca9e";
const UART_RX_CHAR_UUID = "6e400002b5a3f393e0a9e50e24dcca9e";
const UART_TX_CHAR_UUID = "6e400003b5a3f393e0a9e50e24dcca9e";
const securityCode = Number(process.env.RACEBOX_SECURITY_CODE || 0);
let state = "confirming";
let noble;
let device;
let prompt;
let watchdog;
let receiveBuffer = Buffer.alloc(0);

function finish(exitCode, message) {
  if (state === "done") return;
  const eraseUnverified = state === "erasing" || state === "verifying";
  state = "done";
  clearTimeout(watchdog);
  if (prompt) prompt.close();
  console.log(`${exitCode ? "⚠️" : "✅"} ${message}`);
  if (exitCode && eraseUnverified) {
    console.error("Erase completion is unverified; device memory may be partially erased. Keep the device powered on.");
  }
  if (noble) noble.stopScanning();
  if (device) device.disconnect();
  process.exit(exitCode);
}

function resetWatchdog() {
  clearTimeout(watchdog);
  watchdog = setTimeout(() => finish(1, "Device operation timed out"), state === "erasing" ? 180000 : 30000);
}

function send(rxChar, messageId, payload = Buffer.alloc(0)) {
  const header = Buffer.from([0xb5, 0x62, 0xff, messageId, 0, 0]);
  header.writeUInt16LE(payload.length, 4);
  const body = Buffer.concat([header, payload]);
  resetWatchdog();
  rxChar.write(Buffer.concat([body, calculateChecksum(body.subarray(2))]), false, error => {
    if (error) finish(1, `Command failed: ${error.message}`);
  });
}

function handleFrame(frame, rxChar) {
  if (frame[2] !== 0xff) return;
  const messageId = frame[3];
  const payload = frame.subarray(6, -2);
  if (messageId === 0x03 && payload.length === 2 && payload[0] === 0xff) {
    finish(1, `Device rejected command 0x${payload[1].toString(16)}`);
  } else if (messageId === 0x02 && payload.length === 2 && payload[0] === 0xff) {
    if (state === "unlocking" && payload[1] === 0x30) {
      state = "checking";
      send(rxChar, 0x22);
    } else if (state === "erasing" && payload[1] === 0x24) {
      state = "verifying";
      send(rxChar, 0x22);
    }
  } else if (messageId === 0x22 && ["checking", "verifying"].includes(state)) {
    if (payload.length !== 12) return finish(1, "Unexpected recording-status layout");
    const storedRecords = payload.readUInt32LE(4);
    if (state === "verifying") {
      finish(storedRecords === 0 ? 0 : 1, storedRecords === 0
        ? "Device memory cleared and verified empty. Local exports were not changed."
        : `Memory is not empty: ${storedRecords.toLocaleString()} records remain`);
      return;
    }
    if (payload[0] !== 0) return finish(1, "Stop standalone recording before clearing memory");
    if ((payload[2] & 1) !== 0 && (payload[2] & 2) === 0) {
      return finish(1, "Memory is locked; supply RACEBOX_SECURITY_CODE");
    }
    console.log(`🧹 Clearing ${storedRecords.toLocaleString()} stored points. Keep your RaceBox powered on…`);
    state = "erasing";
    send(rxChar, 0x24);
  } else if (messageId === 0x24 && state === "erasing") {
    if (payload.length !== 1 || payload[0] > 100) return finish(1, "Invalid erase-progress response");
    console.log(`🧹 Erasing device memory: ${payload[0]}%`);
    resetWatchdog();
  }
}

function receiveData(data, rxChar) {
  receiveBuffer = Buffer.concat([receiveBuffer, data]);
  while (receiveBuffer.length >= 2 && state !== "done") {
    const syncIndex = receiveBuffer.indexOf(Buffer.from([0xb5, 0x62]));
    if (syncIndex < 0) {
      receiveBuffer = receiveBuffer.subarray(receiveBuffer.length - (receiveBuffer.at(-1) === 0xb5 ? 1 : 0));
      return;
    }
    receiveBuffer = receiveBuffer.subarray(syncIndex);
    if (receiveBuffer.length < 6) return;
    const length = receiveBuffer.readUInt16LE(4) + 8;
    if (length > 512) return finish(1, "Invalid frame length");
    if (receiveBuffer.length < length) return;
    const frame = receiveBuffer.subarray(0, length);
    if (!calculateChecksum(frame.subarray(2, -2)).equals(frame.subarray(-2))) {
      return finish(1, "Invalid response checksum");
    }
    receiveBuffer = receiveBuffer.subarray(length);
    handleFrame(frame, rxChar);
  }
}

function beginBluetooth() {
  noble = require("@abandonware/noble");
  resetWatchdog();
  const scan = bluetoothState => {
    if (state === "done") return;
    if (bluetoothState !== "poweredOn") return finish(1, `Bluetooth is ${bluetoothState}`);
    console.log("🔎 Scanning for RaceBox Mini S hardware...");
    noble.startScanning([UART_SERVICE_UUID], false, error => {
      if (error) finish(1, `Scanning failed: ${error.message}`);
    });
  };
  noble.on("stateChange", scan);
  noble.on("discover", peripheral => {
    if (device || state === "done" || !peripheral.advertisement.localName?.startsWith("RaceBox Mini S")) return;
    device = peripheral;
    noble.stopScanning();
    console.log(`📡 Connecting to ${peripheral.advertisement.localName}...`);
    peripheral.on("disconnect", () => finish(1, "Device disconnected"));
    peripheral.connect(error => {
      if (state === "done") return;
      if (error) return finish(1, `Connection failed: ${error.message}`);
      peripheral.discoverSomeServicesAndCharacteristics(
        [UART_SERVICE_UUID], [UART_RX_CHAR_UUID, UART_TX_CHAR_UUID],
        (error, services, characteristics) => {
          if (state === "done") return;
          if (error) return finish(1, `Discovery failed: ${error.message}`);
          const rxChar = characteristics.find(characteristic => characteristic.uuid === UART_RX_CHAR_UUID);
          const txChar = characteristics.find(characteristic => characteristic.uuid === UART_TX_CHAR_UUID);
          if (!rxChar || !txChar) return finish(1, "Required RaceBox UART characteristics missing");
          txChar.on("data", data => receiveData(data, rxChar));
          txChar.subscribe(error => {
            if (state === "done") return;
            if (error) return finish(1, `Subscription failed: ${error.message}`);
            const payload = Buffer.alloc(4);
            payload.writeUInt32LE(securityCode);
            state = "unlocking";
            send(rxChar, 0x30, payload);
          });
        },
      );
    });
  });
  if (noble.state === "poweredOn") scan(noble.state);
}

process.on("SIGINT", () => finish(130, "Interrupted"));
process.on("SIGTERM", () => finish(143, "Terminated"));

if (!Number.isInteger(securityCode) || securityCode < 0 || securityCode > 0xffffffff) {
  finish(1, "RACEBOX_SECURITY_CODE must be an unsigned 32-bit integer");
} else if (!process.stdin.isTTY) {
  finish(1, "Erasing requires interactive confirmation in a terminal");
} else {
  console.log("⚠️ This permanently deletes ALL recordings from the first RaceBox Mini S found. Download them first. Local exports are not deleted.");
  prompt = readline.createInterface({ input: process.stdin, output: process.stdout });
  prompt.on("close", () => {
    if (state === "confirming") finish(0, "Cancelled; nothing was erased");
  });
  prompt.question("Type ERASE to clear device memory: ", answer => {
    if (state !== "confirming") return;
    if (answer.trim() !== "ERASE") return finish(0, "Cancelled; nothing was erased");
    state = "connecting";
    prompt.close();
    beginBluetooth();
  });
}