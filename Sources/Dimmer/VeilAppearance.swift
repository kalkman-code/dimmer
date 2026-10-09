import AppKit

enum VeilAppearance {
    static func shouldShow(level: Double, locked: Bool, reduceTransparency: Bool) -> Bool {
        level > 0 && (locked || !reduceTransparency)
    }
    static func opacity(strength: Double, reduceTransparency: Bool) -> Double {
        let clamped = min(max(strength, 0), 1)
        return reduceTransparency && clamped > 0 ? 1 : clamped
    }

    static func opaqueColour(smoke: Double) -> NSColor {
        NSColor(calibratedWhite: 0.95 * (1 - min(max(smoke, 0), 1) * SnapSettings.maximumSmoke), alpha: 1)
    }
}
