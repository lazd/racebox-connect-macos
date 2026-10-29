import Foundation
import XCTest
@testable import RaceBoxCore

final class RaceBoxCoreTests: XCTestCase {
    private let literalPayload =
        "a0e70c07e607010a08330837190000002aad4d0e0301ea0b" +
        "c693e10d3b376f19618c09000f0109009c0300002c0700002300000000000000" +
        "d000000088a9dd002c010059fdff7100ce032fff5600fcff"

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    private func packet(_ id: UInt8 = 0x01) -> Packet {
        Packet(id: id, payload: bytes(literalPayload))
    }

    private func status(recording: Bool = false) throws -> MemoryStatus {
        try MemoryStatus(payload: [recording ? 1 : 0, 25, 2, 0, 3, 0, 0, 0, 0, 0, 3, 0])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func canonicalURLs(_ urls: [URL]) -> [URL] {
        urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    func testManufacturerCommands() {
        XCTAssertEqual(Packet(id: 0x23).data, Data(bytes("b562ff2300002265")))
        XCTAssertEqual(Packet(id: 0x24).data, Data(bytes("b562ff2400002368")))
        XCTAssertEqual(Packet.unlock(code: 123456).data, Data(bytes("b562ff30040040e201005608")))
        XCTAssertEqual(Packet(id: 0x23, payload: [0xff]).data, Data(bytes("b562ff230100ff2289")))
    }

    func testFragmentationAtEveryByteAndCombinedNotifications() {
        let frame = packet().data
        for split in 0...frame.count {
            var decoder = PacketDecoder()
            let result = decoder.receive(frame.prefix(split)) + decoder.receive(frame.suffix(frame.count - split))
            XCTAssertEqual(result, [packet()])
            XCTAssertEqual(decoder.invalidFrames, 0)
        }
        var decoder = PacketDecoder()
        XCTAssertEqual(decoder.receive(Data([0, 0xb5]) + frame + frame), [packet(), packet()])
    }

    func testChecksumAndOversizeRecovery() {
        var decoder = PacketDecoder()
        var corrupt = packet().data
        corrupt[10] ^= 1
        XCTAssertEqual(decoder.receive(corrupt + Data(bytes("b562ff01ffff")) + packet().data), [packet()])
        XCTAssertEqual(decoder.invalidFrames, 2)
    }

    func testLostSynchronizationCannotAuthorizeAutomaticDeletion() throws {
        var damaged = packet(0x21).data
        damaged[0] = 0
        var decoder = PacketDecoder()
        let packets = decoder.receive(count(2).data + damaged + packet(0x21).data
                                      + Packet(id: 2, payload: [0xff, 0x23]).data)
        XCTAssertGreaterThan(decoder.invalidFrames, 0)
        let download = HistoryDownload(status: try status(), directory: try temporaryDirectory(), format: .json)
        XCTAssertThrowsError(try packets.forEach { try download.receive($0, invalidFrames: decoder.invalidFrames) })
        XCTAssertFalse(download.safeToErase)
    }

    func testManufacturerTelemetryAndExactNodeSchemas() throws {
        let live = try Telemetry(packet: packet())
        XCTAssertEqual(live.latitude, 42.6719035)
        XCTAssertEqual(live.longitude, 23.2887238)
        XCTAssertEqual(live.altMslM, 590.095)
        XCTAssertEqual(live.speedKmh, 0.126, accuracy: 1e-12)
        XCTAssertEqual(live.satellites, 11)
        XCTAssertTrue(live.hasFix)
        XCTAssertEqual(live.batteryPercent, 89)
        XCTAssertEqual(live.charging, false)
        XCTAssertEqual(live.horizontalAccuracyM, 0.924)
        XCTAssertEqual(live.gForceX, -0.003)
        XCTAssertEqual(live.nanoseconds, 239_971_626)
        let baseKeys: Set<String> = [
            "timestampMs", "year", "month", "day", "hour", "minute", "second", "nanoseconds",
            "fixStatus", "latitude", "longitude", "altMslM", "speedKmh", "headingDeg",
            "gForceX", "gForceY", "gForceZ", "rollRate", "pitchRate", "yawRate"
        ]
        let liveKeys: Set<String> = [
            "satellites", "horizontalAccuracyM", "verticalAccuracyM", "speedAccuracyKmh",
            "headingAccuracyDeg", "pdop", "altWgsM", "batteryPercent", "charging", "utcValid", "timeAccuracyNs"
        ]
        let history = try Telemetry(packet: packet(0x21))
        let historyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        let liveJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(live)) as? [String: Any])
        XCTAssertEqual(Set(historyJSON.keys), baseKeys)
        XCTAssertEqual(Set(liveJSON.keys), baseKeys.union(liveKeys))
    }

    func testFixRequiresBothStatusAndValidFlag() throws {
        var payload = bytes(literalPayload)
        payload[21] = 0
        XCTAssertFalse(try Telemetry(packet: Packet(id: 1, payload: payload)).hasFix)
        payload[21] = 1
        payload[20] = 2
        XCTAssertFalse(try Telemetry(packet: Packet(id: 1, payload: payload)).hasFix)
    }

    func testStatusAndMalformedPayloads() throws {
        let memory = try status()
        XCTAssertEqual(memory.storedRecords, 3)
        XCTAssertEqual(memory.capacityRecords, 196608)
        XCTAssertTrue(memory.unlocked)
        XCTAssertFalse(memory.securityEnabled)
        XCTAssertThrowsError(try MemoryStatus(payload: [0]))
        XCTAssertThrowsError(try Telemetry(packet: Packet(id: 1, payload: [0])))
    }

    func testStreamingJSONAndLiveFooter() throws {
        let point = try Telemetry(packet: packet())
        let writer = try RecordingWriter(directory: temporaryDirectory(), firstPoint: point, format: .json, live: true)
        try writer.append(point)
        XCTAssertTrue(try String(contentsOf: writer.url, encoding: .utf8).contains("\"latitude\":42.6719035"))
        try writer.append(point)
        try writer.finish(complete: false, invalidFrames: 1, reason: "Disconnected \"early\"")
        let json = try readJSON(writer.url)
        XCTAssertEqual(Set(json.keys), ["source", "points", "pointCount", "complete", "invalidFrames", "endReason"])
        XCTAssertEqual(json["source"] as? String, "live")
        XCTAssertEqual(json["pointCount"] as? Int, 2)
        XCTAssertEqual(json["invalidFrames"] as? Int, 1)
        XCTAssertEqual(json["complete"] as? Bool, false)
        XCTAssertEqual(json["endReason"] as? String, "Disconnected \"early\"")
        XCTAssertThrowsError(try writer.append(point))
    }

    func testCSVExactlyMatchesAttachedLayoutAndNegativeNanoseconds() throws {
        var payload = [UInt8](repeating: 0, count: 80)
        func put(_ value: UInt32, at offset: Int, length: Int = 4) {
            for i in 0..<length { payload[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        put(2026, at: 4, length: 2)
        payload[6] = 10
        payload[7] = 29
        payload[8] = 6
        payload[9] = 56
        payload[10] = 11
        put(UInt32(bitPattern: -360_000_000), at: 16)
        put(UInt32(bitPattern: -1_206_144_816), at: 24)
        put(387_335_425, at: 28)
        put(1_112_000, at: 36)
        put(283, at: 48)
        put(225, at: 68, length: 2)
        put(UInt32(UInt16(bitPattern: -21)), at: 70, length: 2)
        put(994, at: 72, length: 2)
        put(19, at: 74, length: 2)
        put(UInt32(UInt16(bitPattern: -57)), at: 76, length: 2)
        put(UInt32(UInt16(bitPattern: -7)), at: 78, length: 2)
        let point = try Telemetry(packet: Packet(id: 0x21, payload: payload))
        let writer = try RecordingWriter(directory: temporaryDirectory(), firstPoint: point, format: .csv, live: false)
        try writer.append(point)
        try writer.finish(complete: true, invalidFrames: 0, reason: "Download complete")
        let csv = try String(contentsOf: writer.url, encoding: .utf8)
        XCTAssertEqual(csv, RecordingWriter.csvHeader + "\n"
            + "1,2026-10-29T06:56:10.640Z,38.7335425,-120.6144816,1112.0,1.02,0.225,-0.021,0.994,0,0.19,-0.57,-0.07\n")
        XCTAssertEqual(try readJSON(writer.url.appendingPathExtension("metadata.json"))["complete"] as? Bool, true)
    }

    private func count(_ value: UInt32) -> Packet {
        Packet(id: 0x23, payload: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func boundary(_ state: UInt8) -> Packet {
        Packet(id: 0x26, payload: [state] + [UInt8](repeating: 0, count: 11))
    }

    func testHistoryBoundariesKeepPauseResumeTogether() throws {
        let download = HistoryDownload(status: try status(), directory: try temporaryDirectory(), format: .json)
        for frame in [count(4), packet(0x21), boundary(2), boundary(1),
                      packet(0x21), boundary(0), boundary(1), packet(0x21)] {
            XCTAssertFalse(try download.receive(frame, invalidFrames: 0))
        }
        XCTAssertTrue(try download.receive(Packet(id: 2, payload: [0xff, 0x23]), invalidFrames: 0))
        XCTAssertTrue(download.safeToErase)
        XCTAssertEqual(download.files.count, 2)
        XCTAssertEqual(try download.files.map { try readJSON($0)["pointCount"] as? Int }, [2, 1])
        for (index, url) in download.files.enumerated() {
            let json = try readJSON(url)
            XCTAssertEqual(Set(json.keys), ["session", "points", "pointCount", "complete", "endReason"])
            XCTAssertEqual(json["session"] as? Int, index + 1)
            XCTAssertEqual(json["complete"] as? Bool, true)
        }
    }

    func testZeroExcessAndCorruptHistoryNeverAllowsDeletion() throws {
        for (expected, number, invalid) in [(0, 0, 0), (0, 1, 0), (1, 1, 1)] {
            let download = HistoryDownload(status: try status(), directory: try temporaryDirectory(), format: .json)
            try download.receive(count(UInt32(expected)), invalidFrames: 0)
            for _ in 0..<number { try download.receive(packet(0x21), invalidFrames: invalid) }
            XCTAssertThrowsError(try download.receive(Packet(id: 2, payload: [0xff, 0x23]), invalidFrames: invalid))
            XCTAssertFalse(download.safeToErase)
            for url in download.files { XCTAssertEqual(try readJSON(url)["complete"] as? Bool, false) }
        }
    }

    func testActiveRecordingLeavesLastSessionIncompleteAndNeverErases() throws {
        let download = HistoryDownload(status: try status(recording: true), directory: try temporaryDirectory(), format: .json)
        try download.receive(count(1), invalidFrames: 0)
        try download.receive(packet(0x21), invalidFrames: 0)
        try download.receive(Packet(id: 2, payload: [0xff, 0x23]), invalidFrames: 0)
        XCTAssertFalse(download.safeToErase)
        XCTAssertEqual(try readJSON(XCTUnwrap(download.files.first))["complete"] as? Bool, false)
    }

    func testInterruptedHistoryRemainsReadableAndDoesNotOverwrite() throws {
        let directory = try temporaryDirectory()
        var urls: [URL] = []
        for _ in 0..<2 {
            let download = HistoryDownload(status: try status(), directory: directory, format: .json)
            try download.receive(count(2), invalidFrames: 0)
            try download.receive(packet(0x21), invalidFrames: 0)
            try download.interrupt(reason: "Timed out", invalidFrames: 0)
            XCTAssertFalse(download.safeToErase)
            let url = try XCTUnwrap(download.files.first)
            XCTAssertEqual(try readJSON(url)["complete"] as? Bool, false)
            urls.append(url)
        }
        XCTAssertNotEqual(urls[0], urls[1])
    }

    private func completedDownload(directory: URL, format: ExportFormat,
                                   frames: [Packet]? = nil) throws -> HistoryDownload {
        let frames = frames ?? [packet(0x21)]
        let download = HistoryDownload(status: try status(), directory: directory, format: format)
        try download.receive(count(UInt32(frames.filter { $0.id == 0x21 }.count)), invalidFrames: 0)
        for frame in frames { try download.receive(frame, invalidFrames: 0) }
        try download.receive(Packet(id: 2, payload: [0xff, 0x23]), invalidFrames: 0)
        return download
    }

    func testRepeatedHistorySkipsCompleteJSONAndCSVWithoutChangingExistingFiles() throws {
        for format in ExportFormat.allCases {
            let directory = try temporaryDirectory()
            let first = try completedDownload(directory: directory, format: format)
            let url = try XCTUnwrap(first.files.first)
            let original = try Data(contentsOf: url)
            let metadataURL = url.appendingPathExtension("metadata.json")
            let metadata = format == .csv ? try Data(contentsOf: metadataURL) : nil
            for _ in 0..<2 {
                let repeated = try completedDownload(directory: directory, format: format)
                XCTAssertTrue(repeated.files.isEmpty)
                XCTAssertEqual(canonicalURLs(repeated.skippedRecordings.map(\.url)), canonicalURLs([url]))
                XCTAssertEqual(repeated.received, 1)
                XCTAssertEqual(repeated.savedPointCount, 0)
                XCTAssertTrue(repeated.safeToErase)
                XCTAssertEqual(try Data(contentsOf: url), original)
                if let metadata { XCTAssertEqual(try Data(contentsOf: metadataURL), metadata) }
            }
            let outputs = try FileManager.default.contentsOfDirectory(
                at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            XCTAssertEqual(outputs.count, format == .csv ? 2 : 1)
        }
    }

    func testJSONDuplicatesIgnoreFilenameKeyOrderAndSessionMetadata() throws {
        let directory = try temporaryDirectory()
        let first = try completedDownload(directory: directory, format: .json)
        let originalURL = try XCTUnwrap(first.files.first)
        var document = try readJSON(originalURL)
        document["session"] = 99
        document["endReason"] = "recording-stopped"
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        let legacyURL = originalURL.deletingLastPathComponent().appendingPathComponent("session-08-51-08.json")
        try data.write(to: legacyURL)
        try FileManager.default.removeItem(at: originalURL)
        let repeated = try completedDownload(directory: directory, format: .json)
        XCTAssertTrue(repeated.files.isEmpty)
        XCTAssertEqual(canonicalURLs(repeated.skippedRecordings.map(\.url)), canonicalURLs([legacyURL]))
        XCTAssertEqual(try Data(contentsOf: legacyURL), data)
    }

    func testSameStartWithChangedOrAdditionalPointsIsNotADuplicate() throws {
        var changed = bytes(literalPayload)
        changed[68] ^= 1
        let changedPoint = Packet(id: 0x21, payload: changed)
        for format in ExportFormat.allCases {
            for frames in [[changedPoint], [packet(0x21), packet(0x21)]] {
                let directory = try temporaryDirectory()
                let first = try completedDownload(directory: directory, format: format)
                let next = try completedDownload(directory: directory, format: format, frames: frames)
                XCTAssertEqual(next.files.count, 1)
                XCTAssertTrue(next.skippedRecordings.isEmpty)
                XCTAssertEqual(next.savedPointCount, frames.count)
                XCTAssertNotEqual(next.files, first.files)
                XCTAssertTrue(next.safeToErase)
            }
        }
    }

    func testCompleteDownloadsDoNotSkipIncompleteBackupsOrOtherFormats() throws {
        for format in ExportFormat.allCases {
            let directory = try temporaryDirectory()
            let partial = HistoryDownload(status: try status(), directory: directory, format: format)
            try partial.receive(count(1), invalidFrames: 0)
            try partial.receive(packet(0x21), invalidFrames: 0)
            try partial.interrupt(reason: "Disconnected", invalidFrames: 0)
            let complete = try completedDownload(directory: directory, format: format)
            XCTAssertEqual(complete.files.count, 1)
            XCTAssertTrue(complete.skippedRecordings.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(partial.files.first).path))
            let other = try completedDownload(directory: directory, format: format == .json ? .csv : .json)
            XCTAssertEqual(other.files.count, 1)
            XCTAssertTrue(other.skippedRecordings.isEmpty)
        }
    }

    func testInterruptedDownloadsDoNotSkipOrEraseCompleteBackups() throws {
        for format in ExportFormat.allCases {
            let directory = try temporaryDirectory()
            let first = try completedDownload(directory: directory, format: format)
            let partial = HistoryDownload(status: try status(), directory: directory, format: format)
            try partial.receive(count(1), invalidFrames: 0)
            try partial.receive(packet(0x21), invalidFrames: 0)
            try partial.interrupt(reason: "Cancelled", invalidFrames: 0)
            XCTAssertEqual(partial.files.count, 1)
            XCTAssertTrue(partial.skippedRecordings.isEmpty)
            XCTAssertFalse(partial.safeToErase)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(first.files.first).path))
        }
    }

    func testMixedDownloadReportsOnlyNewPointsAndKeepsExistingRecording() throws {
        let directory = try temporaryDirectory()
        let first = try completedDownload(directory: directory, format: .json)
        var later = bytes(literalPayload)
        later[10] += 1
        let mixed = try completedDownload(directory: directory, format: .json,
                                          frames: [packet(0x21), boundary(0), Packet(id: 0x21, payload: later)])
        XCTAssertEqual(mixed.received, 2)
        XCTAssertEqual(mixed.savedPointCount, 1)
        XCTAssertEqual(mixed.files.count, 1)
        XCTAssertEqual(canonicalURLs(mixed.skippedRecordings.map(\.url)), canonicalURLs(first.files))
        XCTAssertTrue(mixed.safeToErase)
    }

    func testUnreadableBackupsAreReportedWithoutBlockingNewSavesOrAuthorizingErase() throws {
        for format in ExportFormat.allCases {
            let directory = try temporaryDirectory()
            let first = try completedDownload(directory: directory, format: format)
            let originalURL = try XCTUnwrap(first.files.first)
            let brokenURL = format == .json ? originalURL : originalURL.appendingPathExtension("metadata.json")
            let brokenData = Data("{unfinished".utf8)
            try brokenData.write(to: brokenURL)
            let next = HistoryDownload(status: try status(), directory: directory, format: format)
            try next.receive(count(1), invalidFrames: 0)
            try next.receive(packet(0x21), invalidFrames: 0)
            let newURL = try XCTUnwrap(next.activeFileURL)
            XCTAssertTrue(try next.receive(Packet(id: 2, payload: [0xff, 0x23]), invalidFrames: 0))
            XCTAssertFalse(next.safeToErase)
            XCTAssertEqual(next.duplicateCheckIssues.count, 1)
            XCTAssertEqual(canonicalURLs(next.duplicateCheckIssues.map(\.url)), canonicalURLs([originalURL]))
            XCTAssertEqual(next.files, [newURL])
            XCTAssertEqual(try Data(contentsOf: brokenURL), brokenData)
            XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        }
    }

    func testDuplicateDetectionThroughSymlinkNeverDeletesItsOwnOutput() throws {
        let directory = try temporaryDirectory()
        let actual = directory.appendingPathComponent("actual")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        for format in ExportFormat.allCases {
            let first = try completedDownload(directory: alias, format: format)
            let url = try XCTUnwrap(first.files.first)
            XCTAssertTrue(first.skippedRecordings.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let repeated = try completedDownload(directory: alias, format: format)
            XCTAssertTrue(repeated.files.isEmpty)
            XCTAssertEqual(repeated.skippedRecordings.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testFileFailureIsExplicitAndCannotAuthorizeErase() throws {
        let directory = try temporaryDirectory().appendingPathComponent("not-a-directory")
        try Data([0]).write(to: directory)
        let download = HistoryDownload(status: try status(), directory: directory, format: .json)
        try download.receive(count(1), invalidFrames: 0)
        XCTAssertThrowsError(try download.receive(packet(0x21), invalidFrames: 0))
        XCTAssertFalse(download.safeToErase)
        XCTAssertTrue(download.files.isEmpty)
    }

    func testLiveCaptureWaitsForFixThenPausesAndResumesInSameFile() throws {
        for format in ExportFormat.allCases {
            let directory = try temporaryDirectory()
            let capture = LiveCapture(directory: directory, format: format)
            var noFixPayload = bytes(literalPayload)
            noFixPayload[21] = 0
            let noFix = try Telemetry(packet: Packet(id: 1, payload: noFixPayload))
            let point = try Telemetry(packet: packet())
            XCTAssertFalse(try capture.receive(noFix))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            XCTAssertTrue(try capture.receive(point))
            XCTAssertFalse(try capture.receive(noFix))
            XCTAssertTrue(try capture.receive(point))
            XCTAssertEqual(capture.count, 2)
            let result = try XCTUnwrap(capture.finish(complete: true, invalidFrames: 0, reason: "Stopped by user"))
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.pointCount, 2)
            if format == .json {
                XCTAssertEqual(try readJSON(result.url)["pointCount"] as? Int, 2)
            } else {
                XCTAssertEqual(try String(contentsOf: result.url, encoding: .utf8).split(separator: "\n").count, 3)
            }
            XCTAssertThrowsError(try capture.receive(point))
        }
    }

    func testLiveCaptureWithoutFixCreatesNothingAndInterruptionsStayIncomplete() throws {
        let directory = try temporaryDirectory()
        let empty = LiveCapture(directory: directory, format: .json)
        XCTAssertNil(try empty.finish(complete: true, invalidFrames: 0, reason: "Stopped"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        for (complete, invalid) in [(false, 0), (true, 1)] {
            let capture = LiveCapture(directory: directory, format: .json)
            try capture.receive(Telemetry(packet: packet()))
            let result = try XCTUnwrap(capture.finish(complete: complete, invalidFrames: invalid, reason: "Disconnected"))
            XCTAssertFalse(result.complete)
            XCTAssertEqual(try readJSON(result.url)["complete"] as? Bool, false)
        }
    }

    func testCSVMetadataFailurePreventsSuccessfulDownload() throws {
        let directory = try temporaryDirectory()
        let download = HistoryDownload(status: try status(), directory: directory, format: .csv)
        try download.receive(count(1), invalidFrames: 0)
        try download.receive(packet(0x21), invalidFrames: 0)
        let root = try XCTUnwrap(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil))
        let csv = try XCTUnwrap(root.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "csv" })
        try FileManager.default.createDirectory(at: csv.appendingPathExtension("metadata.json"),
                                                withIntermediateDirectories: false)
        XCTAssertThrowsError(try download.receive(Packet(id: 2, payload: [0xff, 0x23]), invalidFrames: 0))
        XCTAssertFalse(download.safeToErase)
    }
}
