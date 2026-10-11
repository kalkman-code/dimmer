import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI
import XCTest
@testable import Dimmer

@MainActor
final class PrivacyVeilSwitchTests: XCTestCase {
    func testPrivacyVeilDefaultsOnAndPersistsAcrossLaunches() throws {
        let suite = "PrivacyVeilSwitchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let firstLaunch = DimmerFeatures(defaults: defaults)
        defer { firstLaunch.stop(); defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(firstLaunch.privacyVeilEnabled)
        firstLaunch.privacyVeilEnabled = false

        let nextLaunch = DimmerFeatures(defaults: defaults)
        defer { nextLaunch.stop() }
        XCTAssertFalse(nextLaunch.privacyVeilEnabled)
    }

    func testDisablingPrivacyVeilClearsAnActiveShortcutVeil() throws {
        let suite = "PrivacyVeilSwitchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let overlay = VeilSwitchOverlay()
        let features = DimmerFeatures(defaults: defaults, overlay: overlay)
        defer { features.stop(); defaults.removePersistentDomain(forName: suite) }

        features.privacyEnabled = true
        features.angleBlurEnabled = true
        features.setLidAngle(84)
        XCTAssertEqual(try XCTUnwrap(overlay.lastUpdate).strength, 0.5, accuracy: 0.0001)
        features.activatePrivacyBlurFromShortcut(at: 100, angle: 85)
        XCTAssertTrue(features.privacyBlurActive)

        features.privacyVeilEnabled = false

        XCTAssertFalse(features.privacyBlurActive)
        XCTAssertEqual(overlay.lastUpdate?.privacyBlur, true, "the independent angle blur stays visible")
        XCTAssertEqual(try XCTUnwrap(overlay.lastUpdate).strength, 0.5, accuracy: 0.0001)

        features.activatePrivacyBlurFromShortcut(at: 101, angle: 85)
        XCTAssertFalse(features.privacyBlurActive)
        features.snap = SnapSettings(zoneLow: 50, zoneHigh: 101)
        for (angle, time) in [(104.0, 100.0), (102, 100.03), (99, 100.06)] {
            features.update(sample: LidSample(angle: angle, time: time))
        }
        XCTAssertTrue(features.privacyBlurActive, "Snap to blur stays enabled independently")
    }

    func testDisablingPrivacyVeilFinishesAnActiveShortcutClearFadeImmediately() throws {
        let suite = "PrivacyVeilSwitchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let overlay = VeilSwitchOverlay()
        let features = DimmerFeatures(defaults: defaults, overlay: overlay)
        defer { features.stop(); defaults.removePersistentDomain(forName: suite) }

        features.privacyEnabled = true
        features.angleBlurEnabled = true
        features.setLidAngle(84)
        features.snap.clearSeconds = 0.3
        features.activatePrivacyBlurFromShortcut(at: 100, angle: 85)
        features.update(sample: LidSample(angle: 90, time: 101))

        XCTAssertFalse(features.privacyBlurActive)
        XCTAssertGreaterThan(try XCTUnwrap(overlay.lastUpdate).strength, 0.5)

        features.privacyVeilEnabled = false

        XCTAssertEqual(try XCTUnwrap(overlay.lastUpdate).strength, 0.5, accuracy: 0.0001,
                       "only the independent angle blur remains after the shortcut fade is stopped")
    }

    func testSwitchingPrivacyVeilOffAndOnKeepsTheRecordedChord() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PrivacyVeilSwitchTests-\(UUID().uuidString)"))
        let features = DimmerFeatures(defaults: defaults)
        let saved = KeyboardShortcuts.getShortcut(for: .privacyBlur)
        let recorded = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option])
        defer {
            features.stop()
            KeyboardShortcuts.setShortcut(saved, for: .privacyBlur)
        }

        KeyboardShortcuts.setShortcut(recorded, for: .privacyBlur)
        features.privacyVeilEnabled = false
        features.privacyVeilEnabled = true

        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .privacyBlur), recorded)
    }

    func testDisabledPrivacyShortcutListenerUnregistersAndReactivates() async {
        var subscriptions = 0
        let started = expectation(description: "shortcut listener subscribes when enabled")
        let stopped = expectation(description: "shortcut listener unsubscribes when disabled")
        let saved = KeyboardShortcuts.getShortcut(for: .privacyBlur)
        let recorded = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option])
        KeyboardShortcuts.setShortcut(recorded, for: .privacyBlur)
        let listener = ShortcutListener(name: .privacyBlur, events: {
            subscriptions += 1
            started.fulfill()
            return AsyncStream { continuation in
                continuation.onTermination = { _ in stopped.fulfill() }
            }
        }, isAllowed: { true }, onTrigger: {})
        defer { listener.stop(); KeyboardShortcuts.setShortcut(saved, for: .privacyBlur) }

        listener.restart(enabled: false)
        await Task.yield()
        XCTAssertEqual(subscriptions, 0)

        listener.restart(enabled: true)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(subscriptions, 1)

        listener.restart(enabled: false)
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .privacyBlur), recorded)
    }

    func testSwitchPublisherStopsAndRestartsThePrivacyShortcutListener() async throws {
        let suite = "PrivacyVeilSwitchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let features = DimmerFeatures(defaults: defaults)
        defer { features.stop(); defaults.removePersistentDomain(forName: suite) }

        let firstStarted = expectation(description: "default-on switch registers the listener")
        let firstStopped = expectation(description: "turning off unregisters the listener")
        let secondStarted = expectation(description: "turning on re-registers the listener")
        var subscriptions = 0
        let listener = ShortcutListener(name: .privacyBlur, events: {
            subscriptions += 1
            let subscriptionNumber = subscriptions
            if subscriptionNumber == 1 { firstStarted.fulfill() } else if subscriptionNumber == 2 { secondStarted.fulfill() }
            return AsyncStream { continuation in
                continuation.onTermination = { _ in
                    if subscriptionNumber == 1 { firstStopped.fulfill() }
                }
            }
        }, isAllowed: { true }, onTrigger: {})
        defer { listener.stop() }
        var observers = Set<AnyCancellable>()

        listener.restart(enabled: features.privacyVeilEnabled)
        features.privacyVeilEnabledPublisher.dropFirst().sink { enabled in
            listener.restart(enabled: enabled)
        }.store(in: &observers)
        await fulfillment(of: [firstStarted], timeout: 1)

        features.privacyVeilEnabled = false
        await fulfillment(of: [firstStopped], timeout: 1)
        XCTAssertEqual(subscriptions, 1)

        features.privacyVeilEnabled = true
        await fulfillment(of: [secondStarted], timeout: 1)
        XCTAssertEqual(subscriptions, 2)
    }

    func testPrivacyVeilHeaderFitsInEveryLanguageWhenOpenAndCollapsed() throws {
        let suite = "PrivacyVeilSwitchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        defer { features.stop(); L10n.testLanguage = nil; defaults.removePersistentDomain(forName: suite) }
        let history = SettingsHistory(controller: controller, features: features)
        let width: CGFloat = 600
        var heights: [String: (open: CGFloat, collapsed: CGFloat)] = [:]

        for language in ["en-GB", "es", "pt-BR", "de", "fr", "ja"] {
            L10n.testLanguage = language
            features.privacyVeilEnabled = true
            let open = NSHostingView(rootView: PrivacyVeilHeader(features: features, history: history).frame(width: width)).fittingSize.height
            features.privacyVeilEnabled = false
            let collapsed = NSHostingView(rootView: PrivacyVeilHeader(features: features, history: history).frame(width: width)).fittingSize.height
            heights[language] = (open, collapsed)
        }

        let english = try XCTUnwrap(heights["en-GB"])
        for language in ["es", "pt-BR", "de", "fr", "ja"] {
            let measured = try XCTUnwrap(heights[language])
            XCTAssertLessThanOrEqual(measured.open, english.open + 1, "\(language): open title row wraps")
            XCTAssertLessThanOrEqual(measured.collapsed, english.collapsed + 1, "\(language): collapsed title row wraps")
        }
    }
}

@MainActor
private final class VeilSwitchOverlay: PrivacyBlurOverlay {
    private(set) var lastUpdate: (privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool)?

    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {
        lastUpdate = (privacyBlur, strength, smoke, reduceTransparency)
    }

    func describe() -> String { "" }

    func stop() {}
}
