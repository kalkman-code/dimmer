import XCTest
@testable import Dimmer

@MainActor
final class PrivacyClearSpeedTests: XCTestCase {
    func testMissingClearSpeedDefaultsTo80msAndStoredInstantSurvivesMigration() throws {
        let suite = "ClearSpeedMigration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for stored in [nil, Data("{}".utf8), Data("{\"clearSeconds\":0}".utf8)] {
            defaults.set(stored, forKey: "snapSettings")
            let features = DimmerFeatures(defaults: defaults, overlay: ClearSpeedOverlay())
            defer { features.stop() }
            let expected = stored == Data("{\"clearSeconds\":0}".utf8) ? 0.0 : 0.08
            XCTAssertEqual(features.snap.clearSeconds, expected, accuracy: 1e-9)
            let history = SettingsHistory(controller: DimmerController(defaults: defaults), features: features)
            history.restorePrivacyVeilSettings()
            XCTAssertEqual(features.snap.clearSeconds, 0.08, accuracy: 1e-9, "Privacy restore restores 80 ms, not Instant")
        }
    }

    private enum Source: CaseIterable { case shortcut, snap }
    private struct Clearing {
        var seconds: TimeInterval
        var hadIntermediateStrength: Bool
    }

    private func measure(milliseconds: Int, source: Source, byLid: Bool = false) async throws -> Clearing {
        let suite = "PrivacyClearSpeedTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = DimmerFeatures(defaults: defaults, overlay: ClearSpeedOverlay())
        defer { saved.stop() }
        let history = SettingsHistory(controller: DimmerController(defaults: defaults), features: saved)
        // The Privacy veil binding sends milliseconds / 1000 through this setter. Reloading proves the
        // value reaches the persisted settings consumed by the actual input and animation timers.
        history.setSnap(\.clearSeconds, Double(milliseconds) / 1000)
        let overlay = ClearSpeedOverlay()
        var eventTime = 99.0
        var detectedAt: TimeInterval?
        var finishedAt: TimeInterval?
        var intermediate = false
        let cleared = expectation(description: "\(source) clears at \(milliseconds) ms, lid=\(byLid)")
        let features = DimmerFeatures(defaults: defaults, overlay: overlay, lastInput: {
            if eventTime > 100.2 && detectedAt == nil {
                detectedAt = ProcessInfo.processInfo.systemUptime
            }
            return (seconds: 100.8 - eventTime, kind: "key")
        }, uptime: { 100.8 })
        defer { features.stop() }
        XCTAssertEqual(features.snap.clearSeconds, Double(milliseconds) / 1000, accuracy: 1e-9)
        switch source {
        case .shortcut: features.activatePrivacyBlurFromShortcut(at: 100.2, angle: 95)
        case .snap:
            features.privacyEnabled = true
            for (index, angle) in [110.0, 104, 95].enumerated() {
                features.update(sample: LidSample(angle: angle, time: 100 + Double(index) / 10))
            }
        }
        XCTAssertTrue(features.privacyBlurActive)
        XCTAssertEqual(overlay.strength, 1)
        overlay.onUpdate = { visible, strength in
            guard detectedAt != nil else { return }
            if strength > 0 && strength < 1 { intermediate = true }
            if !visible && finishedAt == nil {
                finishedAt = ProcessInfo.processInfo.systemUptime
                cleared.fulfill()
            }
        }
        if byLid {
            detectedAt = ProcessInfo.processInfo.systemUptime
            features.update(sample: LidSample(angle: 100, time: 100.8))
        } else {
            eventTime = 100.7
        }
        await fulfillment(of: [cleared], timeout: 2)
        XCTAssertFalse(features.privacyBlurActive)
        XCTAssertEqual(overlay.strength, 0)
        let seconds = try XCTUnwrap(finishedAt) - XCTUnwrap(detectedAt)
        print("[clear-speed] \(source) lid=\(byLid) requested=\(milliseconds)ms actual=\(Int((seconds * 1000).rounded()))ms intermediate=\(intermediate)")
        return Clearing(seconds: seconds, hadIntermediateStrength: intermediate)
    }

    func testChangingClearSpeedChangesActualShortcutAndSnapInputClearDuration() async throws {
        try XCTSkipIf(DisplayAccessibility.shared.preferences.reduceMotion, "Reduce Motion intentionally clears immediately")
        try XCTSkipIf(DisplayAccessibility.shared.preferences.reduceTransparency, "Reduce Transparency removes the opaque cover immediately")
        for source in Source.allCases {
            let instant = try await measure(milliseconds: 0, source: source)
            let medium = try await measure(milliseconds: 150, source: source)
            let slow = try await measure(milliseconds: 600, source: source)
            XCTAssertLessThan(instant.seconds, 0.05, "\(source): Instant bypasses the fade")
            XCTAssertEqual(medium.seconds, 0.15, accuracy: 0.08, "\(source): 150 ms reaches the actual clearing timer")
            XCTAssertEqual(slow.seconds, 0.6, accuracy: 0.08, "\(source): 600 ms reaches the actual clearing timer")
            XCTAssertGreaterThan(slow.seconds, medium.seconds + 0.3, "changing Clear speed must change the duration")
            XCTAssertFalse(instant.hadIntermediateStrength)
            XCTAssertTrue(medium.hadIntermediateStrength)
            XCTAssertTrue(slow.hadIntermediateStrength)
        }
    }

    func testLidLiftUsesTheSameClearSpeedForShortcutAndSnap() async throws {
        try XCTSkipIf(DisplayAccessibility.shared.preferences.reduceMotion, "Reduce Motion intentionally clears immediately")
        try XCTSkipIf(DisplayAccessibility.shared.preferences.reduceTransparency, "Reduce Transparency removes the opaque cover immediately")
        for source in Source.allCases {
            let clearing = try await measure(milliseconds: 150, source: source, byLid: true)
            XCTAssertEqual(clearing.seconds, 0.15, accuracy: 0.08)
            XCTAssertTrue(clearing.hadIntermediateStrength)
        }
    }
}

@MainActor
private final class ClearSpeedOverlay: PrivacyBlurOverlay {
    var strength = 0.0
    var onUpdate: ((Bool, Double) -> Void)?
    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {
        self.strength = strength
        onUpdate?(privacyBlur, strength)
    }
    #if DEBUG
    func describe() -> String { "clear speed recorder" }
    #endif
    func stop() {}
}
