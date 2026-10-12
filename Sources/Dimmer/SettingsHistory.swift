import AppKit
import Foundation

// Everything Cmd+Z can undo in Settings. A further range or section joins by gaining a field here, a line
// in `current`, and a line in `restore(_:over:)`; the history, gestures and restore actions need no change.
struct SettingsValues: Equatable {
    var keyboardRange: DimRange
    var screenRange: DimRange
    var snap: SnapSettings
    var privacyVeilBlurStrength: Double
    var angleBlurRange: DimRange
    var angleBlurSmoke: Double
    var privacyVeilSmoke: Double
    var privacyVeilEnabled: Bool
}

@MainActor
final class SettingsHistory: ObservableObject {
    let undoManager: UndoManager
    private let controller: DimmerController
    private let features: DimmerFeatures
    private let isMouseDown: () -> Bool
    private let now: () -> Date
    private var gesture: (name: String.LocalizationValue, before: SettingsValues)?

    // A held arrow key is a stream of changes; it is one step while each lands within `burstGap` of the last.
    // The step stays open to growth only while it is the newest one and nothing has been undone since.
    private static let burstGap: TimeInterval = 1
    private final class Step {
        let before: SettingsValues
        var after: SettingsValues
        init(before: SettingsValues, after: SettingsValues) { self.before = before; self.after = after }
    }
    private var burst: (step: Step, control: String, at: Date)?

    init(controller: DimmerController, features: DimmerFeatures,
         isMouseDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons != 0 },
         now: @escaping () -> Date = Date.init) {
        self.controller = controller
        self.features = features
        self.isMouseDown = isMouseDown
        self.now = now
        let manager = UndoManager()
        // Steps are registered explicitly; run-loop grouping would merge two quick edits into one.
        manager.groupsByEvent = false
        manager.levelsOfUndo = 50
        undoManager = manager
    }

    private var current: SettingsValues {
        SettingsValues(keyboardRange: controller.keyboardRange, screenRange: controller.screenRange, snap: features.snap,
                       privacyVeilBlurStrength: features.privacyVeilBlurStrength,
                       angleBlurRange: features.angleBlurRange, angleBlurSmoke: features.angleBlurSmoke,
                       privacyVeilSmoke: features.privacyVeilSmoke, privacyVeilEnabled: features.privacyVeilEnabled)
    }

    private func restore(_ target: SettingsValues, over base: SettingsValues) {
        if target.keyboardRange != base.keyboardRange { controller.keyboardRange = target.keyboardRange }
        if target.screenRange != base.screenRange { controller.screenRange = target.screenRange }
        // Snap and Privacy veil share storage, so undo must restore only the fields the step changed.
        var snap = features.snap
        let fields: [WritableKeyPath<SnapSettings, Double>] = [\.zoneLow, \.zoneHigh, \.snapDegrees, \.minimumSpeed,
                                                               \.blurStrength, \.smoke, \.clearSeconds]
        for field in fields where target.snap[keyPath: field] != base.snap[keyPath: field] {
            snap[keyPath: field] = target.snap[keyPath: field]
        }
        if snap != features.snap { features.snap = snap }
        if target.privacyVeilBlurStrength != base.privacyVeilBlurStrength {
            features.privacyVeilBlurStrength = target.privacyVeilBlurStrength
        }
        if target.angleBlurRange != base.angleBlurRange { features.angleBlurRange = target.angleBlurRange }
        if target.angleBlurSmoke != base.angleBlurSmoke { features.angleBlurSmoke = target.angleBlurSmoke }
        if target.privacyVeilSmoke != base.privacyVeilSmoke { features.privacyVeilSmoke = target.privacyVeilSmoke }
        if target.privacyVeilEnabled != base.privacyVeilEnabled { features.privacyVeilEnabled = target.privacyVeilEnabled }
    }

    // Inside a gesture the writes only apply; the gesture registers the one step when it ends.
    // `coalescing` names the control a key repeat is editing: a run of changes to the same control is folded
    // into the step the first one registered.
    func change(_ name: String.LocalizationValue, coalescing control: String? = nil, _ apply: () -> Void) {
        settleStaleGesture()
        guard gesture == nil else { return apply() }
        let stamp = now()
        if let control, let open = burst, open.control == control, stamp.timeIntervalSince(open.at) < Self.burstGap, !undoManager.canRedo {
            apply()
            open.step.after = current
            burst = (open.step, control, stamp)
            return
        }
        burst = nil
        let before = current
        apply()
        let step = register(name, from: before)
        if let control, let step { burst = (step, control, stamp) }
    }

    func beginGesture(_ name: String.LocalizationValue) {
        settleStaleGesture()
        guard gesture == nil else { return }
        burst = nil
        gesture = (name, current)
    }

    // SwiftUI does not always report the end of a gesture (a cancelled drag, a slider moved with the
    // keys), and a gesture left open would swallow every later change. With no mouse button down it is over.
    private func settleStaleGesture() {
        if gesture != nil && !isMouseDown() { endGesture() }
    }

    func endGesture() {
        guard let open = gesture else { return }
        gesture = nil
        register(open.name, from: open.before)
    }

    // A window closed mid-drag still keeps what the drag changed, as one step.
    func cancelGesture() { endGesture() }

    @discardableResult
    private func register(_ name: String.LocalizationValue, from before: SettingsValues) -> Step? {
        let after = current
        guard before != after else { return nil }
        let step = Step(before: before, after: after)
        undoManager.beginUndoGrouping()
        undoManager.setActionName(L10n.string(name))
        registerUndo(step)
        undoManager.endUndoGrouping()
        return step
    }

    // The undo handler registers its own inverse, which is what makes redo work. It reads the step when it
    // runs, so a step grown by a key repeat undoes the whole run.
    private func registerUndo(_ step: Step) {
        undoManager.registerUndo(withTarget: self) { history in
            history.restore(step.before, over: step.after)
            history.registerUndo(Step(before: step.after, after: step.before))
        }
    }

    var canUndo: Bool { settleStaleGesture(); return gesture == nil && undoManager.canUndo }
    var canRedo: Bool { settleStaleGesture(); return gesture == nil && undoManager.canRedo }

    func undo() { if canUndo { burst = nil; undoManager.undo() } }
    func redo() { if canRedo { burst = nil; undoManager.redo() } }

    // One privacy slider or number being nudged from the keyboard is one step per control, like the axis handles.
    func setSnap(_ keyPath: WritableKeyPath<SnapSettings, Double>, _ value: Double, coalescing control: String? = nil) {
        let name: String.LocalizationValue = keyPath == \.smoke ? "Snap tint" :
            keyPath == \.blurStrength ? "Snap blur strength" : "Privacy settings"
        change(name, coalescing: control ?? "snap.\(keyPath)") {
            var settings = features.snap
            settings[keyPath: keyPath] = value
            features.snap = settings.clamped(maximum: LidAxis.maximum)
        }
    }

    func setPrivacyVeilBlurStrength(_ value: Double) {
        change("Privacy veil blur strength", coalescing: "privacyVeilBlurStrength") {
            features.privacyVeilBlurStrength = value
        }
    }

    func setAngleBlurSmoke(_ value: Double) {
        change("Blur tint", coalescing: "angleBlurSmoke") { features.angleBlurSmoke = value }
    }

    func setPrivacyVeilSmoke(_ value: Double) {
        change("Privacy veil tint", coalescing: "privacyVeilSmoke") { features.privacyVeilSmoke = value }
    }

    func apply(_ look: VeilLook, to target: VeilLookTarget) {
        change("Apply veil look") {
            switch target {
            case .snap:
                var snap = features.snap
                snap.blurStrength = look.strength
                snap.smoke = look.tint
                features.snap = snap
            case .angle:
                features.angleBlurSmoke = look.tint
            case .privacy:
                features.privacyVeilBlurStrength = look.strength
                features.privacyVeilSmoke = look.tint
            }
        }
    }

    func setPrivacyVeilEnabled(_ enabled: Bool) {
        change("Privacy veil") { features.privacyVeilEnabled = enabled }
    }

    func restoreKeyboardRange() { change("Restore defaults") { controller.keyboardRange = .keyboardDefault } }
    func restoreScreenRange() { change("Restore defaults") { controller.screenRange = .screenDefault } }
    func restoreBlurRange() {
        change("Restore defaults") {
            features.angleBlurRange = .blurDefault
            features.angleBlurSmoke = VeilTintSettings.defaultValue
        }
    }

    // Only the values: whether snap is switched on is not part of the snap settings.
    func restoreSnapSettings() { change("Restore defaults") { features.snap = features.snap.restoringSnapDefaults() } }
    func restorePrivacyVeilSettings() {
        change("Restore defaults") {
            features.snap = features.snap.restoringPrivacyVeilDefaults()
            features.privacyVeilBlurStrength = 1
            features.privacyVeilSmoke = VeilTintSettings.defaultValue
        }
    }
}
