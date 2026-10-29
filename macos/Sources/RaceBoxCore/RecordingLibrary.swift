import Foundation

public struct TrackCoordinate: Sendable {
    public let latitude: Double
    public let longitude: Double
}

public struct RecordingSample: Identifiable, Sendable {
    public let id: Int
    public let elapsed: TimeInterval
    public let coordinate: TrackCoordinate?
    public let speedKmh: Double?
    public let speedSegment: Int
    public let gForceX: Double
    public let gForceY: Double
    public let gForceZ: Double
}

public struct RecordingSummary: Identifiable, Sendable {
    public let url: URL
    public let pointCount: Int
    public let complete: Bool?
    public let startedAt: Date?
    public let duration: TimeInterval
    public var id: URL { url }
}

public struct LoadedRecording: Sendable {
    public let summary: RecordingSummary
    public let samples: [RecordingSample]
    public let endReason: String?
    public let statistics: RecordingStatistics

    init(summary: RecordingSummary, samples: [RecordingSample], endReason: String?) {
        self.summary = summary
        self.samples = samples
        self.endReason = endReason
        statistics = RecordingStatistics(samples: samples)
    }

    public var trackSegments: [[TrackCoordinate]] {
        var result: [[TrackCoordinate]] = []
        var current: [TrackCoordinate] = []
        for sample in samples {
            if let coordinate = sample.coordinate { current.append(coordinate) }
            else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // Keep speed and each axis's extrema, plus speed-run boundaries across GNSS gaps.
    public func chartSamples(buckets: Int = 240) -> [RecordingSample] {
        precondition(buckets > 0)
        guard samples.count > buckets * 8 else { return samples }
        var indices: Set<Int> = [0, samples.count - 1]
        for index in samples.indices where samples[index].speedKmh != nil {
            if index == 0 || samples[index - 1].speedKmh == nil { indices.insert(index) }
            if index == samples.count - 1 || samples[index + 1].speedKmh == nil { indices.insert(index) }
        }
        let width = Int(ceil(Double(samples.count) / Double(buckets)))
        for start in stride(from: 0, to: samples.count, by: width) {
            let range = start..<min(samples.count, start + width)
            for axis in [\RecordingSample.gForceX, \.gForceY, \.gForceZ] {
                if let minIndex = range.min(by: { samples[$0][keyPath: axis] < samples[$1][keyPath: axis] }) {
                    indices.insert(minIndex)
                }
                if let maxIndex = range.max(by: { samples[$0][keyPath: axis] < samples[$1][keyPath: axis] }) {
                    indices.insert(maxIndex)
                }
            }
            let speeds = range.compactMap { index in
                samples[index].speedKmh.map { (index: index, speed: $0) }
            }
            if let minimum = speeds.min(by: { $0.speed < $1.speed }) {
                indices.insert(minimum.index)
            }
            if let maximum = speeds.max(by: { $0.speed < $1.speed }) {
                indices.insert(maximum.index)
            }
        }
        return indices.sorted().map { samples[$0] }
    }

    public func nearestSample(to elapsed: TimeInterval) -> RecordingSample? {
        guard !samples.isEmpty else { return nil }
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].elapsed < elapsed { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return samples[0] }
        if lower == samples.count { return samples.last }
        return elapsed - samples[lower - 1].elapsed <= samples[lower].elapsed - elapsed
            ? samples[lower - 1] : samples[lower]
    }
}

public struct RecordingLoadIssue: Identifiable, Sendable {
    public let url: URL
    public let message: String
    public var id: URL { url }
}

public struct RecordingIndex: Sendable {
    public let recordings: [RecordingSummary]
    public let issues: [RecordingLoadIssue]
}

public enum RecordingReader {
    private struct JSONPoint: Decodable {
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int
        let nanoseconds: Double
        let fixStatus: Int
        let latitude: Double
        let longitude: Double
        let speedKmh: Double
        let gForceX: Double
        let gForceY: Double
        let gForceZ: Double
    }

    private struct JSONRecording: Decodable {
        let points: [JSONPoint]
        let complete: Bool?
        let pointCount: Int?
        let endReason: String?
    }

    private struct CSVMetadata: Decodable {
        let complete: Bool?
        let pointCount: Int?
        let endReason: String?
    }

    public static func load(_ url: URL) throws -> LoadedRecording {
        let data = try Data(contentsOf: url)
        var rows: [(date: Date, coordinate: TrackCoordinate?, speedKmh: Double?, x: Double, y: Double, z: Double)] = []
        let complete: Bool?
        let reason: String?
        let advertisedCount: Int?
        if url.pathExtension.lowercased() == "json" {
            let document = try JSONDecoder().decode(JSONRecording.self, from: data)
            complete = document.complete
            reason = document.endReason
            advertisedCount = document.pointCount
            rows.reserveCapacity(document.points.count)
            for point in document.points {
                let date = try RecordingTime.utcDate(
                    year: point.year, month: point.month, day: point.day, hour: point.hour,
                    minute: point.minute, second: point.second, nanoseconds: point.nanoseconds
                )
                let coordinate = try coordinate(latitude: point.latitude, longitude: point.longitude,
                                                validFix: point.fixStatus == 3)
                rows.append((date, coordinate, point.fixStatus == 3 ? point.speedKmh : nil,
                             point.gForceX, point.gForceY, point.gForceZ))
            }
        } else if url.pathExtension.lowercased() == "csv" {
            guard let text = String(data: data, encoding: .utf8) else {
                throw RaceBoxError.fileError("The CSV is not UTF-8 encoded.")
            }
            let lines = text.replacingOccurrences(of: "\u{feff}", with: "")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            guard lines.first == RecordingWriter.csvHeader else {
                throw RaceBoxError.fileError("The CSV does not have the RaceBox column layout.")
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let wholeSecondFormatter = ISO8601DateFormatter()
            wholeSecondFormatter.formatOptions = [.withInternetDateTime]
            for (index, line) in lines.dropFirst().enumerated() where !line.isEmpty {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 13, Int(fields[0]) != nil,
                      let date = formatter.date(from: fields[1]) ?? wholeSecondFormatter.date(from: fields[1]),
                      let latitude = Double(fields[2]), let longitude = Double(fields[3]),
                      let speed = Double(fields[5]),
                      let x = Double(fields[6]), let y = Double(fields[7]), let z = Double(fields[8]) else {
                    throw RaceBoxError.fileError("Invalid RaceBox CSV row \(index + 2).")
                }
                rows.append((date, try coordinate(latitude: latitude, longitude: longitude, validFix: true), speed, x, y, z))
            }
            let metadataURL = url.appendingPathExtension("metadata.json")
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                let metadata = try JSONDecoder().decode(CSVMetadata.self, from: Data(contentsOf: metadataURL))
                complete = metadata.complete
                reason = metadata.endReason
                advertisedCount = metadata.pointCount
            } else {
                complete = nil
                reason = nil
                advertisedCount = nil
            }
        } else {
            throw RaceBoxError.fileError("Only RaceBox JSON and CSV recordings are supported.")
        }
        if let advertisedCount, advertisedCount != rows.count {
            throw RaceBoxError.fileError("The recording's point count does not match its saved data.")
        }
        let start = rows.first?.date
        var samples: [RecordingSample] = []
        samples.reserveCapacity(rows.count)
        var previous: TimeInterval = 0
        var speedSegment = 0
        var previousSpeedValid = false
        for (index, row) in rows.enumerated() {
            let elapsed = row.date.timeIntervalSince(start ?? row.date)
            guard elapsed >= previous, row.x.isFinite, row.y.isFinite, row.z.isFinite else {
                throw RaceBoxError.fileError("Point \(index + 1) has an invalid time or G-force value.")
            }
            if let speed = row.speedKmh, !speed.isFinite {
                throw RaceBoxError.fileError("Point \(index + 1) has an invalid speed.")
            }
            let speedValid = row.speedKmh != nil
            if speedValid && !previousSpeedValid { speedSegment += 1 }
            samples.append(RecordingSample(id: index, elapsed: elapsed, coordinate: row.coordinate,
                                            speedKmh: row.speedKmh, speedSegment: speedSegment,
                                            gForceX: row.x, gForceY: row.y, gForceZ: row.z))
            previousSpeedValid = speedValid
            previous = elapsed
        }
        return LoadedRecording(
            summary: RecordingSummary(url: url, pointCount: samples.count, complete: complete,
                                      startedAt: start, duration: samples.last?.elapsed ?? 0),
            samples: samples, endReason: reason
        )
    }

    private static func coordinate(latitude: Double, longitude: Double, validFix: Bool) throws -> TrackCoordinate? {
        guard validFix else { return nil }
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw RaceBoxError.fileError("A recording point has invalid coordinates.")
        }
        return TrackCoordinate(latitude: latitude, longitude: longitude)
    }

    public static func index(directory: URL, excluding: Set<URL> = []) throws -> RecordingIndex {
        let manager = FileManager.default
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let excluding = Set(excluding.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        guard manager.fileExists(atPath: directory.path) else {
            throw RaceBoxError.fileError("The download folder does not exist: \(directory.path)")
        }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw RaceBoxError.fileError("The download location is not a folder: \(directory.path)")
        }
        var issues: [RecordingLoadIssue] = []
        guard let enumerator = manager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                issues.append(RecordingLoadIssue(url: url, message: error.localizedDescription))
                return true
            }
        ) else { throw RaceBoxError.fileError("Could not read the download folder.") }
        var recordings: [RecordingSummary] = []
        for case let url as URL in enumerator {
            let url = url.resolvingSymlinksInPath().standardizedFileURL
            let managed = url.pathComponents.contains("racebox_sessions") || url.pathComponents.contains("racebox_live")
                || url.lastPathComponent.hasPrefix("session-") || url.lastPathComponent.hasPrefix("live-")
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values.isDirectory == true {
                    if !managed { enumerator.skipDescendants() }
                    continue
                }
                guard ["json", "csv"].contains(url.pathExtension.lowercased()),
                      !url.lastPathComponent.lowercased().hasSuffix(".metadata.json"),
                      !excluding.contains(url), values.isRegularFile == true else { continue }
                if !managed {
                    let data = try Data(contentsOf: url)
                    if url.pathExtension.lowercased() == "csv" {
                        guard let text = String(data: data.prefix(512), encoding: .utf8),
                              text.replacingOccurrences(of: "\u{feff}", with: "").hasPrefix(RecordingWriter.csvHeader) else { continue }
                    } else {
                        guard data.range(of: Data("\"points\"".utf8)) != nil else { continue }
                        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              object["points"] != nil else { continue }
                        let first = (object["points"] as? [[String: Any]])?.first
                        let knownContainer = object["session"] != nil || object["source"] as? String == "live"
                        let hasMotion = first?["gForceX"] != nil && first?["gForceY"] != nil && first?["gForceZ"] != nil
                        guard knownContainer || hasMotion else { continue }
                    }
                }
                recordings.append(try load(url).summary)
            } catch {
                issues.append(RecordingLoadIssue(url: url, message: error.localizedDescription))
            }
        }
        recordings.sort {
            let lhs = $0.startedAt ?? .distantPast
            let rhs = $1.startedAt ?? .distantPast
            return lhs == rhs ? $0.url.path < $1.url.path : lhs > rhs
        }
        return RecordingIndex(recordings: recordings, issues: issues)
    }
}
