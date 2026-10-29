import Foundation

public enum DisplayUnits: String, CaseIterable, Identifiable {
    case automatic
    case metric
    case imperial

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Automatic (locale)"
        case .metric: return "Metric (km/h, meters)"
        case .imperial: return "Imperial (mph, feet)"
        }
    }

    public func resolved(locale: Locale = .autoupdatingCurrent) -> DisplayUnits {
        guard self == .automatic else { return self }
        return locale.measurementSystem == .us || locale.measurementSystem == .uk ? .imperial : .metric
    }

    public var speedSymbol: String { resolved() == .imperial ? "mph" : "km/h" }
    public var lengthSymbol: String { resolved() == .imperial ? "ft" : "m" }
    public var lengthName: String { resolved() == .imperial ? "feet" : "meters" }

    public func speed(fromKmh value: Double) -> Double {
        guard resolved() == .imperial else { return value }
        // Foundation rounds its km/h-to-SI coefficient; use the exact international mile.
        return value / 1.609344
    }

    public func length(fromMeters value: Double) -> Double {
        guard resolved() == .imperial else { return value }
        return value / 0.3048
    }
}
