import CoreGraphics
import Foundation

enum AwakeDuration: String, CaseIterable, Identifiable {
    case off
    case indefinitely
    case fifteenMinutes
    case oneHour
    case twoHours
    case fiveHours
    case untilTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .indefinitely: "Indefinitely"
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .fiveHours: "5 hours"
        case .untilTime: "Until a time…"
        }
    }
}

enum AwakeSchedule {
    static func deadline(
        for duration: AwakeDuration,
        startedAt: Date,
        untilTime: Date,
        calendar: Calendar = .current
    ) -> Date? {
        return switch duration {
        case .off, .indefinitely:
            nil
        case .fifteenMinutes:
            startedAt.addingTimeInterval(15 * 60)
        case .oneHour:
            startedAt.addingTimeInterval(60 * 60)
        case .twoHours:
            startedAt.addingTimeInterval(2 * 60 * 60)
        case .fiveHours:
            startedAt.addingTimeInterval(5 * 60 * 60)
        case .untilTime:
            nextOccurrence(of: untilTime, after: startedAt, calendar: calendar)
        }
    }

    private static func nextOccurrence(of time: Date, after start: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: start)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: time)
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = 0
        guard let today = calendar.date(from: components) else { return nil }
        if today > start { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }
}

struct LidSample: Equatable, Sendable {
    var angle: Double
    var time: TimeInterval
}

struct SnapSettings: Codable, Equatable, Sendable {
    var zoneLow: Double = 68
    var zoneHigh: Double = 99
    var snapDegrees: Double = 5
    var minimumSpeed: Double = 60
    var blurStrength: Double = 1
    var smoke: Double = 0            // 0 frost … 1 smoke; the tint is `smoke × maximumSmoke` black
    var clearSeconds: Double = 0.08
    static let maximumSmoke = 0.75   // above about 80% black the veil reads as a black screen, not a film

    init(zoneLow: Double = 68, zoneHigh: Double = 99, snapDegrees: Double = 5, minimumSpeed: Double = 60,
         blurStrength: Double = 1, smoke: Double = 0, clearSeconds: Double = 0.08) {
        self.zoneLow = zoneLow
        self.zoneHigh = zoneHigh
        self.snapDegrees = snapDegrees
        self.minimumSpeed = minimumSpeed
        self.blurStrength = blurStrength
        self.smoke = smoke
        self.clearSeconds = clearSeconds
    }

    // Settings saved before a field existed must keep everything else, so every key is optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SnapSettings()
        self.init(zoneLow: try c.decodeIfPresent(Double.self, forKey: .zoneLow) ?? d.zoneLow,
                  zoneHigh: try c.decodeIfPresent(Double.self, forKey: .zoneHigh) ?? d.zoneHigh,
                  snapDegrees: try c.decodeIfPresent(Double.self, forKey: .snapDegrees) ?? d.snapDegrees,
                  minimumSpeed: try c.decodeIfPresent(Double.self, forKey: .minimumSpeed) ?? d.minimumSpeed,
                  blurStrength: try c.decodeIfPresent(Double.self, forKey: .blurStrength) ?? d.blurStrength,
                  smoke: try c.decodeIfPresent(Double.self, forKey: .smoke) ?? d.smoke,
                  clearSeconds: try c.decodeIfPresent(Double.self, forKey: .clearSeconds) ?? d.clearSeconds)
    }

    func clamped(maximum: Double) -> SnapSettings {
        var result = self
        let limit = max(maximum, 2)
        result.zoneLow = min(max(zoneLow, 0), limit - 2)
        result.zoneHigh = min(max(zoneHigh, result.zoneLow + 2), limit)
        result.snapDegrees = min(max(snapDegrees, 1), 40)
        result.minimumSpeed = min(max(minimumSpeed, 10), 300)
        result.blurStrength = min(max(blurStrength, 0), 1)
        result.smoke = min(max(smoke, 0), 1)
        result.clearSeconds = min(max(clearSeconds, 0), 0.6)
        return result
    }
}

// The snap gesture as Toby uses it (08-10-2026): flicks down into the zone, often starting inside it or
// just above it, sometimes slower than a full snap. So the veil is not a switch: any quick downward
// movement in or near the zone fades it in as far as the movement has gone, a full snap locks it, and
// anything short of a snap fades back out.
struct SnapDetector {
    enum Veil: Hashable {
        case none
        case partial(Double)   // 0…1 of the way to a snap, still fading with the movement
        case snapped
    }

    static let window: TimeInterval = 1.5
    static let liftHysteresis: Double = 2
    // Recorded flicks rebound under 2° and the integer sensor wobbles 1°; a real push-back passes 3° in about 30 ms.
    static let clearRise: Double = 3
    static let inputGrace: TimeInterval = 0.4
    // A movement counts as the start of a flick from 3° down at 20 °/s within 0.4 s, which the sensor's
    // 1° typing wobble never reaches; it can start this far above the zone.
    static let onsetDegrees: Double = 3
    static let onsetSpeed: Double = 20
    static let onsetWindow: TimeInterval = 0.4
    static let nearMargin: Double = 8

    private var history: [LidSample] = []
    private(set) var hasFired = false
    private var lowestSinceSnap: Double?
    var lowestAngle: Double? { lowestSinceSnap }

    mutating func observe(_ sample: LidSample, settings: SnapSettings) -> Veil {
        history.removeAll { $0.time < sample.time - Self.window || $0.time >= sample.time }
        defer { history.append(sample) }
        if hasFired { return .snapped }
        let inZone = sample.angle >= settings.zoneLow && sample.angle <= settings.zoneHigh

        // A snap: in the zone now, and some recent sample at least the snap size higher, reached at the
        // snap speed. Taking the fastest qualifying sample measures the flick, not the pause before it.
        let snapSpeed = history.compactMap { earlier -> Double? in
            let elapsed = sample.time - earlier.time
            let drop = earlier.angle - sample.angle
            guard drop >= settings.snapDegrees, elapsed > 0 else { return nil }
            return drop / elapsed
        }.max() ?? 0
        if inZone && snapSpeed >= settings.minimumSpeed {
            hasFired = true
            lowestSinceSnap = sample.angle
            return .snapped
        }

        let near = sample.angle >= settings.zoneLow && sample.angle <= settings.zoneHigh + Self.nearMargin
        guard near else { return .none }
        let recent = history.filter { $0.time >= sample.time - Self.onsetWindow }
        guard let peak = recent.max(by: { $0.angle < $1.angle }) else { return .none }
        let drop = peak.angle - sample.angle
        let elapsed = sample.time - peak.time
        guard drop >= Self.onsetDegrees, elapsed > 0, drop / elapsed >= Self.onsetSpeed else { return .none }
        return .partial(min(0.85, drop / max(settings.snapDegrees, 1) * 0.5))
    }

    func liftedAbove(_ angle: Double, settings: SnapSettings) -> Bool {
        angle >= settings.zoneHigh + Self.liftHysteresis
    }

    mutating func pushedBack(_ angle: Double, settings: SnapSettings) -> Bool {
        if let lowestSinceSnap {
            let lowest = min(lowestSinceSnap, angle)
            self.lowestSinceSnap = lowest
            if angle - lowest >= Self.clearRise { return true }
        }
        return liftedAbove(angle, settings: settings)
    }

    mutating func reset() {
        history.removeAll()
        hasFired = false
        lowestSinceSnap = nil
    }

    static func inputArrived(idleSeconds: Double, now: TimeInterval, blurredAt: TimeInterval,
                             grace: TimeInterval = inputGrace) -> Bool {
        now - idleSeconds > blurredAt + grace
    }
}

// The session's idle counters need neither Accessibility nor Input Monitoring (checked on macOS 27.2);
// NSEvent global key monitors stay silent without Accessibility, so they are not used.
enum InputActivity {
    private static let eventTypes: [(CGEventType, String)] = [
        (.keyDown, "key"), (.mouseMoved, "pointer move"), (.scrollWheel, "scroll"), (.leftMouseDown, "click"),
        (.rightMouseDown, "click"), (.leftMouseDragged, "drag"), (.otherMouseDown, "click"),
    ]

    static func secondsSinceLastInput() -> Double { lastInput().seconds }

    static func lastInput() -> (seconds: Double, kind: String) {
        eventTypes.map { (CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0.0), $0.1) }
            .min { $0.0 < $1.0 }
            .map { (seconds: $0.0, kind: $0.1) } ?? (.infinity, "none")
    }
}

// Go dark: a darkness of 0 leaves the ranges in charge, 1 is backlight off and screen black.
enum GoDark {
    static let fadeOut: TimeInterval = 0.8
    static let fadeIn: TimeInterval = 0.6
    // The click that chose Go dark, and the hand still on the trackpad after it, must not undo it.
    static let inputGrace: TimeInterval = 1.2
    static let lidMove: Double = 3

    static func nextDarkness(_ current: Double, isDark: Bool, elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion { return isDark ? 1 : 0 }
        return isDark ? min(1, current + elapsed / fadeOut) : max(0, current - elapsed / fadeIn)
    }

    static func level(_ level: Double, darkness: Double) -> Double {
        level * (1 - min(max(darkness, 0), 1))
    }

    static func shouldWake(idleSeconds: Double, now: TimeInterval, darkAt: TimeInterval,
                           angle: Double?, startAngle: Double?) -> Bool {
        if SnapDetector.inputArrived(idleSeconds: idleSeconds, now: now, blurredAt: darkAt, grace: inputGrace) {
            return true
        }
        guard let angle, let startAngle else { return false }
        return abs(angle - startAngle) >= lidMove
    }
}

enum VeilTransition {
    static func level(from current: Double, to target: Double, elapsed: TimeInterval,
                      fallingDuration: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion || fallingDuration == 0 { return target }
        let rising = target > current
        let delta = elapsed / (rising ? 0.18 : fallingDuration)
        return rising ? min(target, current + delta) : max(target, current - delta)
    }
}
