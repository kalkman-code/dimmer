import Foundation

struct DimRange: Codable, Equatable, Sendable {
    var lowAngle: Double
    var lowLevel: Double
    var highAngle: Double
    var highLevel: Double

    static let keyboardDefault = DimRange(lowAngle: 68, lowLevel: 0, highAngle: 100, highLevel: 1)
    static let screenDefault = DimRange(lowAngle: 68, lowLevel: 0, highAngle: 100, highLevel: 1)

    // For the blur lane the level is blur strength: full at the low end, gone at the high end.
    static let blurDefault = DimRange(lowAngle: 68, lowLevel: 1, highAngle: 100, highLevel: 0)

    func clamped(maximum: Double) -> DimRange {
        settingLow(angle: lowAngle, level: lowLevel, maximum: maximum)
            .settingHigh(angle: highAngle, level: highLevel, maximum: maximum)
    }

    func movedBelow(_ angle: Double) -> DimRange {
        var result = self
        if angle < 2 {
            result.lowAngle = 0
            result.highAngle = 2
        } else {
            result.highAngle = angle
            result.lowAngle = max(0, angle - (highAngle - lowAngle))
        }
        return result
    }

    func level(at angle: Double) -> Double {
        if angle <= lowAngle { return lowLevel }
        if angle >= highAngle { return highLevel }
        return lowLevel + (highLevel - lowLevel) * (angle - lowAngle) / (highAngle - lowAngle)
    }

    func settingLow(angle: Double, level: Double, maximum: Double) -> DimRange {
        var result = self
        result.lowAngle = min(max(angle, 0), maximum)
        result.lowLevel = min(max(level, 0), 1)
        if highAngle - result.lowAngle < 1 {
            result.highAngle = result.lowAngle + 1 <= maximum ? result.lowAngle + 1 : maximum
            result.lowAngle = min(result.lowAngle, result.highAngle - 1)
        }
        return result
    }

    func settingHigh(angle: Double, level: Double, maximum: Double) -> DimRange {
        var result = self
        result.highAngle = min(max(angle, 0), maximum)
        result.highLevel = min(max(level, 0), 1)
        if result.highAngle - lowAngle < 1 {
            result.lowAngle = result.highAngle - 1 >= 0 ? result.highAngle - 1 : 0
            result.highAngle = max(result.highAngle, result.lowAngle + 1)
        }
        return result
    }

    // 1.0 saved each of offAt/fullAt only when its own slider moved, so either one means the user
    // tuned the range; the other end takes 1.0's default (30° and 85°).
    static func migrated(offAt: Double?, fullAt: Double?) -> DimRange? {
        guard offAt != nil || fullAt != nil else { return nil }
        let offAt = offAt ?? 30
        let fullAt = fullAt ?? 85
        let low = min(max(offAt, 0), LidAxis.maximum - 1)
        let high = min(max(fullAt, low + 1), LidAxis.maximum)
        return DimRange(lowAngle: low, lowLevel: 0, highAngle: high, highLevel: 1)
    }
}

struct BrightnessAngleFilter {
    private var range: DimRange?
    private var smoothed: Double?
    private var endpoint: Double?

    mutating func controlAngle(raw: Double, range: DimRange) -> Double {
        if self.range != range {
            self.range = range
            smoothed = nil
            endpoint = nil
        }
        // Two degrees reject the sensor's one-degree endpoint wobble; narrow ranges keep an interior.
        let hysteresis = min(2, (range.highAngle - range.lowAngle) / 2)
        if endpoint == range.highAngle, raw > range.highAngle - hysteresis {
            return range.highAngle
        }
        if endpoint == range.lowAngle, raw < range.lowAngle + hysteresis {
            return range.lowAngle
        }
        let leavingEndpoint = endpoint != nil
        endpoint = nil
        if raw >= range.highAngle { endpoint = range.highAngle }
        if raw <= range.lowAngle { endpoint = range.lowAngle }
        if let endpoint {
            smoothed = endpoint
            return endpoint
        }
        let angle = leavingEndpoint ? raw : smoothed.map { $0 * 0.65 + raw * 0.35 } ?? raw
        smoothed = angle
        return angle
    }
}

struct KeyboardTargetLatency {
    private(set) var pendingAt: TimeInterval?
    private(set) var appliedTarget: Double?
    private(set) var readback: Double?

    mutating func observe(target: Double, readback: Double, time: TimeInterval, active: Bool) {
        self.readback = readback
        guard active, abs(target - readback) > 0.008 else {
            pendingAt = nil
            return
        }
        if pendingAt == nil {
            pendingAt = time
        }
    }

    mutating func didWrite(target: Double, readback: Double, time: TimeInterval) -> Double? {
        let elapsed = pendingAt.map { (time - $0) * 1000 }
        appliedTarget = target
        self.readback = readback
        pendingAt = nil
        return elapsed
    }

    mutating func suspend() { pendingAt = nil }
}

enum LidAxis {
    static let maximum: Double = 130
}
