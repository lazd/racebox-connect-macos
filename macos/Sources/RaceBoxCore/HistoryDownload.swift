import Foundation

public struct ExportedRecording {
    public let url: URL
    public let pointCount: Int
    public let complete: Bool
}

public final class HistoryDownload {
    public private(set) var received = 0
    public private(set) var expected: UInt32?
    public private(set) var recordings: [ExportedRecording] = []
    public private(set) var skippedRecordings: [ExportedRecording] = []
    public private(set) var duplicateCheckIssues: [RecordingLoadIssue] = []
    public var files: [URL] { recordings.map(\.url) }
    public var savedPointCount: Int { recordings.reduce(0) { $0 + $1.pointCount } }
    public var activeFileURL: URL? { writer?.url }
    public private(set) var finished = false
    public private(set) var safeToErase = false
    public let status: MemoryStatus
    private let directory: URL
    private let format: ExportFormat
    private var writer: RecordingWriter?
    private var recordingState: UInt8?
    private var session = 0

    public init(status: MemoryStatus, directory: URL, format: ExportFormat) {
        self.status = status
        self.directory = directory
        self.format = format
    }

    private func closeSession(complete: Bool, invalidFrames: Int, reason: String) throws {
        guard let current = writer else { return }
        writer = nil
        try current.finish(complete: complete && invalidFrames == 0,
                           invalidFrames: invalidFrames, reason: reason)
        if complete && invalidFrames == 0, let existing = try duplicate(of: current) {
            if format == .csv {
                try FileManager.default.removeItem(at: current.url.appendingPathExtension("metadata.json"))
            }
            try FileManager.default.removeItem(at: current.url)
            skippedRecordings.append(ExportedRecording(url: existing, pointCount: current.count, complete: true))
            return
        }
        recordings.append(ExportedRecording(url: current.url, pointCount: current.count,
                                            complete: complete && invalidFrames == 0))
    }

    private func duplicate(of current: RecordingWriter) throws -> URL? {
        let manager = FileManager.default
        let currentURL = current.url.resolvingSymlinksInPath().standardizedFileURL
        let candidates = try manager.contentsOfDirectory(
            at: current.url.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.resolvingSymlinksInPath().standardizedFileURL != currentURL
                && $0.pathExtension.lowercased() == format.fileExtension
                && !$0.lastPathComponent.lowercased().hasSuffix(".metadata.json")
        }.sorted { $0.path < $1.path }
        let currentData = try Data(contentsOf: current.url, options: .mappedIfSafe)
        let currentPoints = format == .json ? try jsonPoints(in: currentData, url: current.url) : nil
        for candidate in candidates {
            guard !duplicateCheckIssues.contains(where: { $0.url == candidate }) else { continue }
            do {
                guard try candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                if format == .json {
                    let data = try Data(contentsOf: candidate, options: .mappedIfSafe)
                    guard let points = try jsonPoints(in: data, url: candidate),
                          let currentPoints, points.count == current.count else { continue }
                    if NSArray(array: points).isEqual(to: currentPoints) { return candidate }
                } else {
                    let metadataURL = candidate.appendingPathExtension("metadata.json")
                    guard manager.fileExists(atPath: metadataURL.path) else { continue }
                    let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))
                    guard let metadata = metadata as? [String: Any] else {
                        throw RaceBoxError.fileError("Invalid recording metadata: \(metadataURL.path)")
                    }
                    guard metadata["complete"] as? Bool == true,
                          metadata["source"] as? String != "live",
                          metadata["pointCount"] as? Int == current.count else { continue }
                    if try Data(contentsOf: candidate, options: .mappedIfSafe) == currentData { return candidate }
                }
            } catch {
                duplicateCheckIssues.append(RecordingLoadIssue(url: candidate, message: error.localizedDescription))
            }
        }
        return nil
    }

    private func jsonPoints(in data: Data, url: URL) throws -> [[String: Any]]? {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RaceBoxError.fileError("Invalid recording: \(url.path)")
        }
        guard document["complete"] as? Bool == true, document["source"] as? String != "live" else { return nil }
        guard let points = document["points"] as? [[String: Any]],
              document["pointCount"] as? Int == points.count else {
            throw RaceBoxError.fileError("Invalid recording points or count: \(url.path)")
        }
        return points
    }

    // Returns true only for the device's end-of-download ACK, never for a count announcement.
    @discardableResult
    public func receive(_ packet: Packet, invalidFrames: Int) throws -> Bool {
        guard !finished, packet.messageClass == 0xff else { return false }
        switch packet.id {
        case 0x23:
            guard packet.payload.count == 4, expected == nil else {
                throw RaceBoxError.protocolError("Unexpected history count response.")
            }
            expected = packet.payload.u32(0)
        case 0x21:
            guard expected != nil else {
                throw RaceBoxError.protocolError("History arrived before the download count.")
            }
            let point = try Telemetry(packet: packet)
            if recordingState == 2 { recordingState = 1 }
            if writer == nil {
                session += 1
                writer = try RecordingWriter(directory: directory, firstPoint: point,
                                             format: format, live: false, session: session)
            }
            try writer?.append(point)
            received += 1
        case 0x26:
            guard packet.payload.count == 12, let next = packet.payload.first, next <= 2 else {
                throw RaceBoxError.protocolError("Unexpected recording-boundary layout.")
            }
            if next == 0 || (next == 1 && recordingState != 2) {
                try closeSession(complete: true, invalidFrames: invalidFrames,
                                 reason: next == 0 ? "recording-stopped" : "recording-started")
            }
            recordingState = next
        case 0x02 where packet.payload == [0xff, 0x23]:
            let valid = expected != nil && received > 0
                && UInt64(received) <= UInt64(expected ?? 0) && invalidFrames == 0
            try closeSession(complete: valid && !status.recording,
                             invalidFrames: invalidFrames, reason: valid
                             ? "Download complete" : "Download ended with invalid frames or an unexpected record count")
            finished = true
            safeToErase = valid && !status.recording && duplicateCheckIssues.isEmpty
            guard valid else {
                throw RaceBoxError.protocolError("Download could not be verified (\(received) points, \(invalidFrames) rejected frames). Memory was not erased.")
            }
            return true
        default: break
        }
        return false
    }

    public func interrupt(reason: String, invalidFrames: Int) throws {
        guard !finished else { return }
        finished = true
        safeToErase = false
        try closeSession(complete: false, invalidFrames: invalidFrames, reason: reason)
    }
}
