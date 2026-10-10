import AppKit
import SwiftUI
import XCTest
@testable import Dimmer

// Builds, lays out and draws the real Settings and menu views off screen, so a SwiftUI trap in
// either shows up here rather than on the first click in the app.
@MainActor
final class SettingsViewTests: XCTestCase {
    private func render<V: View>(_ view: V, size: NSSize) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    func testSettingsViewRendersWithLiveState() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        let view = SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults), login: LoginItem())
        let rep = try XCTUnwrap(render(view, size: NSSize(width: 680, height: 893)))
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        // Set DIMMER_RENDER_PNG to a path to look at the window's layout without opening the app.
        if let path = ProcessInfo.processInfo.environment["DIMMER_RENDER_PNG"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        let fitting = NSHostingController(rootView: view).view.fittingSize
        XCTAssertGreaterThan(fitting.height, 300)
    }

    // Snap off hides the Privacy lane and the axis closes up; snap on with the screen dimming inside the
    // zone adds the overlap note. Set DIMMER_RENDER_DIR to a folder to look at all three.
    func testPrivacyLaneHidesAndOverlapNoteShows() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        controller.dimsScreen = true
        let features = DimmerFeatures(defaults: defaults)
        let view = LidAxisView(controller: controller, features: features)
        func height(_ name: String) throws -> CGFloat {
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .darkAqua)
            let size = host.fittingSize
            if let dir = ProcessInfo.processInfo.environment["DIMMER_RENDER_DIR"],
               let rep = render(view, size: NSSize(width: 604, height: size.height)) {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
            return size.height
        }
        features.privacyEnabled = false
        let hidden = try height("axis-snap-off.png")
        features.privacyEnabled = true
        let overlapping = try height("axis-snap-on-overlap.png")
        controller.screenRange = controller.screenRange.movedBelow(features.snap.zoneLow)
        let moved = try height("axis-snap-on-moved.png")
        XCTAssertEqual(controller.screenRange.highAngle, features.snap.zoneLow)
        XCTAssertGreaterThan(moved, hidden + 40, "the Privacy lane should add its 44 pt back")
        XCTAssertGreaterThan(overlapping, moved, "the overlap note should show only while the ranges overlap")
    }

    // 207dec5 crashed in the axis Canvas when the lid sat just past the screen range's top end: a label
    // gap was built as a range with reversed bounds. Draw the axis at every half degree, over ranges and
    // zones pushed to the ends of the axis, so any value the Canvas draws from is exercised; the crash window was about 1.6° wide.
    func testAxisDrawsAtEveryLidAngleAndEdgeRange() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        features.privacyEnabled = true
        let host = NSHostingView(rootView: LidAxisView(controller: controller, features: features))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 604, height: 300)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        let ranges = [
            DimRange.screenDefault,
            DimRange(lowAngle: 71, lowLevel: 0, highAngle: 72, highLevel: 1),
            DimRange(lowAngle: 0, lowLevel: 1, highAngle: 1, highLevel: 0),
            DimRange(lowAngle: 129, lowLevel: 0, highAngle: 130, highLevel: 1),
        ]
        let zones: [(Double, Double)] = [(75, 91), (0, 2), (128, 130)]
        for (index, range) in ranges.enumerated() {
            controller.screenRange = range
            controller.keyboardRange = range
            var snap = features.snap
            (snap.zoneLow, snap.zoneHigh) = zones[index % zones.count]
            features.snap = snap
            for step in stride(from: -2.0, through: 132, by: 0.5) {
                controller.simulateLid(angle: step)
                host.layoutSubtreeIfNeeded()
                host.cacheDisplay(in: host.bounds, to: rep)
            }
        }
        controller.simulateLid(angle: nil)
        host.cacheDisplay(in: host.bounds, to: rep)
    }

    // Live screen coverage is an integrator check; this exercises the shared veil/preview view off screen.
    func testVeilAndPreviewTreatmentSwitchesToAnOpaqueCover() throws {
        let view = DimmerBlurView(frame: NSRect(x: 0, y: 0, width: 300, height: 64))
        let tint = try XCTUnwrap(view.subviews.first)
        view.update(smoke: 0, reduceTransparency: true)
        XCTAssertEqual(tint.alphaValue, 1)
        let frost = NSColor(cgColor: try XCTUnwrap(tint.layer?.backgroundColor))
        XCTAssertEqual(try XCTUnwrap(frost).alphaComponent, 1)
        view.update(smoke: 1, reduceTransparency: true)
        XCTAssertEqual(tint.alphaValue, 1)
        let smoke = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(tint.layer?.backgroundColor)))
        XCTAssertEqual(smoke.alphaComponent, 1)
        XCTAssertLessThan(smoke.whiteComponent, try XCTUnwrap(frost).whiteComponent)
        view.update(smoke: 0.4, reduceTransparency: false)
        XCTAssertEqual(tint.alphaValue, 0.3, accuracy: 0.001)
    }

    func testMenuPanelRenders() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
        let view = DimmerMenu(controller: DimmerController(defaults: defaults), features: DimmerFeatures(defaults: defaults), showSettings: {})
        XCTAssertNotNil(render(view, size: NSSize(width: 260, height: 360)))
    }

    func testMenuPanelIsFixedAt320Points() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
        let view = DimmerMenu(controller: DimmerController(defaults: defaults), features: DimmerFeatures(defaults: defaults), showSettings: {})
        let width = NSHostingController(rootView: view).view.fittingSize.width
        XCTAssertEqual(width, 320, accuracy: 1)
    }

    func testLocalisedPanelAndSettingsFitAvailableWidths() throws {
        if let language = ProcessInfo.processInfo.environment["DIMMER_TEST_LANGUAGE"] {
            XCTAssertEqual(L10n.bundle.preferredLocalizations.first, language, "The off-screen check must use the requested translation")
        }
        let name = "LocalisedLayoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        features.privacyEnabled = true
        let panel = NSHostingView(rootView: DimmerMenu(controller: controller, features: features, showSettings: {}))
        let size = panel.fittingSize
        XCTAssertGreaterThanOrEqual(size.width, 260)
        XCTAssertLessThanOrEqual(size.width, 440)
        panel.frame = NSRect(origin: .zero, size: size)
        panel.layoutSubtreeIfNeeded()
        func checkSegments(_ view: NSView) {
            if let control = view as? NSSegmentedControl {
                XCTAssertGreaterThanOrEqual(control.bounds.width + 1, control.intrinsicContentSize.width, "Localised duration labels must fit the segmented picker")
            }
            view.subviews.forEach(checkSegments)
        }
        checkSegments(panel)
        for width in [CGFloat(680), 760, 900] {
            let settings = SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults), login: LoginItem())
            XCTAssertNotNil(render(settings, size: NSSize(width: width, height: 640)))
        }
    }
}
