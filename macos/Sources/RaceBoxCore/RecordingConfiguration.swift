import Foundation

public struct RecordingConfiguration: Equatable {
    public let payload: [UInt8]
    public var enabled: Bool { payload[0] != 0 }
    public let samplesPerSecond: Double

    public init(payload: [UInt8]) throws {
        guard payload.count == 12, payload[0] <= 1 else {
            throw RaceBoxError.protocolError("Unexpected standalone recording configuration.")
        }
        let rates: [Double] = [25, 10, 5, 1, 20]
        guard Int(payload[1]) < rates.count else {
            throw RaceBoxError.protocolError("Unsupported standalone recording rate: \(payload[1]).")
        }
        self.payload = payload
        samplesPerSecond = rates[Int(payload[1])]
    }

    public func command(enabled: Bool) -> Packet {
        var updated = payload
        updated[0] = enabled ? 1 : 0
        return Packet(id: 0x25, payload: updated)
    }

    public func duration(records: UInt32) -> String {
        RecordingTime.duration(Double(records) / samplesPerSecond)
    }
}

public enum RecordingTime {
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 3600)h \(total % 3600 / 60)m \(total % 60)s"
    }

    public static func axisLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    public static func utcDate(year: Int, month: Int, day: Int, hour: Int,
                               minute: Int, second: Int, nanoseconds: Double) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: min(second, 59))
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second),
              nanoseconds.isFinite, abs(nanoseconds) <= 1_000_000_000,
              let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else {
            throw RaceBoxError.protocolError("The recording contains an invalid UTC date.")
        }
        return date.addingTimeInterval(Double(second == 60 ? 1 : 0) + nanoseconds / 1_000_000_000)
    }
}
