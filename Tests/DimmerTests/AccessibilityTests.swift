import AppKit
import XCTest
@testable import Dimmer

final class AccessibilityTests: XCTestCase {
    func testReducedTransparencySkipsNearMissVeilButKeepsLockedCover() {
        XCTAssertFalse(VeilAppearance.shouldShow(level: 0.4, locked: false, reduceTransparency: true))
        XCTAssertTrue(VeilAppearance.shouldShow(level: 0.4, locked: false, reduceTransparency: false))
        XCTAssertTrue(VeilAppearance.shouldShow(level: 1, locked: true, reduceTransparency: true))
        XCTAssertFalse(VeilAppearance.shouldShow(level: 0, locked: true, reduceTransparency: true))
    }
    func testReadoutsSpeakUnitsRatherThanAmbiguousSymbols() {
        XCTAssertEqual(AccessibilityReadout.value(74.6, unit: "°"), "75 degrees")
        XCTAssertEqual(AccessibilityReadout.value(60, unit: "°/s"), "60 degrees per second")
        XCTAssertEqual(AccessibilityReadout.value(350, unit: "ms"), "350 milliseconds")
        XCTAssertEqual(AccessibilityReadout.value(71, unit: "%"), "71 percent")
        XCTAssertEqual(AccessibilityReadout.range(0...130, unit: "°"), "Range 0 degrees to 130 degrees.")
        XCTAssertEqual(AccessibilityReadout.value(.nan, unit: "%"), "Invalid value")
        XCTAssertEqual(AccessibilityReadout.value(.infinity, unit: "°"), "Invalid value")
        XCTAssertEqual(AccessibilityReadout.value(1e20, unit: "%"), "100000000000000000000 percent")
    }

    func testReduceMotionAppliesVeilTargetsWithoutIntermediateFrames() {
        XCTAssertEqual(VeilTransition.level(from: 0, to: 0.6, elapsed: 0.01, fallingDuration: 0.35, reduceMotion: true), 0.6)
        XCTAssertEqual(VeilTransition.level(from: 1, to: 0, elapsed: 0.01, fallingDuration: 0.35, reduceMotion: true), 0)
        XCTAssertEqual(VeilTransition.level(from: 0, to: 1, elapsed: 0.09, fallingDuration: 0.35, reduceMotion: false), 0.5, accuracy: 0.001)
        XCTAssertEqual(VeilTransition.level(from: 1, to: 0, elapsed: 0.175, fallingDuration: 0.35, reduceMotion: false), 0.5, accuracy: 0.001)
        XCTAssertEqual(VeilTransition.level(from: 1, to: 0, elapsed: 0, fallingDuration: 0, reduceMotion: false), 0)
    }

    func testReduceMotionMakesGoDarkAndWakeImmediate() {
        XCTAssertEqual(GoDark.nextDarkness(0.2, isDark: true, elapsed: 0.01, reduceMotion: true), 1)
        XCTAssertEqual(GoDark.nextDarkness(0.8, isDark: false, elapsed: 0.01, reduceMotion: true), 0)
        XCTAssertEqual(GoDark.nextDarkness(0, isDark: true, elapsed: 0.4, reduceMotion: false), 0.5, accuracy: 0.001)
        XCTAssertEqual(GoDark.nextDarkness(1, isDark: false, elapsed: 0.3, reduceMotion: false), 0.5, accuracy: 0.001)
    }

    func testReducedTransparencyCoversContentEvenAtLowLockedStrength() {
        for strength in [0.01, 0.4, 1.0] {
            XCTAssertEqual(VeilAppearance.opacity(strength: strength, reduceTransparency: true), 1)
        }
        XCTAssertEqual(VeilAppearance.opacity(strength: 0, reduceTransparency: true), 0)
        XCTAssertEqual(VeilAppearance.opacity(strength: 0.4, reduceTransparency: false), 0.4)
        XCTAssertEqual(VeilAppearance.opacity(strength: 2, reduceTransparency: false), 1)
        XCTAssertEqual(VeilAppearance.opacity(strength: -1, reduceTransparency: true), 0)
    }

    @MainActor
    func testIncreasedContrastStrengthensBothTemplateGlyphStates() throws {
        func alphaMass(_ image: NSImage) throws -> Double {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var total = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    total += Double(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent)
                }
            }
            return total
        }
        for paused in [false, true] {
            let normal = StatusGlyph.image(paused: paused)
            let contrast = StatusGlyph.image(paused: paused, increaseContrast: true)
            XCTAssertTrue(contrast.isTemplate)
            XCTAssertGreaterThan(try alphaMass(contrast), try alphaMass(normal))
        }
    }

    @MainActor
    func testLeavingExactAxisEditingDoesNotRecaptureFocus() {
        let field = NSTextField(string: "73")
        var finishes: [(Double?, Bool)] = []
        let coordinator = TagNumberField.Coordinator { finishes.append(($0, $1)) }
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes.first?.0, 73)
        XCTAssertEqual(finishes.first?.1, false)
    }

    @MainActor
    func testEscapeCancelsOnceAndReturnCommitsOnceWithFocusRestored() {
        for cancel in [true, false] {
            let field = NSTextField(string: "37")
            var finishes: [(Double?, Bool)] = []
            let coordinator = TagNumberField.Coordinator { finishes.append(($0, $1)) }
            let selector = cancel ? #selector(NSResponder.cancelOperation(_:)) : #selector(NSResponder.insertNewline(_:))
            XCTAssertTrue(coordinator.control(field, textView: NSTextView(), doCommandBy: selector))
            coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
            XCTAssertEqual(finishes.count, 1)
            XCTAssertEqual(finishes.first?.0, cancel ? nil : 37)
            XCTAssertEqual(finishes.first?.1, true)
        }
    }

    @MainActor
    func testNonFiniteAxisEntryDoesNotReachTheRangeSetter() {
        let field = NSTextField(string: "nan")
        var finished = false
        let coordinator = TagNumberField.Coordinator { value, _ in
            XCTAssertNil(value)
            finished = true
        }
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertTrue(finished)
    }

    @MainActor
    func testFeaturesLoadTheProvidedPreferencesRatherThanSharedTestState() throws {
        let name = "FeaturePreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "privacyBlurEnabled")
        defaults.set(try JSONEncoder().encode(SnapSettings(zoneLow: 20, zoneHigh: 60)), forKey: "snapSettings")
        let features = DimmerFeatures(defaults: defaults)
        XCTAssertTrue(features.privacyEnabled)
        XCTAssertEqual(features.snap.zoneLow, 20)
        XCTAssertEqual(features.snap.zoneHigh, 60)
        features.privacyEnabled = false
        features.snap = SnapSettings(zoneLow: 30, zoneHigh: 70)
        let reloaded = DimmerFeatures(defaults: defaults)
        XCTAssertFalse(reloaded.privacyEnabled)
        XCTAssertEqual(reloaded.snap.zoneLow, 30)
        XCTAssertEqual(reloaded.snap.zoneHigh, 70)
    }
}
