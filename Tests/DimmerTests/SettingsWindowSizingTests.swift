import AppKit
import SwiftUI
import XCTest
@testable import Dimmer

@MainActor
final class SettingsWindowSizingTests: XCTestCase {
    func testProductionWindowClampsBelowMinimumAndContentFitsAfterLayout() throws {
        let suite = "SettingsWindowSizingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        defer { features.stop() }
        let owner = SettingsWindowController(controller: controller, features: features,
            shell: ShellPreferences(defaults: defaults), login: LoginItem(), updates: UpdateController())
        let window = owner.loadWindow()
        window.setFrameAutosaveName("")
        defer { window.contentViewController = nil }
        let host = try XCTUnwrap(window.contentViewController?.view)

        func layout() {
            for _ in 0..<4 {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
        }
        var scrollViewsChecked = 0
        func checkContent(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                scrollViewsChecked += 1
                let viewport = host.convert(scroll.bounds, from: scroll)
                XCTAssertGreaterThanOrEqual(viewport.minX, 0, "Form must not clip off the left edge")
                XCTAssertLessThanOrEqual(viewport.maxX, host.bounds.maxX + 1, "Form must not clip off the right edge")
                XCTAssertFalse(scroll.hasHorizontalScroller, "Settings must never scroll horizontally")
                XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1,
                                         "Form document must fit its viewport")
                XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1, "Form stays at its leading edge")
            }
            view.subviews.forEach(checkContent)
        }

        for open in [true, false] {
            controller.dimsKeyboard = open
            controller.dimsScreen = open
            features.privacyEnabled = open
            features.privacyVeilEnabled = open
            features.angleBlurEnabled = open
            layout()
            XCTAssertEqual(window.contentMinSize.width, 680, accuracy: 1, "hosting must retain the layout's minimum")
            XCTAssertEqual(window.contentMinSize.height, 480, accuracy: 1)
            window.setContentSize(NSSize(width: 680, height: 100))
            layout()
            XCTAssertEqual(window.contentLayoutRect.height, 480, accuracy: 1, "short windows scroll vertically")
            for width in [100.0, 679, 680, 720, 760, 1000] {
                window.setContentSize(NSSize(width: width, height: 893))
                layout()
                XCTAssertEqual(window.contentLayoutRect.width, max(680, width), accuracy: 1, "requested \(width), open=\(open)")
                XCTAssertEqual(host.frame.minX, 0, accuracy: 1)
                XCTAssertEqual(host.bounds.width, window.contentLayoutRect.width, accuracy: 1, "hosting fills the window")
                let previous = scrollViewsChecked
                checkContent(host)
                XCTAssertGreaterThan(scrollViewsChecked, previous, "every size must inspect the actual Form viewport")
                XCTAssertFalse(window.isVisible, "geometry verification must not present Settings")
            }
        }
    }
}
