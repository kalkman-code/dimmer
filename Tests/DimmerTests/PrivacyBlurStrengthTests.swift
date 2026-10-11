import XCTest
@testable import Dimmer

@MainActor
final class PrivacyBlurStrengthTests: XCTestCase {
    func testMissingPrivacyStrengthMigratesTheClampedLegacyValueOnceIncludingZero() throws {
        for (legacy, expected) in [(nil as Data?, 1.0),
                                   (Data("{}".utf8), 1.0),
                                   (Data("{\"blurStrength\":0}".utf8), 0.0),
                                   (try JSONEncoder().encode(SnapSettings(blurStrength: 0.42)), 0.42),
                                   (try JSONEncoder().encode(SnapSettings(blurStrength: 1.4)), 1.0)] {
            let suite = "PrivacyBlurStrengthMigration-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if let legacy { defaults.set(legacy, forKey: "snapSettings") }

            let firstLaunch = DimmerFeatures(defaults: defaults, overlay: StrengthOverlay())
            XCTAssertNotNil(defaults.object(forKey: "privacyVeilBlurStrength"), "saved zero must differ from an absent migration key")
            XCTAssertEqual(defaults.double(forKey: "privacyVeilBlurStrength"), expected, accuracy: 1e-9,
                           "the missing privacy value should inherit the old shared Snap value")
            firstLaunch.snap.blurStrength = 0.2

            let secondLaunch = DimmerFeatures(defaults: defaults, overlay: StrengthOverlay())
            defer { firstLaunch.stop(); secondLaunch.stop() }
            XCTAssertEqual(defaults.double(forKey: "privacyVeilBlurStrength"), expected, accuracy: 1e-9,
                           "a saved independent value must not be reseeded after Snap changes")
        }
    }

    func testShortcutUsesPrivacyStrengthAndSnapUsesSnapStrength() throws {
        let suite = "PrivacyBlurStrengthSources-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(SnapSettings(blurStrength: 0.25)), forKey: "snapSettings")
        defaults.set(0.8, forKey: "privacyVeilBlurStrength")
        let overlay = StrengthOverlay()
        let features = DimmerFeatures(defaults: defaults, overlay: overlay)
        defer { features.stop() }

        features.activatePrivacyBlurFromShortcut(at: 100, angle: 85)
        XCTAssertEqual(overlay.strength, 0.8, accuracy: 1e-9, "shortcut veil reads its own saved strength")
        features.suspend(reason: "test")
        features.privacyEnabled = true
        features.snap = SnapSettings(zoneLow: 50, zoneHigh: 101, blurStrength: 0.25)
        for (angle, time) in [(110.0, 100.0), (104, 100.03), (95, 100.06)] {
            features.update(sample: LidSample(angle: angle, time: time))
        }
        XCTAssertTrue(features.privacyBlurActive)
        XCTAssertEqual(overlay.strength, 0.25, accuracy: 1e-9, "Snap veil reads Snap's own saved strength")
    }

    func testExplicitSavedZeroSurvivesRelaunchAndStrengthValuesClamp() throws {
        let suite = "PrivacyBlurStrengthSaved-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(SnapSettings(blurStrength: 0.4)), forKey: "snapSettings")
        defaults.set(0.0, forKey: "privacyVeilBlurStrength")

        let firstLaunch = DimmerFeatures(defaults: defaults, overlay: StrengthOverlay())
        XCTAssertEqual(firstLaunch.privacyVeilBlurStrength, 0, accuracy: 1e-9,
                       "an explicit saved zero must not be treated as a missing migration key")
        firstLaunch.privacyVeilBlurStrength = 0.65
        let secondLaunch = DimmerFeatures(defaults: defaults, overlay: StrengthOverlay())
        defer { firstLaunch.stop(); secondLaunch.stop() }
        XCTAssertEqual(secondLaunch.privacyVeilBlurStrength, 0.65, accuracy: 1e-9)

        secondLaunch.privacyVeilBlurStrength = -0.1
        XCTAssertEqual(secondLaunch.privacyVeilBlurStrength, 0, accuracy: 1e-9)
        secondLaunch.privacyVeilBlurStrength = 1.4
        XCTAssertEqual(secondLaunch.privacyVeilBlurStrength, 1, accuracy: 1e-9)
        secondLaunch.privacyVeilBlurStrength = .nan
        XCTAssertEqual(secondLaunch.privacyVeilBlurStrength, 1, accuracy: 1e-9)
    }

    func testSnapAndPrivacyRestoresOnlyTheirOwnStrength() throws {
        let suite = "PrivacyBlurStrengthRestore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.3, forKey: "privacyVeilBlurStrength")
        let features = DimmerFeatures(defaults: defaults, overlay: StrengthOverlay())
        defer { features.stop() }
        let history = SettingsHistory(controller: DimmerController(defaults: defaults), features: features)

        features.snap.blurStrength = 0.4
        history.restoreSnapSettings()
        XCTAssertEqual(features.snap.blurStrength, 1, accuracy: 1e-9, "Snap restore resets Snap strength")
        XCTAssertEqual(defaults.double(forKey: "privacyVeilBlurStrength"), 0.3, accuracy: 1e-9,
                       "Snap restore leaves Privacy veil strength alone")

        features.snap.blurStrength = 0.6
        history.restorePrivacyVeilSettings()
        XCTAssertEqual(features.snap.blurStrength, 0.6, accuracy: 1e-9,
                       "Privacy restore leaves Snap strength alone")
        XCTAssertEqual(defaults.double(forKey: "privacyVeilBlurStrength"), 1, accuracy: 1e-9,
                       "Privacy restore resets its own strength")
    }

    func testSnapStrengthUndoUsesItsOwnActionName() throws {
        let suite = "PrivacyBlurStrengthUndo-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = DimmerFeatures(defaults: defaults, overlay: StrengthOverlay())
        defer { features.stop() }
        let history = SettingsHistory(controller: DimmerController(defaults: defaults), features: features)

        history.setSnap(\.blurStrength, 0.4)

        XCTAssertEqual(history.undoManager.undoActionName, L10n.string("Snap blur strength"))
    }

    func testPrivacyStrengthUndoGroupsValuesUnderItsOwnNameAndLeavesSnapAlone() throws {
        let suite = "PrivacyBlurStrengthHistory-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = DimmerFeatures(defaults: defaults, overlay: StrengthOverlay())
        defer { features.stop() }
        let history = SettingsHistory(controller: DimmerController(defaults: defaults), features: features)
        features.snap.blurStrength = 0.3
        for value in [0.2, 0.4, 0.6] { history.setPrivacyVeilBlurStrength(value) }

        XCTAssertEqual(history.undoManager.undoActionName, L10n.string("Privacy veil blur strength"))
        features.snap.blurStrength = 0.5
        history.undo()
        XCTAssertEqual(features.privacyVeilBlurStrength, 1, accuracy: 1e-9)
        XCTAssertEqual(features.snap.blurStrength, 0.5, accuracy: 1e-9,
                       "undo restores only the Privacy veil strength edited by the step")
        history.redo()
        XCTAssertEqual(features.privacyVeilBlurStrength, 0.6, accuracy: 1e-9)
        XCTAssertEqual(features.snap.blurStrength, 0.5, accuracy: 1e-9)
    }

    func testShortcutVeilKeepsItsOwnStrengthWhileClearingAndSnapChanges() async throws {
        try XCTSkipIf(DisplayAccessibility.shared.preferences.reduceMotion, "Reduce Motion intentionally clears immediately")
        try XCTSkipIf(DisplayAccessibility.shared.preferences.reduceTransparency, "Reduce Transparency removes the opaque cover immediately")
        let suite = "PrivacyBlurStrengthFade-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(SnapSettings(blurStrength: 0.25, clearSeconds: 0.6)), forKey: "snapSettings")
        defaults.set(0.8, forKey: "privacyVeilBlurStrength")
        let overlay = StrengthOverlay()
        let features = DimmerFeatures(defaults: defaults, overlay: overlay)
        defer { features.stop() }
        let cleared = expectation(description: "shortcut veil finishes its clear fade")
        var fadingStrengths: [Double] = []
        var didFinishFade = false
        overlay.onUpdate = { visible, strength in
            if !visible && strength == 0 && !didFinishFade {
                didFinishFade = true
                cleared.fulfill()
            }
            else if !features.privacyBlurActive { fadingStrengths.append(strength) }
        }

        features.activatePrivacyBlurFromShortcut(at: 100, angle: 85)
        XCTAssertEqual(overlay.strength, 0.8, accuracy: 1e-9)
        features.update(sample: LidSample(angle: 88, time: 101))
        XCTAssertFalse(features.privacyBlurActive)
        features.snap.blurStrength = 0.1

        await fulfillment(of: [cleared], timeout: 2)
        XCTAssertTrue(fadingStrengths.contains { $0 > 0.5 }, "the fade remains based on Privacy veil strength")
        XCTAssertTrue(fadingStrengths.allSatisfy { $0 <= 0.8 }, "the unrelated Snap strength never replaces the held shortcut source")
        XCTAssertEqual(overlay.strength, 0, accuracy: 1e-9)
    }

    func testSnapVeilKeepsItsOwnStrengthWhileClearingAndPrivacyChanges() async throws {
        try XCTSkipIf(DisplayAccessibility.shared.preferences.reduceMotion, "Reduce Motion intentionally clears immediately")
        try XCTSkipIf(DisplayAccessibility.shared.preferences.reduceTransparency, "Reduce Transparency removes the opaque cover immediately")
        let suite = "SnapBlurStrengthFade-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(SnapSettings(blurStrength: 0.75, clearSeconds: 0.6)), forKey: "snapSettings")
        defaults.set(0.8, forKey: "privacyVeilBlurStrength")
        let overlay = StrengthOverlay()
        let features = DimmerFeatures(defaults: defaults, overlay: overlay)
        defer { features.stop() }
        features.angleBlurEnabled = false
        let cleared = expectation(description: "Snap veil finishes its clear fade")
        var fadingStrengths: [Double] = []
        var didFinishFade = false
        var clearing = false
        overlay.onUpdate = { visible, strength in
            if clearing && !visible && strength == 0 && !didFinishFade {
                didFinishFade = true
                cleared.fulfill()
            } else if !features.privacyBlurActive {
                fadingStrengths.append(strength)
            }
        }
        features.privacyEnabled = true
        for (angle, time) in [(110.0, 100.0), (104, 100.03), (95, 100.06)] {
            features.update(sample: LidSample(angle: angle, time: time))
        }
        XCTAssertTrue(features.privacyBlurActive)
        XCTAssertEqual(overlay.strength, 0.75, accuracy: 1e-9)
        clearing = true
        features.update(sample: LidSample(angle: 100, time: 101))
        XCTAssertFalse(features.privacyBlurActive)
        features.privacyVeilBlurStrength = 0.1

        await fulfillment(of: [cleared], timeout: 2)
        XCTAssertTrue(fadingStrengths.contains { $0 > 0.1 }, "the fade remains based on Snap strength")
        XCTAssertTrue(fadingStrengths.allSatisfy { $0 <= 0.75 }, "unrelated Privacy strength cannot replace Snap during its fade")
        XCTAssertEqual(overlay.strength, 0, accuracy: 1e-9)
    }
}

@MainActor
private final class StrengthOverlay: PrivacyBlurOverlay {
    var strength = 0.0
    var onUpdate: ((Bool, Double) -> Void)?

    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {
        self.strength = strength
        onUpdate?(privacyBlur, strength)
    }

    #if DEBUG
    func describe() -> String { "strength recorder" }
    #endif

    func stop() {}
}
