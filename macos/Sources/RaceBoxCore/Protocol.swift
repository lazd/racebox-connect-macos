import Foundation

public enum RaceBoxError: LocalizedError {
    case protocolError(String)
    case fileError(String)

    public var errorDescription: String? {
        switch self {
        case .protocolError(let message), .fileError(let message): return message
        }
    }
}

extension Array where Element == UInt8 {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }

    func i32(_ offset: Int) -> Int32 { Int32(bitPattern: u32(offset)) }
    func i16(_ offset: Int) -> Int16 { Int16(bitPattern: u16(offset)) }
}

public struct Packet: Equatable {
    public let messageClass: UInt8
    public let id: UInt8
    public let payload: [UInt8]

    public init(id: UInt8, payload: [UInt8] = [], messageClass: UInt8 = 0xff) {
        self.messageClass = messageClass
        self.id = id
        self.payload = payload
    }

    public var data: Data {
        precondition(payload.count <= 504)
        let body = [messageClass, id, UInt8(payload.count & 255), UInt8(payload.count >> 8)] + payload
        return Data([0xb5, 0x62] + body + Self.checksum(body))
    }

    static func checksum(_ bytes: [UInt8]) -> [UInt8] {
        var a: UInt8 = 0
        var b: UInt8 = 0
        for byte in bytes {
            a = a &+ byte
            b = b &+ a
        }
        return [a, b]
    }

    public static func unlock(code: UInt32) -> Packet {
        Packet(id: 0x30, payload: (0..<4).map { UInt8(truncatingIfNeeded: code >> ($0 * 8)) })
    }
}

public struct PacketDecoder {
    private var buffer: [UInt8] = []
    private var discardingBytes = false
    public private(set) var invalidFrames = 0

    public init() {}

    public mutating func receive(_ data: Data) -> [Packet] {
        buffer.append(contentsOf: data)
        var packets: [Packet] = []
        while buffer.count >= 2 {
            guard buffer[0] == 0xb5, buffer[1] == 0x62 else {
                if !discardingBytes { invalidFrames += 1 }
                discardingBytes = true
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= 6 else { break }
            let length = Int(buffer.u16(4)) + 8
            guard length <= 512 else {
                invalidFrames += 1
                discardingBytes = true
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= length else { break }
            let frame = Array(buffer.prefix(length))
            guard Packet.checksum(Array(frame[2..<(length - 2)])) == Array(frame.suffix(2)) else {
                invalidFrames += 1
                discardingBytes = true
                buffer.removeFirst()
                continue
            }
            packets.append(Packet(id: frame[3], payload: Array(frame[6..<(length - 2)]),
                                  messageClass: frame[2]))
            discardingBytes = false
            buffer.removeFirst(length)
        }
        return packets
    }
}

public struct MemoryStatus: Equatable {
    public let recording: Bool
    public let usedPercent: Int
    public let securityEnabled: Bool
    public let unlocked: Bool
    public let storedRecords: UInt32
    public let capacityRecords: UInt32

    public init(payload: [UInt8]) throws {
        guard payload.count == 12 else {
            throw RaceBoxError.protocolError("Unexpected memory-status layout (\(payload.count) bytes).")
        }
        recording = payload[0] != 0
        usedPercent = Int(payload[1])
        securityEnabled = payload[2] & 1 != 0
        unlocked = payload[2] & 2 != 0
        storedRecords = payload.u32(4)
        capacityRecords = payload.u32(8)
    }
}

public struct Telemetry: Encodable {
    public let timestampMs: UInt32
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int
    public let nanoseconds: Int32
    public let fixStatus: Int
    public let latitude: Double
    public let longitude: Double
    public let altMslM: Double
    public let speedKmh: Double
    public let headingDeg: Double
    public let gForceX: Double
    public let gForceY: Double
    public let gForceZ: Double
    public let rollRate: Double
    public let pitchRate: Double
    public let yawRate: Double
    public let satellites: Int?
    public let horizontalAccuracyM: Double?
    public let verticalAccuracyM: Double?
    public let speedAccuracyKmh: Double?
    public let headingAccuracyDeg: Double?
    public let pdop: Double?
    public let altWgsM: Double?
    public let batteryPercent: Int?
    public let charging: Bool?
    public let utcValid: Bool?
    public let timeAccuracyNs: UInt32?

    // Transport-only validity flag must not change the Node-compatible JSON schema.
    public var hasFix: Bool { fixStatus == 3 && fixValid }
    private let fixValid: Bool

    enum CodingKeys: String, CodingKey {
        case timestampMs, year, month, day, hour, minute, second, nanoseconds, fixStatus
        case latitude, longitude, altMslM, speedKmh, headingDeg, gForceX, gForceY, gForceZ
        case rollRate, pitchRate, yawRate, satellites, horizontalAccuracyM, verticalAccuracyM
        case speedAccuracyKmh, headingAccuracyDeg, pdop, altWgsM, batteryPercent, charging
        case utcValid, timeAccuracyNs
    }

    public init(packet: Packet) throws {
        let p = packet.payload
        guard packet.messageClass == 0xff, [0x01, 0x21].contains(packet.id), p.count == 80 else {
            throw RaceBoxError.protocolError("Unexpected telemetry packet layout.")
        }
        timestampMs = p.u32(0)
        year = Int(p.u16(4))
        month = Int(p[6])
        day = Int(p[7])
        hour = Int(p[8])
        minute = Int(p[9])
        second = Int(p[10])
        nanoseconds = p.i32(16)
        fixStatus = Int(p[20])
        fixValid = p[21] & 1 != 0
        longitude = Double(p.i32(24)) / 10_000_000
        latitude = Double(p.i32(28)) / 10_000_000
        altMslM = Double(p.i32(36)) / 1000
        speedKmh = Double(p.i32(48)) * 3.6 / 1000
        headingDeg = Double(p.i32(52)) / 100_000
        gForceX = Double(p.i16(68)) / 1000
        gForceY = Double(p.i16(70)) / 1000
        gForceZ = Double(p.i16(72)) / 1000
        rollRate = Double(p.i16(74)) / 100
        pitchRate = Double(p.i16(76)) / 100
        yawRate = Double(p.i16(78)) / 100
        let live = packet.id == 0x01
        satellites = live ? Int(p[23]) : nil
        horizontalAccuracyM = live ? Double(p.u32(40)) / 1000 : nil
        verticalAccuracyM = live ? Double(p.u32(44)) / 1000 : nil
        speedAccuracyKmh = live ? Double(p.u32(56)) * 3.6 / 1000 : nil
        headingAccuracyDeg = live ? Double(p.u32(60)) / 100_000 : nil
        pdop = live ? Double(p.u16(64)) / 100 : nil
        altWgsM = live ? Double(p.i32(32)) / 1000 : nil
        batteryPercent = live ? Int(p[67] & 0x7f) : nil
        charging = live ? p[67] & 0x80 != 0 : nil
        utcValid = live ? p[11] & 3 == 3 : nil
        timeAccuracyNs = live ? p.u32(12) : nil
    }

    public var dateFolder: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var timeFilename: String {
        String(format: "%02d-%02d-%02d", hour, minute, second)
    }

    public func utcDate() throws -> Date {
        try RecordingTime.utcDate(year: year, month: month, day: day, hour: hour,
                                  minute: minute, second: second, nanoseconds: Double(nanoseconds))
    }
}
