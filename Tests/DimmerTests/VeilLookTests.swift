import XCTest
@testable import Dimmer

@MainActor
final class VeilLookTests: XCTestCase {
    private func make() throws -> (DimmerFeatures, SettingsHistory, UserDefaults) {
        let suite = "VeilLookTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        return (features, SettingsHistory(controller: controller, features: features), defaults)
    }

    func testApplyingSnapLookChangesOnlySnapStrengthAndTint() throws {
        let (features, history, _) = try make()
        features.privacyVeilBlurStrength = 0.27
        features.privacyVeilSmoke = 0.62
        features.angleBlurSmoke = 0.31
        features.angleBlurEnabled = true

        history.apply(.charcoal, to: .snap)

        XCTAssertEqual(features.snap.blurStrength, VeilLook.charcoal.strength, accuracy: 1e-9)
        XCTAssertEqual(features.snap.smoke, VeilLook.charcoal.tint, accuracy: 1e-9)
        XCTAssertEqual(features.privacyVeilBlurStrength, 0.27, accuracy: 1e-9)
        XCTAssertEqual(features.privacyVeilSmoke, 0.62, accuracy: 1e-9)
        XCTAssertEqual(features.angleBlurSmoke, 0.31, accuracy: 1e-9)
        XCTAssertTrue(features.angleBlurEnabled)
    }

    func testAngleLookChangesTintOnlyAndCustomTracksManualEdits() throws {
        let (features, history, _) = try make()
        features.angleBlurRange = DimRange(lowAngle: 61, lowLevel: 1, highAngle: 102, highLevel: 0)

        history.apply(.smoke, to: .angle)
        XCTAssertEqual(features.angleBlurSmoke, VeilLook.smoke.tint, accuracy: 1e-9)
        XCTAssertEqual(features.angleBlurRange, DimRange(lowAngle: 61, lowLevel: 1, highAngle: 102, highLevel: 0))
        XCTAssertEqual(VeilLook.matching(strength: 0.8, tint: features.angleBlurSmoke, target: .angle), .smoke)

        history.setAngleBlurSmoke(0.123)
        XCTAssertNil(VeilLook.matching(strength: 0.8, tint: features.angleBlurSmoke, target: .angle))
    }

    func testLookApplicationIsOneUndoStepAndRestoreRemainsScoped() throws {
        let (features, history, _) = try make()
        let startingSnap = features.snap
        let startingPrivacyStrength = features.privacyVeilBlurStrength
        let startingPrivacyTint = features.privacyVeilSmoke

        history.apply(.charcoal, to: .snap)
        history.undo()
        XCTAssertEqual(features.snap, startingSnap)
        XCTAssertTrue(features.privacyVeilEnabled)
        XCTAssertEqual(features.privacyVeilBlurStrength, startingPrivacyStrength, accuracy: 1e-9)
        history.redo()
        XCTAssertEqual(features.snap.blurStrength, VeilLook.charcoal.strength, accuracy: 1e-9)
        XCTAssertEqual(features.snap.smoke, VeilLook.charcoal.tint, accuracy: 1e-9)

        history.apply(.slate, to: .privacy)
        history.restorePrivacyVeilSettings()
        XCTAssertEqual(features.snap.blurStrength, VeilLook.charcoal.strength, accuracy: 1e-9)
        XCTAssertEqual(features.snap.smoke, VeilLook.charcoal.tint, accuracy: 1e-9)
        XCTAssertEqual(features.privacyVeilBlurStrength, 1, accuracy: 1e-9)
        XCTAssertEqual(features.privacyVeilSmoke, 0, accuracy: 1e-9)
        history.undo()
        XCTAssertEqual(features.privacyVeilBlurStrength, VeilLook.slate.strength, accuracy: 1e-9)
        XCTAssertEqual(features.privacyVeilSmoke, VeilLook.slate.tint, accuracy: 1e-9)
        XCTAssertEqual(features.snap.blurStrength, VeilLook.charcoal.strength, accuracy: 1e-9)
        XCTAssertEqual(startingPrivacyTint, 0, accuracy: 1e-9)
    }

    func testChosenLookValuesPersistAcrossFeatureReload() throws {
        let (features, history, defaults) = try make()
        history.apply(.mist, to: .privacy)

        let reloaded = DimmerFeatures(defaults: defaults)

        XCTAssertEqual(reloaded.privacyVeilBlurStrength, VeilLook.mist.strength, accuracy: 1e-9)
        XCTAssertEqual(reloaded.privacyVeilSmoke, VeilLook.mist.tint, accuracy: 1e-9)
        XCTAssertEqual(VeilLook.matching(strength: reloaded.privacyVeilBlurStrength,
                                         tint: reloaded.privacyVeilSmoke, target: .privacy), .mist)
        features.stop()
        reloaded.stop()
    }
}
