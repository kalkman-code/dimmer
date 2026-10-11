import AppKit
import XCTest
@testable import Dimmer

@MainActor
final class TintInBoxesTests: XCTestCase {
    func testShortcutKeepsItsOwnTintWhileLidLiftFadesItOut() throws {
        let (features, overlay, _) = try make()
        defer { features.stop() }
        features.snap.smoke = 0.2
        features.privacyVeilSmoke = 0.75
        features.activatePrivacyBlurFromShortcut(at: 100, angle: 84)
        XCTAssertEqual(overlay.smoke, 0.75)
        features.update(sample: LidSample(angle: 90, time: 101))
        XCTAssertFalse(features.privacyBlurActive)
        XCTAssertGreaterThan(overlay.strength, 0, "the veil is still fading")
        XCTAssertEqual(overlay.smoke, 0.75, "clearing must not switch to Snap tint")
    }

    func testShortcutTintUndoRedoAndRestoreAreIndependentAndNamed() throws {
        let (features, _, defaults) = try make()
        defer { features.stop(); L10n.testLanguage = nil }
        let history = SettingsHistory(controller: DimmerController(defaults: defaults), features: features)
        for language in ["en-GB", "es", "pt-BR", "de", "fr", "ja"] {
            L10n.testLanguage = language
            history.setSnap(\.smoke, 0.3)
            XCTAssertEqual(history.undoManager.undoActionName, L10n.string("Snap tint"))
            history.undo()
            for value in [0.2, 0.4, 0.6] { history.setPrivacyVeilSmoke(value) }
            XCTAssertEqual(history.undoManager.undoActionName, L10n.string("Privacy veil tint"))
            history.undo()
            XCTAssertEqual(features.privacyVeilSmoke, 0)
            XCTAssertFalse(history.canUndo)
            history.redo()
            XCTAssertEqual(features.privacyVeilSmoke, 0.6)
            features.snap.smoke = 0.7
            features.snap.blurStrength = 0.4
            features.snap.clearSeconds = 0.3
            history.restorePrivacyVeilSettings()
            XCTAssertEqual(features.privacyVeilSmoke, 0)
            XCTAssertEqual(features.snap.smoke, 0.7)
            XCTAssertEqual(features.snap.blurStrength, 0.4)
            XCTAssertEqual(features.privacyVeilBlurStrength, 1)
            XCTAssertEqual(features.snap.clearSeconds, 0.08)
            history.undo()
            XCTAssertEqual(features.privacyVeilSmoke, 0.6)
            XCTAssertEqual(features.snap.blurStrength, 0.4)
            XCTAssertEqual(features.snap.clearSeconds, 0.3)
            history.undo()
            XCTAssertEqual(features.privacyVeilSmoke, 0)
            XCTAssertEqual(features.snap.smoke, 0.7)
        }
    }

    func testShortcutTintPersistsClampsAndRestoresWithoutTouchingSnapOrAngleTint() throws {
        let (features, _, defaults) = try make()
        defer { features.stop() }
        features.privacyVeilSmoke = 2
        XCTAssertEqual(features.privacyVeilSmoke, 1)
        features.privacyVeilSmoke = -1
        XCTAssertEqual(features.privacyVeilSmoke, 0)
        features.privacyVeilSmoke = .nan
        XCTAssertEqual(features.privacyVeilSmoke, 0)
        features.privacyVeilSmoke = 0.45
        features.snap.smoke = 0.2
        let reloaded = DimmerFeatures(defaults: defaults, overlay: TintRecorder())
        defer { reloaded.stop() }
        XCTAssertEqual(reloaded.privacyVeilSmoke, 0.45)
        XCTAssertEqual(reloaded.snap.smoke, 0.2)
        XCTAssertEqual(reloaded.angleBlurSmoke, 0.8)
        let history = SettingsHistory(controller: DimmerController(defaults: defaults), features: reloaded, isMouseDown: { true })
        history.beginGesture("Privacy veil tint")
        for value in [0.3, 0.5, 0.7] { history.setPrivacyVeilSmoke(value) }
        history.endGesture()
        reloaded.snap.smoke = 0.9
        history.undo()
        XCTAssertEqual(reloaded.privacyVeilSmoke, 0.45)
        XCTAssertEqual(reloaded.snap.smoke, 0.9)
        XCTAssertFalse(history.canUndo)
        history.redo()
        XCTAssertEqual(reloaded.privacyVeilSmoke, 0.7)
    }

    func testShortcutTintMigratesOnceFromSavedSnapTintBeforeEitherIsEdited() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(try JSONEncoder().encode(SnapSettings(smoke: 0.65)), forKey: "snapSettings")
        let features = DimmerFeatures(defaults: defaults, overlay: TintRecorder())
        defer { features.stop() }
        XCTAssertEqual(defaults.object(forKey: "privacyVeilSmoke") as? Double, 0.65,
                       "first run stores the old shortcut look before Snap tint can change")
        features.snap.smoke = 0.2
        let overlay = TintRecorder()
        let reloaded = DimmerFeatures(defaults: defaults, overlay: overlay)
        defer { reloaded.stop() }
        reloaded.activatePrivacyBlurFromShortcut(at: 100, angle: 84)
        XCTAssertEqual(overlay.smoke, 0.65, accuracy: 1e-9, "shortcut uses its migrated tint, not later Snap tint")
        XCTAssertEqual(reloaded.snap.smoke, 0.2)
    }

    private func make(smoke: Double = 0.8, legacy: Any? = nil) throws -> (DimmerFeatures, TintRecorder, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(smoke, forKey: "angleBlurSmoke")
        if let legacy {
            defaults.set(true, forKey: "angleTintEnabled")
            defaults.set(legacy, forKey: "angleTintRange")
        }
        let overlay = TintRecorder()
        return (DimmerFeatures(defaults: defaults, overlay: overlay), overlay, defaults)
    }

    func testStoredTintLaneIsIgnoredIncludingMalformedValues() throws {
        let range = try JSONEncoder().encode(DimRange(lowAngle: 0, lowLevel: 1, highAngle: 130, highLevel: 1))
        for legacy: Any in [range, "malformed", 42] {
            let (features, overlay, _) = try make(legacy: legacy)
            defer { features.stop() }
            features.setLidAngle(60)
            XCTAssertFalse(overlay.visible)
            features.angleBlurEnabled = true
            XCTAssertEqual(overlay.smoke, 0.8, accuracy: 1e-9, "legacy darkness must not override the new tint")
        }
    }

    func testAngleTintScalesWithItsBlurAndLeavesSnapTintIndependent() throws {
        let (features, overlay, _) = try make()
        defer { features.stop() }
        features.angleBlurEnabled = true
        features.snap.smoke = 0.2
        features.setLidAngle(84)
        XCTAssertEqual(overlay.strength, 0.5)
        XCTAssertEqual(overlay.strength * overlay.smoke, 0.4, accuracy: 1e-9)
        features.activatePrivacyBlurFromShortcut(at: 100, angle: 84)
        XCTAssertEqual(overlay.strength, 1)
        XCTAssertEqual(overlay.smoke, 0.4, accuracy: 1e-9, "the stronger darkness wins without stacking")
        XCTAssertEqual(features.snap.smoke, 0.2)
    }

    func testBlurRestoreRestoresTintAsOneUndoableStep() throws {
        let (features, overlay, defaults) = try make()
        defer { features.stop() }
        features.angleBlurEnabled = true
        features.angleBlurRange = DimRange(lowAngle: 30, lowLevel: 1, highAngle: 90, highLevel: 0)
        features.setLidAngle(30)
        let history = SettingsHistory(controller: DimmerController(defaults: defaults), features: features)
        history.restoreBlurRange()
        XCTAssertEqual(overlay.smoke, 0, "restore covers the whole blur box")
        XCTAssertTrue(features.angleBlurEnabled)
        history.undo()
        XCTAssertEqual(overlay.smoke, 0.8)
        XCTAssertEqual(features.angleBlurRange.highAngle, 90)
        history.redo()
        XCTAssertEqual(overlay.smoke, 0)
    }

    func testSnapTintNudgesCoalesceAndRestoreIncludesTint() throws {
        let (features, _, defaults) = try make()
        defer { features.stop() }
        let history = SettingsHistory(controller: DimmerController(defaults: defaults), features: features)
        for value in [0.2, 0.4, 0.6] { history.setSnap(\.smoke, value) }
        history.undo()
        XCTAssertEqual(features.snap.smoke, 0)
        XCTAssertFalse(history.canUndo)
        history.redo()
        XCTAssertEqual(features.snap.smoke, 0.6)
        history.restoreSnapSettings()
        XCTAssertEqual(features.snap.smoke, 0)
        history.undo()
        XCTAssertEqual(features.snap.smoke, 0.6)
    }

    func testBothTintsPersistIndependentlyAndAngleTintClamps() throws {
        let (features, _, defaults) = try make(smoke: 2)
        defer { features.stop() }
        XCTAssertEqual(features.angleBlurSmoke, 1)
        features.angleBlurSmoke = 0.7
        features.snap.smoke = 0.25
        let reloaded = DimmerFeatures(defaults: defaults, overlay: TintRecorder())
        defer { reloaded.stop() }
        XCTAssertEqual(reloaded.angleBlurSmoke, 0.7)
        XCTAssertEqual(reloaded.snap.smoke, 0.25)
        defaults.set("malformed", forKey: "angleBlurSmoke")
        let malformed = DimmerFeatures(defaults: defaults, overlay: TintRecorder())
        defer { malformed.stop() }
        XCTAssertEqual(malformed.angleBlurSmoke, 0)
    }

    func testEveryTintClampsPersistsAndRefreshesOverlay() throws {
        let (features, overlay, defaults) = try make(smoke: 0)
        defer { features.stop() }

        features.snap.smoke = 0.3
        XCTAssertEqual(overlay.updateCount, 1, "Snap tint changes must refresh the shared veil overlay")
        features.angleBlurSmoke = 0.4
        XCTAssertEqual(overlay.updateCount, 2, "Blur tint changes must refresh the shared veil overlay")
        features.privacyVeilSmoke = 0.5
        XCTAssertEqual(overlay.updateCount, 3, "Privacy veil tint changes must refresh the shared veil overlay")

        let persistedSnap = try XCTUnwrap(defaults.data(forKey: "snapSettings"))
        XCTAssertEqual(try JSONDecoder().decode(SnapSettings.self, from: persistedSnap).smoke, 0.3, accuracy: 1e-9)
        XCTAssertEqual(defaults.double(forKey: "angleBlurSmoke"), 0.4, accuracy: 1e-9)
        XCTAssertEqual(defaults.double(forKey: "privacyVeilSmoke"), 0.5, accuracy: 1e-9)

        let tints: [(String, (Double) -> Void, () -> Double)] = [
            ("Snap", { features.snap.smoke = $0 }, { features.snap.smoke }),
            ("Blur", { features.angleBlurSmoke = $0 }, { features.angleBlurSmoke }),
            ("Privacy veil", { features.privacyVeilSmoke = $0 }, { features.privacyVeilSmoke }),
        ]
        for (name, set, value) in tints {
            set(2)
            XCTAssertEqual(value(), 1, "\(name) tint clamps values above 1")
            set(-1)
            XCTAssertEqual(value(), 0, "\(name) tint clamps values below 0")
            set(.nan)
            XCTAssertEqual(value(), 0, "\(name) tint maps non-finite values to its default")
        }

        let reloaded = DimmerFeatures(defaults: defaults, overlay: TintRecorder())
        defer { reloaded.stop() }
        XCTAssertEqual(reloaded.snap.smoke, 0)
        XCTAssertEqual(reloaded.angleBlurSmoke, 0)
        XCTAssertEqual(reloaded.privacyVeilSmoke, 0)
    }

    func testAngleTintDragIsOneUndoStepAndDoesNotUndoLaterSnapTint() throws {
        let (features, _, defaults) = try make(smoke: 0)
        defer { features.stop() }
        let history = SettingsHistory(controller: DimmerController(defaults: defaults), features: features, isMouseDown: { true })
        history.beginGesture("Blur tint")
        for value in [0.2, 0.4, 0.6] { history.setAngleBlurSmoke(value) }
        history.endGesture()
        XCTAssertEqual(features.angleBlurSmoke, 0.6)
        features.snap.smoke = 0.3
        history.undo()
        XCTAssertEqual(features.angleBlurSmoke, 0)
        XCTAssertEqual(features.snap.smoke, 0.3)
        XCTAssertFalse(history.canUndo)
        history.redo()
        XCTAssertEqual(features.angleBlurSmoke, 0.6)
    }
}

@MainActor
private final class TintRecorder: PrivacyBlurOverlay {
    var visible = false
    var strength = 0.0
    var smoke = 0.0
    private(set) var updateCount = 0
    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {
        updateCount += 1
        visible = privacyBlur
        self.strength = strength
        self.smoke = smoke
    }
    #if DEBUG
    func describe() -> String { "tint recorder" }
    #endif
    func stop() {}
}
