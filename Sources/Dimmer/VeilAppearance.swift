import AppKit

enum VeilAppearance {
    static func shouldShow(level: Double, locked: Bool, reduceTransparency: Bool) -> Bool {
        level > 0 && (locked || !reduceTransparency)
    }
    static func opacity(strength: Double, reduceTransparency: Bool) -> Double {
        let clamped = min(max(strength, 0), 1)
        return reduceTransparency && clamped > 0 ? 1 : clamped
    }

    // A shared window takes the stronger blur and darkness, without stacking the two veils. Normalising
    // the tint by the window's strength keeps each veil's darkness scaled by its own blur strength.
    static func combined(snap: Double, smoke: Double, angle: Double, angleSmoke: Double) -> (strength: Double, smoke: Double) {
        let strength = max(snap, angle)
        return (strength, strength > 0 ? max(snap * smoke, angle * angleSmoke) / strength : 0)
    }

    static func opaqueColour(smoke: Double) -> NSColor {
        NSColor(calibratedWhite: 0.95 * (1 - min(max(smoke, 0), 1) * SnapSettings.maximumSmoke), alpha: 1)
    }
}

enum AngleLane {
    // Reduce Transparency removes the angle veil rather than turning a continuous ramp into an opaque
    // sheet; the snap veil keeps its opaque cover because that is a deliberate privacy action.
    static func level(enabled: Bool, held: Bool, reduceTransparency: Bool, angle: Double?, range: DimRange) -> Double {
        guard enabled, !held, !reduceTransparency, let angle else { return 0 }
        return (min(max(range.level(at: angle), 0), 1) * 100).rounded() / 100
    }
}
