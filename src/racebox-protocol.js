function calculateChecksum(payload) {
  let checksumA = 0;
  let checksumB = 0;
  for (const byte of payload) {
    checksumA = (checksumA + byte) & 0xff;
    checksumB = (checksumB + checksumA) & 0xff;
  }
  return Buffer.from([checksumA, checksumB]);
}

function parseDataFrame(data, messageId) {
  if (data.length !== 88 || data[2] !== 0xff || data[3] !== messageId) return null;
  return {
    timestampMs: data.readUInt32LE(6),
    year: data.readUInt16LE(10),
    month: data.readUInt8(12),
    day: data.readUInt8(13),
    hour: data.readUInt8(14),
    minute: data.readUInt8(15),
    second: data.readUInt8(16),
    nanoseconds: data.readInt32LE(22),
    fixStatus: data.readUInt8(26),
    latitude: data.readInt32LE(34) / 10000000,
    longitude: data.readInt32LE(30) / 10000000,
    altMslM: data.readInt32LE(42) / 1000,
    speedKmh: (data.readInt32LE(54) * 3.6) / 1000,
    headingDeg: data.readInt32LE(58) / 100000,
    gForceX: data.readInt16LE(74) / 1000,
    gForceY: data.readInt16LE(76) / 1000,
    gForceZ: data.readInt16LE(78) / 1000,
    rollRate: data.readInt16LE(80) / 100,
    pitchRate: data.readInt16LE(82) / 100,
    yawRate: data.readInt16LE(84) / 100,
  };
}

module.exports = { calculateChecksum, parseDataFrame };