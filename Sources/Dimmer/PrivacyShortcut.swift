import KeyboardShortcuts
import Foundation

extension Notification.Name {
    static let dimmerPrivacyShortcutDidChange = Self("dimmerPrivacyShortcutDidChange")
}

extension KeyboardShortcuts.Name {
    // No standard macOS assignment uses Ctrl+Cmd+P (docs/research/shortcut-research.md). KeyboardShortcuts
    // stores a cleared shortcut as false once a name has an initial one, so clearing it sticks.
    static let privacyBlur = Self("privacyBlur", initial: .init(.p, modifiers: [.control, .command]))
}

struct PrivacyShortcutTrigger {
    private var pressed = false

    mutating func receive(isKeyDown: Bool, allowed: Bool) -> Bool {
        guard allowed else { cancel(); return false }
        if isKeyDown { pressed = true; return false }
        defer { pressed = false }
        return pressed
    }

    mutating func cancel() { pressed = false }
}

struct ManualPrivacyLift {
    private var lowestAngle: Double?

    init(angle: Double?) { lowestAngle = angle }

    mutating func shouldClear(at angle: Double) -> Bool {
        let lowest = min(lowestAngle ?? angle, angle)
        lowestAngle = lowest
        return angle - lowest >= SnapDetector.clearRise
    }
}
