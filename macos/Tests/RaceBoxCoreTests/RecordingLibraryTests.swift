import Foundation
import XCTest
@testable import RaceBoxCore

final class RecordingLibraryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func point(second: Int = 10, nanos: Int = 640_000_000, fix: Int = 3,
                       speed: Double = 36, x: Double = 0.225, y: Double = -0.021, z: Double = 0.994) -> [String: Any] {
        [
            "year": 2026, "month": 10, "day": 29, "hour": 6, "minute": 56,
            "second": second, "nanoseconds": nanos, "fixStatus": fix,
            "latitude": 38.7335425, "longitude": -120.6144816,
            "speedKmh": speed,
            "gForceX": x, "gForceY": y, "gForceZ": z
        ]
    }

    @discardableResult
    private func writeJSON(_ points: [[String: Any]], to url: URL, complete: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "session": 1, "points": points, "complete": complete,
            "pointCount": points.count, "endReason": complete ? "Download complete" : "Disconnected"
        ]).write(to: url)
        return url
    }

    func testJSONLoadsTrackMotionSignedNanosecondsAndElapsedTime() throws {
        let url = try directory().appendingPathComponent("session-test.json")
        try writeJSON([point(second: 11, nanos: -360_000_000), point(second: 11, nanos: -320_000_000)], to: url)
        let recording = try RecordingReader.load(url)
        XCTAssertEqual(recording.summary.pointCount, 2)
        XCTAssertEqual(recording.summary.complete, true)
        XCTAssertEqual(recording.summary.duration, 0.04, accuracy: 1e-6)
        XCTAssertEqual(recording.samples[0].gForceX, 0.225)
        XCTAssertEqual(recording.samples[0].gForceY, -0.021)
        XCTAssertEqual(recording.samples[0].gForceZ, 0.994)
        XCTAssertEqual(recording.samples[0].speedKmh, 36)
        XCTAssertEqual(recording.trackSegments[0][0].latitude, 38.7335425)
        XCTAssertEqual(recording.trackSegments[0][0].longitude, -120.6144816)
        XCTAssertEqual(recording.nearestSample(to: 0.039)?.id, 1)
        XCTAssertEqual(recording.nearestSample(to: -1)?.id, 0)
        XCTAssertEqual(recording.nearestSample(to: 99)?.id, 1)
    }

    func testCSVReadsAttachedLayoutCRLFAndOptionalMetadata() throws {
        let url = try directory().appendingPathComponent("RaceBox Track Session.csv")
        let csv = "\u{feff}" + RecordingWriter.csvHeader + "\r\n"
            + "1,2026-10-29T06:56:10.640Z,38.7335425,-120.6144816,1112.0,1.02,0.225,-0.021,0.994,0,0.19,-0.57,-0.07\r\n"
            + "2,2026-10-29T06:56:10.680Z,38.7335425,-120.6144813,1112.0,1.04,0.240,-0.019,0.994,0,0.20,-0.57,-0.12\r\n"
        try Data(csv.utf8).write(to: url)
        let imported = try RecordingReader.load(url)
        XCTAssertNil(imported.summary.complete)
        XCTAssertEqual(imported.summary.pointCount, 2)
        XCTAssertEqual(imported.summary.duration, 0.04, accuracy: 1e-6)
        XCTAssertEqual(imported.samples[1].gForceX, 0.240)
        XCTAssertEqual(imported.samples[0].speedKmh, 1.02)
        XCTAssertEqual(imported.samples[1].speedKmh, 1.04)
        XCTAssertEqual(imported.statistics.maxSpeedKmh, 1.04)
        try JSONSerialization.data(withJSONObject: [
            "pointCount": 2, "complete": false, "endReason": "Device disconnected"
        ]).write(to: url.appendingPathExtension("metadata.json"))
        let incomplete = try RecordingReader.load(url)
        XCTAssertEqual(incomplete.summary.complete, false)
        XCTAssertEqual(incomplete.endReason, "Device disconnected")
        let index = try RecordingReader.index(directory: url.deletingLastPathComponent())
        XCTAssertEqual(index.recordings.count, 1)
        XCTAssertTrue(index.issues.isEmpty)
    }

    func testIndexFindsPreviousDownloadsAndLiveCapturesAndExcludesActiveFiles() throws {
        let root = try directory()
        let older = try writeJSON([point()], to: root.appendingPathComponent("racebox_sessions/2026-10-29/session-old.json"))
        let newer = try writeJSON([point(second: 12)], to: root.appendingPathComponent("racebox_live/2026-10-29/live-new.json"))
        let active = root.appendingPathComponent("racebox_live/live-active.json")
        try Data("{\"points\":[".utf8).write(to: active)
        try Data("{\"not\":\"a recording\"}".utf8).write(to: root.appendingPathComponent("other.json"))
        try Data("{\"points\":[{\"x\":0,\"y\":1}]}".utf8).write(to: root.appendingPathComponent("geometry.json"))
        try Data("name,value\nx,y\n".utf8).write(to: root.appendingPathComponent("other.csv"))
        let index = try RecordingReader.index(directory: root, excluding: [active])
        XCTAssertEqual(index.recordings.map(\.url), [newer, older])
        XCTAssertTrue(index.issues.isEmpty)
    }

    func testIndexReportsBrokenRecordingsWithoutHidingGoodFilesOrIncludingSidecars() throws {
        let root = try directory()
        let valid = try writeJSON([point()], to: root.appendingPathComponent("session-valid.json"))
        let broken = root.appendingPathComponent("session-broken.json")
        try Data("{\"points\":[".utf8).write(to: broken)
        try Data("{}".utf8).write(to: valid.appendingPathExtension("metadata.json"))
        let index = try RecordingReader.index(directory: root)
        XCTAssertEqual(index.recordings.map(\.url), [valid])
        XCTAssertEqual(index.issues.map(\.url), [broken])
        XCTAssertThrowsError(try RecordingReader.index(directory: root.appendingPathComponent("missing")))
    }

    func testIndexResolvesFolderAliasesBeforeExcludingActiveFiles() throws {
        let root = try directory()
        let real = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let active = real.appendingPathComponent("session-active.json")
        try Data("{\"points\":[".utf8).write(to: active)
        let result = try RecordingReader.index(directory: alias,
                                               excluding: [alias.appendingPathComponent("session-active.json")])
        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testNoFixPointsSplitTrackWithoutRemovingMotionSamples() throws {
        let url = try writeJSON([point(), point(nanos: 680_000_000, fix: 0),
                                 point(nanos: 720_000_000)], to: directory().appendingPathComponent("session.json"))
        let recording = try RecordingReader.load(url)
        XCTAssertEqual(recording.samples.count, 3)
        XCTAssertNil(recording.samples[1].coordinate)
        XCTAssertEqual(recording.trackSegments.map(\.count), [1, 1])
        XCTAssertNil(recording.samples[1].speedKmh)
        XCTAssertNotEqual(recording.samples[0].speedSegment, recording.samples[2].speedSegment)
    }

    func testSessionStatisticsSeparateAccelerationBrakingAndCorneringDirections() throws {
        let url = try writeJSON([
            point(speed: 36, x: 0.8, y: -0.6, z: 1.3),
            point(nanos: 680_000_000, speed: 72, x: -1.2, y: 0.9, z: -0.4),
            point(nanos: 720_000_000, fix: 0, speed: 9999, x: -2, y: -1.5, z: -3),
            point(nanos: 760_000_000, speed: 54, x: 1.1, y: -1.4, z: 2.2)
        ], to: directory().appendingPathComponent("session.json"))
        let statistics = try RecordingReader.load(url).statistics
        XCTAssertEqual(statistics.maxSpeedKmh, 72)
        XCTAssertEqual(statistics.accelerationG, 1.1)
        XCTAssertEqual(statistics.brakingG, 2)
        XCTAssertEqual(statistics.cornering?.positive, 0.9)
        XCTAssertEqual(statistics.cornering?.negative, -1.5)
        XCTAssertEqual(statistics.cornering?.magnitude, 1.5)
        XCTAssertEqual(statistics.vertical?.positive, 2.2)
        XCTAssertEqual(statistics.vertical?.negative, -3)
        XCTAssertEqual(statistics.vertical?.magnitude, 3)
    }

    func testOneSidedAndEmptyStatisticsDoNotConfuseBrakingWithAcceleration() throws {
        let url = try directory().appendingPathComponent("session.json")
        try writeJSON([point(x: -2.5), point(nanos: 680_000_000, x: -0.2)], to: url)
        var statistics = try RecordingReader.load(url).statistics
        XCTAssertEqual(statistics.accelerationG, 0)
        XCTAssertEqual(statistics.brakingG, 2.5)
        try writeJSON([point(x: 1.2)], to: url)
        statistics = try RecordingReader.load(url).statistics
        XCTAssertEqual(statistics.accelerationG, 1.2)
        XCTAssertEqual(statistics.brakingG, 0)
        try writeJSON([point(fix: 0, speed: 999)], to: url)
        XCTAssertNil(try RecordingReader.load(url).statistics.maxSpeedKmh)
        try writeJSON([], to: url)
        statistics = try RecordingReader.load(url).statistics
        XCTAssertNil(statistics.maxSpeedKmh)
        XCTAssertNil(statistics.accelerationG)
        XCTAssertNil(statistics.brakingG)
        XCTAssertNil(statistics.cornering)
        XCTAssertNil(statistics.vertical)
    }

    func testSignedSpeedsArePreservedAndNonfiniteSpeedsAreReported() throws {
        let url = try directory().appendingPathComponent("session.json")
        try writeJSON([point(speed: -1)], to: url)
        XCTAssertEqual(try RecordingReader.load(url).samples.first?.speedKmh, -1)
        let csv = url.deletingPathExtension().appendingPathExtension("csv")
        for speed in ["nan", "inf", "not-a-number"] {
            try Data((RecordingWriter.csvHeader + "\n"
                + "1,2026-10-29T06:56:10.640Z,38.7335425,-120.6144816,1112.0,\(speed),0.225,-0.021,0.994,0,0.19,-0.57,-0.07\n").utf8).write(to: csv)
            XCTAssertThrowsError(try RecordingReader.load(csv))
        }
    }

    func testChartRetainsSpeedPeakAndBothSidesOfFixLoss() {
        let samples: [RecordingSample] = (0..<10_000).map { index in
            let speed: Double? = (2000..<2200).contains(index) ? nil : (index == 1333 ? 130 : 36)
            return RecordingSample(id: index, elapsed: Double(index) / 25, coordinate: nil,
                                   speedKmh: speed, speedSegment: index < 2200 ? 1 : 2,
                                   gForceX: 0, gForceY: 0, gForceZ: 1)
        }
        let recording = LoadedRecording(
            summary: RecordingSummary(url: URL(fileURLWithPath: "/session.json"), pointCount: samples.count,
                                      complete: true, startedAt: nil, duration: 399.96),
            samples: samples, endReason: nil)
        let chart = recording.chartSamples(buckets: 80)
        XCTAssertTrue(Set(chart.map(\.id)).isSuperset(of: [0, 1333, 1999, 2200, 9999]))
        XCTAssertEqual(recording.statistics.maxSpeedKmh, 130)
        XCTAssertLessThan(chart.count, samples.count)
        XCTAssertEqual(chart.map(\.id), chart.map(\.id).sorted())
    }

    func testInvalidCoordinatesDatesCountsAndReversedTimesAreExplicitErrors() throws {
        let url = try directory().appendingPathComponent("session.json")
        var invalidCoordinate = point()
        invalidCoordinate["latitude"] = 91
        try writeJSON([invalidCoordinate], to: url)
        XCTAssertThrowsError(try RecordingReader.load(url))
        var invalidDate = point()
        invalidDate["month"] = 13
        try writeJSON([invalidDate], to: url)
        XCTAssertThrowsError(try RecordingReader.load(url))
        try writeJSON([point(second: 12), point(second: 11)], to: url)
        XCTAssertThrowsError(try RecordingReader.load(url))
        try JSONSerialization.data(withJSONObject: ["points": [point()], "pointCount": 2]).write(to: url)
        XCTAssertThrowsError(try RecordingReader.load(url))
    }

    func testDownsamplingPreservesAllAxisSpikesAndChronologicalEndpoints() {
        let samples: [RecordingSample] = (0..<10_000).map { index in
            let x: Double = index == 777 ? 4 : 0
            let y: Double = index == 4222 ? -3 : 0
            let z: Double = index == 8888 ? 5 : 1
            return RecordingSample(id: index, elapsed: Double(index) / 25, coordinate: nil,
                                   speedKmh: nil, speedSegment: 0, gForceX: x, gForceY: y, gForceZ: z)
        }
        let recording = LoadedRecording(
            summary: RecordingSummary(url: URL(fileURLWithPath: "/session.json"), pointCount: samples.count,
                                      complete: true, startedAt: nil, duration: 399.96),
            samples: samples, endReason: nil)
        let result = recording.chartSamples(buckets: 80)
        XCTAssertLessThanOrEqual(result.count, 80 * 6 + 2)
        XCTAssertEqual(result.first?.id, 0)
        XCTAssertEqual(result.last?.id, 9999)
        XCTAssertTrue(Set(result.map(\.id)).isSuperset(of: [777, 4222, 8888]))
        XCTAssertEqual(result.map(\.id), result.map(\.id).sorted())
    }

    func testStandaloneCommandsPreserveEverySettingExceptEnable() throws {
        let original: [UInt8] = [0, 0, 0x1f, 0, 0x6d, 5, 30, 0, 30, 0, 0x2c, 1]
        let configuration = try RecordingConfiguration(payload: original)
        let command = configuration.command(enabled: true)
        XCTAssertEqual(command.id, 0x25)
        XCTAssertEqual(Array(command.payload.dropFirst()), Array(original.dropFirst()))
        XCTAssertEqual(command.payload[0], 1)
        XCTAssertEqual(command.data, Data([
            0xb5, 0x62, 0xff, 0x25, 0x0c, 0, 1, 0, 0x1f, 0, 0x6d, 5, 30, 0, 30, 0, 0x2c, 1, 0x2b, 0x15
        ]))
        XCTAssertEqual(try RecordingConfiguration(payload: command.payload).command(enabled: false).payload, original)
    }

    func testMemoryDurationsUseAllSupportedRatesAndExplicitUnits() throws {
        for (code, rate) in [(0, 25.0), (1, 10.0), (2, 5.0), (3, 1.0), (4, 20.0)] {
            let config = try RecordingConfiguration(payload: [0, UInt8(code)] + [UInt8](repeating: 0, count: 10))
            XCTAssertEqual(config.samplesPerSecond, rate)
            XCTAssertEqual(config.duration(records: UInt32(rate * 3661)), "1h 1m 1s")
        }
        XCTAssertEqual(RecordingTime.duration(0), "0h 0m 0s")
        XCTAssertEqual(RecordingTime.axisLabel(106.16), "1:46")
        XCTAssertEqual(RecordingTime.axisLabel(3661), "1:01:01")
        XCTAssertThrowsError(try RecordingConfiguration(payload: [0, 5] + [UInt8](repeating: 0, count: 10)))
        XCTAssertThrowsError(try RecordingConfiguration(payload: [0]))
    }
}
