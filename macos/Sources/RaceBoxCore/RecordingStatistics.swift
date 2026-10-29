import Foundation

public struct GForcePeaks: Sendable {
    public let positive: Double
    public let negative: Double
    public var magnitude: Double { max(positive, -negative) }
}

public struct RecordingStatistics: Sendable {
    public let maxSpeedKmh: Double?
    public let accelerationG: Double?
    public let brakingG: Double?
    public let cornering: GForcePeaks?
    public let vertical: GForcePeaks?

    init(samples: [RecordingSample]) {
        var maxSpeed: Double?
        var maxX = 0.0
        var minX = 0.0
        var maxY = 0.0
        var minY = 0.0
        var maxZ = 0.0
        var minZ = 0.0
        for sample in samples {
            if let speed = sample.speedKmh { maxSpeed = max(maxSpeed ?? speed, speed) }
            maxX = max(maxX, sample.gForceX)
            minX = min(minX, sample.gForceX)
            maxY = max(maxY, sample.gForceY)
            minY = min(minY, sample.gForceY)
            maxZ = max(maxZ, sample.gForceZ)
            minZ = min(minZ, sample.gForceZ)
        }
        maxSpeedKmh = maxSpeed
        accelerationG = samples.isEmpty ? nil : maxX
        brakingG = samples.isEmpty ? nil : max(0, -minX)
        cornering = samples.isEmpty ? nil : GForcePeaks(positive: maxY, negative: minY)
        vertical = samples.isEmpty ? nil : GForcePeaks(positive: maxZ, negative: minZ)
    }
}
