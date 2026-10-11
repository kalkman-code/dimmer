import AppKit
import KeyboardShortcuts
import XCTest
@testable import Dimmer

@MainActor
final class SettingsHistoryTests: XCTestCase {
    // Tests that hold a gesture open say the mouse is down; a real gesture only lives while it is.
    private func make(mouseDown: Bool = true, now: @escaping () -> Date = Date.init) throws -> (DimmerController, DimmerFeatures, SettingsHistory, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsHistoryTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        return (controller, features, SettingsHistory(controller: controller, features: features, isMouseDown: { mouseDown }, now: now), defaults)
    }

    private func nudge(_ controller: DimmerController, _ history: SettingsHistory) {
        history.change("Brightness range", coalescing: "keyboardHigh") {
            controller.keyboardRange = controller.keyboardRange.settingHigh(angle: controller.keyboardRange.highAngle - 1, level: 1, maximum: LidAxis.maximum)
        }
    }

    func testAHeldKeyIsOneStepAndRedoReplaysTheWholeRun() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let (controller, _, history, _) = try make(now: { clock })
        for _ in 0..<12 { nudge(controller, history); clock += 0.03 }
        XCTAssertEqual(controller.keyboardRange.highAngle, 88)
        history.undo()
        XCTAssertEqual(controller.keyboardRange, .keyboardDefault)
        XCTAssertFalse(history.canUndo)
        history.redo()
        XCTAssertEqual(controller.keyboardRange.highAngle, 88)
        history.undo()
        XCTAssertEqual(controller.keyboardRange, .keyboardDefault)
    }

    func testHeldKeysOnTwoControlsAreTwoSteps() throws {
        let (controller, _, history, _) = try make()
        nudge(controller, history); nudge(controller, history)
        history.change("Brightness range", coalescing: "screenHigh") {
            controller.screenRange = controller.screenRange.settingHigh(angle: 90, level: 1, maximum: LidAxis.maximum)
        }
        history.undo()
        XCTAssertEqual(controller.screenRange, .screenDefault)
        XCTAssertEqual(controller.keyboardRange.highAngle, 98)
    }

    func testAHeldKeyOnAPrivacySliderIsOneStep() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let (_, features, history, _) = try make(now: { clock })
        let start = features.snap.blurStrength
        for step in 1...8 { history.setSnap(\.blurStrength, start - Double(step) * 0.05); clock += 0.03 }
        XCTAssertEqual(features.snap.blurStrength, start - 0.4, accuracy: 0.0001)
        history.setSnap(\.smoke, 0.5)
        history.undo()
        XCTAssertEqual(features.snap.smoke, SnapSettings().smoke, accuracy: 0.0001)
        history.undo()
        XCTAssertEqual(features.snap.blurStrength, start, accuracy: 0.0001)
        XCTAssertFalse(history.canUndo)
    }

    func testAPauseBetweenKeyPressesStartsANewStep() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let (controller, _, history, _) = try make(now: { clock })
        nudge(controller, history); nudge(controller, history)
        clock += 2
        nudge(controller, history); nudge(controller, history)
        history.undo()
        XCTAssertEqual(controller.keyboardRange.highAngle, 98)
        history.undo()
        XCTAssertEqual(controller.keyboardRange, .keyboardDefault)
    }

    func testAnUndoOrAnotherChangeEndsTheRun() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let (controller, _, history, _) = try make(now: { clock })
        nudge(controller, history); nudge(controller, history)
        history.undo()
        nudge(controller, history); nudge(controller, history)
        XCTAssertEqual(controller.keyboardRange.highAngle, 98)
        history.change("Brightness range") { controller.screenRange = controller.screenRange.settingHigh(angle: 90, level: 1, maximum: LidAxis.maximum) }
        nudge(controller, history)
        clock += 0.1
        nudge(controller, history)
        history.undo()
        XCTAssertEqual(controller.keyboardRange.highAngle, 98)
        XCTAssertEqual(controller.screenRange.highAngle, 90)
        history.undo()
        XCTAssertEqual(controller.screenRange, .screenDefault)
        XCTAssertEqual(controller.keyboardRange.highAngle, 98)
    }

    func testOneChangeIsOneStepAndRedoReplaysIt() throws {
        let (controller, _, history, _) = try make()
        XCTAssertFalse(history.canUndo)
        history.change("Brightness range") { controller.keyboardRange = controller.keyboardRange.settingHigh(angle: 90, level: 1, maximum: LidAxis.maximum) }
        XCTAssertEqual(controller.keyboardRange.highAngle, 90)
        history.undo()
        XCTAssertEqual(controller.keyboardRange, .keyboardDefault)
        XCTAssertTrue(history.canRedo)
        history.redo()
        XCTAssertEqual(controller.keyboardRange.highAngle, 90)
    }

    func testTwoQuickChangesAreTwoSteps() throws {
        let (controller, _, history, _) = try make()
        history.change("Brightness range") { controller.keyboardRange = controller.keyboardRange.settingHigh(angle: 95, level: 1, maximum: LidAxis.maximum) }
        history.change("Brightness range") { controller.keyboardRange = controller.keyboardRange.settingHigh(angle: 90, level: 1, maximum: LidAxis.maximum) }
        history.undo()
        XCTAssertEqual(controller.keyboardRange.highAngle, 95)
        history.undo()
        XCTAssertEqual(controller.keyboardRange.highAngle, 100)
    }

    func testAGestureOfManyWritesIsOneStep() throws {
        let (controller, features, history, _) = try make()
        history.beginGesture("Privacy settings")
        for blur in stride(from: 1.0, through: 0.2, by: -0.1) { history.change("Privacy settings") { features.snap.blurStrength = blur } }
        XCTAssertFalse(history.canUndo, "an open gesture has registered nothing yet")
        history.endGesture()
        history.undo()
        XCTAssertEqual(features.snap.blurStrength, 1)
        XCTAssertFalse(history.canUndo)
        history.redo()
        XCTAssertEqual(features.snap.blurStrength, 0.3, accuracy: 0.0001)
        XCTAssertEqual(controller.keyboardRange, .keyboardDefault)
    }

    func testUndoAndRedoAreIgnoredWhileAGestureIsOpen() throws {
        let (controller, _, history, _) = try make()
        history.change("Brightness range") { controller.keyboardRange = controller.keyboardRange.settingHigh(angle: 95, level: 1, maximum: LidAxis.maximum) }
        history.beginGesture("Brightness range")
        controller.keyboardRange = controller.keyboardRange.settingHigh(angle: 90, level: 1, maximum: LidAxis.maximum)
        XCTAssertFalse(history.canUndo)
        history.undo()
        XCTAssertEqual(controller.keyboardRange.highAngle, 90)
        history.endGesture()
        history.undo()
        XCTAssertEqual(controller.keyboardRange.highAngle, 95)
        history.undo()
        XCTAssertEqual(controller.keyboardRange.highAngle, 100)
    }

    func testAGestureThatChangesNothingRegistersNothing() throws {
        let (_, _, history, _) = try make()
        history.beginGesture("Brightness range")
        history.endGesture()
        history.endGesture()
        XCTAssertFalse(history.canUndo)
    }

    func testAWindowClosedMidGestureKeepsOneStep() throws {
        let (controller, _, history, _) = try make()
        history.beginGesture("Brightness range")
        controller.screenRange = controller.screenRange.settingHigh(angle: 80, level: 1, maximum: LidAxis.maximum)
        history.cancelGesture()
        XCTAssertTrue(history.canUndo)
        history.undo()
        XCTAssertEqual(controller.screenRange, .screenDefault)
    }

    func testUndoRestoresBothEndpointsWhenClampingMovedTheOther() throws {
        let (controller, _, history, defaults) = try make()
        let before = controller.keyboardRange
        history.change("Brightness range") {
            controller.keyboardRange = controller.keyboardRange.settingHigh(angle: 40, level: 0.6, maximum: LidAxis.maximum)
        }
        XCTAssertLessThan(controller.keyboardRange.lowAngle, before.lowAngle, "dragging the high end under the low end must have pushed the low end down")
        history.undo()
        XCTAssertEqual(controller.keyboardRange, before)
        let stored = try JSONDecoder().decode(DimRange.self, from: try XCTUnwrap(defaults.data(forKey: "keyboardRange")))
        XCTAssertEqual(stored, before, "the restored value is persisted")
        history.redo()
        XCTAssertEqual(controller.keyboardRange.highAngle, 40)
    }

    func testAStepRestoresOnlyTheSectionsItChanged() throws {
        let (controller, features, history, _) = try make()
        history.change("Privacy settings") { features.snap.zoneHigh = 90 }
        controller.screenRange = controller.screenRange.settingHigh(angle: 85, level: 1, maximum: LidAxis.maximum)
        history.undo()
        XCTAssertEqual(features.snap.zoneHigh, 99)
        XCTAssertEqual(controller.screenRange.highAngle, 85, "a change made outside the history is not rolled back")
    }

    func testRestoreEachSectionTouchesOnlyThatSection() throws {
        let (controller, features, history, _) = try make()
        let shortcut = KeyboardShortcuts.getShortcut(for: .privacyBlur)
        controller.keyboardRange = DimRange(lowAngle: 50, lowLevel: 0.1, highAngle: 90, highLevel: 0.9)
        controller.screenRange = DimRange(lowAngle: 40, lowLevel: 0.2, highAngle: 80, highLevel: 0.8)
        features.snap.zoneHigh = 90
        features.snap.blurStrength = 0.4
        controller.dimsKeyboard = false
        controller.dimsScreen = false
        features.privacyEnabled = true
        features.setAwakeDuration(.oneHour)
        defer { features.setAwakeDuration(.off) }

        history.restoreKeyboardRange()
        XCTAssertEqual(controller.keyboardRange, .keyboardDefault)
        XCTAssertEqual(controller.screenRange.lowAngle, 40)
        XCTAssertEqual(features.snap.zoneHigh, 90)

        history.restoreScreenRange()
        XCTAssertEqual(controller.screenRange, .screenDefault)
        XCTAssertEqual(features.snap.blurStrength, 0.4)

        history.restoreSnapSettings()
        XCTAssertEqual(features.snap, SnapSettings(blurStrength: 0.4))
        history.restorePrivacyVeilSettings()
        XCTAssertEqual(features.snap, SnapSettings())

        XCTAssertFalse(controller.dimsKeyboard)
        XCTAssertFalse(controller.dimsScreen)
        XCTAssertTrue(features.privacyEnabled, "restoring snap values leaves snap on when it was on")
        XCTAssertEqual(features.awakeDuration, .oneHour)
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .privacyBlur), shortcut)
    }

    func testBlurRangeJoinsUndoAndItsOwnRestore() throws {
        let (controller, features, history, _) = try make()
        let custom = DimRange(lowAngle: 40, lowLevel: 0.6, highAngle: 90, highLevel: 0.1)
        history.change("Blur range") { features.angleBlurRange = custom }
        XCTAssertEqual(history.undoManager.undoActionName, L10n.string("Blur range"))
        history.undo()
        XCTAssertEqual(features.angleBlurRange, .blurDefault)
        history.redo()
        XCTAssertEqual(features.angleBlurRange, custom)

        controller.keyboardRange = DimRange(lowAngle: 50, lowLevel: 0.1, highAngle: 90, highLevel: 0.9)
        history.restoreBlurRange()
        XCTAssertEqual(features.angleBlurRange, .blurDefault)
        XCTAssertEqual(controller.keyboardRange.lowAngle, 50, "restoring blur touches nothing else")
        history.undo()
        XCTAssertEqual(features.angleBlurRange, custom)
        history.undo()
        XCTAssertEqual(features.angleBlurRange, .blurDefault, "undoing the first edit returns to the default")
    }

    func testEveryBoxRestoreLeavesOtherBoxesAndShortcutUntouched() throws {
        let originalSnap = SnapSettings(zoneLow: 40, zoneHigh: 90, snapDegrees: 12, minimumSpeed: 120,
                                        blurStrength: 0.4, smoke: 0.6, clearSeconds: 0.3)
        let keyboard = DimRange(lowAngle: 30, lowLevel: 0.2, highAngle: 80, highLevel: 0.8)
        let screen = DimRange(lowAngle: 35, lowLevel: 0.1, highAngle: 95, highLevel: 0.7)
        let blur = DimRange(lowAngle: 45, lowLevel: 0.7, highAngle: 105, highLevel: 0.1)
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .privacyBlur)
        let shortcut = KeyboardShortcuts.Shortcut(.p, modifiers: [.control, .command])
        KeyboardShortcuts.setShortcut(shortcut, for: .privacyBlur)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .privacyBlur) }
        for box in ["keyboard", "screen", "snap", "privacy", "blur"] {
            let (controller, features, history, _) = try make()
            defer { features.stop() }
            controller.keyboardRange = keyboard
            controller.screenRange = screen
            controller.dimsKeyboard = false
            controller.dimsScreen = false
            features.privacyEnabled = false
            features.angleBlurEnabled = true
            features.snap = originalSnap
            features.angleBlurRange = blur
            features.angleBlurSmoke = 0.8
            var wantedSnap = originalSnap
            switch box {
            case "keyboard": history.restoreKeyboardRange()
            case "screen": history.restoreScreenRange()
            case "snap":
                history.restoreSnapSettings()
                wantedSnap = SnapSettings(blurStrength: 0.4, clearSeconds: 0.3)
            case "privacy":
                history.restorePrivacyVeilSettings()
                wantedSnap.blurStrength = 1
                wantedSnap.clearSeconds = 0.08
            default: history.restoreBlurRange()
            }
            XCTAssertEqual(controller.keyboardRange, box == "keyboard" ? .keyboardDefault : keyboard, box)
            XCTAssertEqual(controller.screenRange, box == "screen" ? .screenDefault : screen, box)
            XCTAssertEqual(features.snap, wantedSnap, box)
            XCTAssertEqual(features.angleBlurRange, box == "blur" ? .blurDefault : blur, box)
            XCTAssertEqual(features.angleBlurSmoke, box == "blur" ? 0 : 0.8, box)
            XCTAssertFalse(controller.dimsKeyboard, box)
            XCTAssertFalse(controller.dimsScreen, box)
            XCTAssertFalse(features.privacyEnabled, box)
            XCTAssertTrue(features.angleBlurEnabled, box)
            XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .privacyBlur), shortcut, box)
            history.undo()
            XCTAssertEqual(controller.keyboardRange, keyboard, box)
            XCTAssertEqual(controller.screenRange, screen, box)
            XCTAssertEqual(features.snap, originalSnap, box)
            XCTAssertEqual(features.angleBlurRange, blur, box)
            XCTAssertEqual(features.angleBlurSmoke, 0.8, box)
            XCTAssertFalse(history.canUndo, box)
            history.redo()
            XCTAssertEqual(features.snap, wantedSnap, box)
        }
    }

    func testUndoingSnapRestorePreservesALaterPrivacyVeilChange() throws {
        let (_, features, history, _) = try make()
        defer { features.stop() }
        features.snap.smoke = 0.6
        history.restoreSnapSettings()
        features.snap.blurStrength = 0.4
        features.snap.clearSeconds = 0.3
        history.undo()
        XCTAssertEqual(features.snap.smoke, 0.6)
        XCTAssertEqual(features.snap.blurStrength, 0.4)
        XCTAssertEqual(features.snap.clearSeconds, 0.3)
    }

    func testAngleTintNudgesCoalesceAndRestoreDoesNotTouchSnapTint() throws {
        let (controller, features, history, _) = try make()
        features.snap.smoke = 0.3
        for value in [0.2, 0.4, 0.6] { history.setAngleBlurSmoke(value) }
        history.undo()
        XCTAssertEqual(features.angleBlurSmoke, 0)
        XCTAssertFalse(history.canUndo)
        history.redo()
        XCTAssertEqual(features.angleBlurSmoke, 0.6)

        controller.keyboardRange = DimRange(lowAngle: 50, lowLevel: 0.1, highAngle: 90, highLevel: 0.9)
        history.restoreBlurRange()
        XCTAssertEqual(features.angleBlurSmoke, 0)
        XCTAssertEqual(features.snap.smoke, 0.3)
        XCTAssertEqual(controller.keyboardRange.lowAngle, 50)
        history.undo()
        XCTAssertEqual(features.angleBlurSmoke, 0.6)
    }

    func testRestoringWhatIsAlreadyDefaultBlurRegistersNothing() throws {
        let (_, _, history, _) = try make()
        history.restoreBlurRange()
        XCTAssertFalse(history.canUndo)
    }

    func testRestoringSnapValuesNeverSwitchesSnapOn() throws {
        let (_, features, history, _) = try make()
        features.privacyEnabled = false
        features.snap.snapDegrees = 12
        history.restoreSnapSettings()
        XCTAssertEqual(features.snap, SnapSettings())
        XCTAssertFalse(features.privacyEnabled)
        history.undo()
        XCTAssertEqual(features.snap.snapDegrees, 12)
        XCTAssertFalse(features.privacyEnabled)
    }

    func testPrivacyVeilSwitchIsUndoableAndRestoreLeavesItAlone() throws {
        let (_, features, history, _) = try make()
        XCTAssertTrue(features.privacyVeilEnabled)
        history.setPrivacyVeilEnabled(false)
        XCTAssertFalse(features.privacyVeilEnabled)
        features.snap.blurStrength = 0.25
        history.restorePrivacyVeilSettings()
        XCTAssertFalse(features.privacyVeilEnabled)
        XCTAssertEqual(features.snap.blurStrength, 1)

        history.undo()
        XCTAssertFalse(features.privacyVeilEnabled)
        XCTAssertEqual(features.snap.blurStrength, 0.25)
        history.undo()
        XCTAssertTrue(features.privacyVeilEnabled)
        history.redo()
        XCTAssertFalse(features.privacyVeilEnabled)
    }

    func testARestoreIsUndoableAndRedoable() throws {
        let (controller, _, history, _) = try make()
        let custom = DimRange(lowAngle: 50, lowLevel: 0.1, highAngle: 90, highLevel: 0.9)
        controller.screenRange = custom
        history.restoreScreenRange()
        XCTAssertEqual(controller.screenRange, .screenDefault)
        history.undo()
        XCTAssertEqual(controller.screenRange, custom)
        history.redo()
        XCTAssertEqual(controller.screenRange, .screenDefault)
    }

    func testRestoringWhatIsAlreadyDefaultRegistersNothing() throws {
        let (_, _, history, _) = try make()
        history.restoreKeyboardRange()
        history.restoreScreenRange()
        history.restoreSnapSettings()
        XCTAssertFalse(history.canUndo)
    }

    func testAGestureNobodyEndedSettlesOnceTheMouseIsUp() throws {
        let (controller, _, history, _) = try make(mouseDown: false)
        history.beginGesture("Privacy settings")
        controller.screenRange = controller.screenRange.settingHigh(angle: 80, level: 1, maximum: LidAxis.maximum)
        XCTAssertTrue(history.canUndo, "a gesture left open with no button down is closed as one step, not allowed to trap Cmd+Z")
        history.undo()
        XCTAssertEqual(controller.screenRange, .screenDefault)
        history.change("Brightness range") { controller.keyboardRange = controller.keyboardRange.settingHigh(angle: 90, level: 1, maximum: LidAxis.maximum) }
        XCTAssertTrue(history.canUndo)
    }

    func testWindowUndoGoesToTheHistoryExceptWhileANumberIsBeingTyped() throws {
        let (_, _, history, _) = try make()
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
                                    backing: .buffered, defer: true, history: history)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.undoManager === history.undoManager)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue((window.firstResponder as? NSText)?.isFieldEditor == true)
        XCTAssertFalse(window.undoManager === history.undoManager, "typing in a field must not register in the settings history")
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertTrue(window.undoManager === history.undoManager)
    }

    // The Edit menu's Undo reaches the window's undo(_:), whoever is first responder; typing must win.
    func testUndoWhileTypingUndoesTheTypingNotTheLastSettingsChange() throws {
        let (controller, _, history, _) = try make()
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
                                    backing: .buffered, defer: true, history: history)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        window.contentView?.addSubview(field)
        history.change("Brightness range") { controller.keyboardRange = controller.keyboardRange.settingHigh(angle: 95, level: 1, maximum: LidAxis.maximum) }
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("42", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "42")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let item = NSMenuItem(title: "Undo", action: #selector(SettingsWindow.undo(_:)), keyEquivalent: "z")
        XCTAssertTrue(window.validateMenuItem(item))
        window.undo(nil)
        XCTAssertEqual(controller.keyboardRange.highAngle, 95, "typing's undo must not revert the settings")
        XCTAssertEqual(editor.string, "")
        XCTAssertTrue(window.makeFirstResponder(nil))
        window.undo(nil)
        XCTAssertEqual(controller.keyboardRange.highAngle, 100)
    }
}
