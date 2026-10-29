import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable {
    case json = "JSON"
    case csv = "CSV"
    public var id: String { rawValue }
    public var fileExtension: String { rawValue.lowercased() }
}

public final class RecordingWriter {
    public static let csvHeader = "Record,Time,Latitude,Longitude,Altitude,Speed,GForceX,GForceY,GForceZ,Lap,GyroX,GyroY,GyroZ"
    public let url: URL
    public let format: ExportFormat
    public private(set) var count = 0
    private var handle: FileHandle?
    private let live: Bool
    private let session: Int
    private let encoder = JSONEncoder()
    private let isoFormatter: ISO8601DateFormatter

    public init(directory: URL, firstPoint: Telemetry, format: ExportFormat,
                live: Bool, session: Int = 1) throws {
        self.format = format
        self.live = live
        self.session = session
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let folder = directory.appendingPathComponent(live ? "racebox_live" : "racebox_sessions")
            .appendingPathComponent(firstPoint.dateFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = live ? "live" : "session"
        let name = "\(prefix)-\(firstPoint.timeFilename)-\(firstPoint.timestampMs)-\(UUID().uuidString)"
        url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RaceBoxError.fileError("Could not create \(url.path).")
        }

        handle = try FileHandle(forWritingTo: url)
        do {
            try write(format == .csv ? Self.csvHeader + "\n"
                      : live ? "{\"source\":\"live\",\"points\":[\n"
                      : "{\"session\":\(session),\"points\":[\n")
        } catch {
            try handle?.close()
            handle = nil
            throw error
        }
    }

    deinit { handle?.closeFile() }

    private func write(_ text: String) throws {
        guard let handle else { throw RaceBoxError.fileError("The output file is already closed.") }
        try handle.write(contentsOf: Data(text.utf8))
    }

    public func append(_ point: Telemetry) throws {
        if format == .json {
            guard let text = String(data: try encoder.encode(point), encoding: .utf8) else {
                throw RaceBoxError.fileError("Could not encode a telemetry point.")
            }
            try write((count == 0 ? "" : ",\n") + text)
        } else {
            let time = isoFormatter.string(from: try point.utcDate())
            let numbers = String(
                format: "%.7f,%.7f,%.1f,%.2f,%.3f,%.3f,%.3f,0,%.2f,%.2f,%.2f",
                locale: Locale(identifier: "en_US_POSIX"),
                point.latitude, point.longitude, point.altMslM, point.speedKmh,
                point.gForceX, point.gForceY, point.gForceZ,
                point.rollRate, point.pitchRate, point.yawRate
            )
            try write("\(count + 1),\(time),\(numbers)\n")
        }
        count += 1
    }

    public func finish(complete: Bool, invalidFrames: Int, reason: String) throws {
        guard let handle else { throw RaceBoxError.fileError("The output file is already closed.") }
        let metadata: [String: Any] = [
            "pointCount": count, "complete": complete, "endReason": reason
        ].merging(live ? ["source": "live", "invalidFrames": invalidFrames] : ["session": session]) {
            _, new in new
        }
        do {
            if format == .json {
                let encodedReason = String(decoding: try encoder.encode(reason), as: UTF8.self)
                try write("\n],\"pointCount\":\(count),\"complete\":\(complete)"
                          + (live ? ",\"invalidFrames\":\(invalidFrames)" : "")
                          + ",\"endReason\":\(encodedReason)}\n")
            }
            try handle.synchronize()
            try handle.close()
            self.handle = nil
            if format == .csv {
                let metadataURL = url.appendingPathExtension("metadata.json")
                try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
                    .write(to: metadataURL, options: .atomic)
                let metadataHandle = try FileHandle(forWritingTo: metadataURL)
                try metadataHandle.synchronize()
                try metadataHandle.close()
            }
        } catch {
            if self.handle != nil {
                self.handle = nil
                do { try handle.close() } catch let closeError {
                    throw RaceBoxError.fileError("\(error.localizedDescription) Closing output also failed: \(closeError.localizedDescription)")
                }
            }
            throw error
        }
    }
}

public final class LiveCapture {
    private let directory: URL
    private let format: ExportFormat
    private var writer: RecordingWriter?
    private var finished = false
    public var count: Int { writer?.count ?? 0 }
    public var url: URL? { writer?.url }

    public init(directory: URL, format: ExportFormat) {
        self.directory = directory
        self.format = format
    }

    @discardableResult
    public func receive(_ point: Telemetry) throws -> Bool {
        guard !finished else { throw RaceBoxError.fileError("The live capture is already closed.") }
        guard point.hasFix else { return false }
        if writer == nil {
            writer = try RecordingWriter(directory: directory, firstPoint: point, format: format, live: true)
        }
        try writer?.append(point)
        return true
    }

    public func finish(complete: Bool, invalidFrames: Int, reason: String) throws -> ExportedRecording? {
        guard !finished else { throw RaceBoxError.fileError("The live capture is already closed.") }
        finished = true
        guard let writer else { return nil }
        let valid = complete && invalidFrames == 0
        try writer.finish(complete: valid, invalidFrames: invalidFrames, reason: reason)
        return ExportedRecording(url: writer.url, pointCount: writer.count, complete: valid)
    }
}
