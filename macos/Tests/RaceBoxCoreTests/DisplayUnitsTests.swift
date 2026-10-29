import Foundation
import XCTest
@testable import RaceBoxCore

final class DisplayUnitsTests: XCTestCase {
    func testAutomaticUsesRegionalMeasurementSystem() {
        for identifier in ["en_US", "en_GB"] {
            XCTAssertEqual(DisplayUnits.automatic.resolved(locale: Locale(identifier: identifier)), .imperial)
        }
        for identifier in ["de_DE", "fr_FR", "en_CA", "ja_JP"] {
            XCTAssertEqual(DisplayUnits.automatic.resolved(locale: Locale(identifier: identifier)), .metric)
        }
    }

    func testExplicitChoiceOverridesLocale() {
        XCTAssertEqual(DisplayUnits.metric.resolved(locale: Locale(identifier: "en_US")), .metric)
        XCTAssertEqual(DisplayUnits.imperial.resolved(locale: Locale(identifier: "de_DE")), .imperial)
    }

    func testSpeedAndSpeedAccuracyConversions() {
        XCTAssertEqual(DisplayUnits.imperial.speed(fromKmh: 1.609344), 1, accuracy: 1e-8)
        XCTAssertEqual(DisplayUnits.imperial.speed(fromKmh: 100), 62.13711922, accuracy: 1e-6)
        XCTAssertEqual(DisplayUnits.imperial.speed(fromKmh: 0.1609344), 0.1, accuracy: 1e-8)
        XCTAssertEqual(DisplayUnits.imperial.speed(fromKmh: 0), 0)
        XCTAssertEqual(DisplayUnits.metric.speed(fromKmh: 100), 100)
        XCTAssertEqual(DisplayUnits.imperial.speedSymbol, "mph")
        XCTAssertEqual(DisplayUnits.metric.speedSymbol, "km/h")
    }

    func testAltitudeAndAccuracyConversions() {
        XCTAssertEqual(DisplayUnits.imperial.length(fromMeters: 0.3048), 1, accuracy: 1e-10)
        XCTAssertEqual(DisplayUnits.imperial.length(fromMeters: -3.048), -10, accuracy: 1e-10)
        XCTAssertEqual(DisplayUnits.imperial.length(fromMeters: 0), 0)
        XCTAssertEqual(DisplayUnits.metric.length(fromMeters: -3.048), -3.048)
        XCTAssertEqual(DisplayUnits.imperial.lengthSymbol, "ft")
        XCTAssertEqual(DisplayUnits.metric.lengthSymbol, "m")
    }
}
