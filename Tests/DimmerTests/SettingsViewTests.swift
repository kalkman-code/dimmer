import AppKit
import SwiftUI
import XCTest
@testable import Dimmer

// Builds, lays out and draws the real Settings and menu views off screen, so a SwiftUI trap in
// either shows up here rather than on the first click in the app.
@MainActor
final class SettingsViewTests: XCTestCase {
    func testActualSnapBoxOffContainsOnlyItsTitleRow() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        defer { features.stop() }
        features.privacyEnabled = false
        let history = SettingsHistory(controller: controller, features: features)
        let settings = SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults),
                                    login: LoginItem(), history: history, updates: UpdateController())
        let actual = NSHostingView(rootView: Form { settings.snapBox }.formStyle(.grouped).frame(width: 680)).fittingSize
        let titleOnly = NSHostingView(rootView: Form {
            Section {
                LaneHeader(lane: .privacy, isOn: .constant(false), controller: controller, features: features, history: history)
                    .padding(.vertical, 2)
            }
        }.formStyle(.grouped).frame(width: 680)).fittingSize
        XCTAssertEqual(actual.height, titleOnly.height, accuracy: 1, "off hides both Tint and Restore snap defaults")
    }

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
        let view = SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults), login: LoginItem(), history: SettingsHistory(controller: controller, features: features), updates: UpdateController())
        let rep = try XCTUnwrap(render(view, size: NSSize(width: 680, height: 893)))
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        // Set DIMMER_RENDER_PNG to a path to look at the window's layout without opening the app.
        if let path = ProcessInfo.processInfo.environment["DIMMER_RENDER_PNG"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        let fitting = NSHostingController(rootView: view).view.fittingSize
        XCTAssertGreaterThan(fitting.height, 300)
    }

    // Snap off collapses its box to the title row; snap on with the screen dimming inside the zone adds the
    // overlap note to the Screen box.
    func testSnapBoxCollapsesAndOverlapNoteShows() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        controller.dimsScreen = true
        let features = DimmerFeatures(defaults: defaults)
        defer { features.stop() }
        let history = SettingsHistory(controller: controller, features: features)
        func box(_ lane: AxisLane) -> CGFloat {
            let host = NSHostingView(rootView: Form { Section { LaneBox(lane: lane, controller: controller, features: features, history: history) { EmptyView() } } }.formStyle(.grouped).frame(width: 680))
            host.appearance = NSAppearance(named: .darkAqua)
            return host.fittingSize.height
        }
        features.privacyEnabled = false
        let collapsed = box(.privacy)
        features.privacyEnabled = true
        let open = box(.privacy)
        XCTAssertGreaterThan(open, collapsed + 80, "the zone bar and its details open under the title row")
        let settings = { () -> CGFloat in
            let host = NSHostingView(rootView: SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults), login: LoginItem(), history: history, updates: UpdateController()).frame(width: 680))
            host.appearance = NSAppearance(named: .darkAqua)
            return host.fittingSize.height
        }
        let overlapping = settings()
        controller.screenRange = controller.screenRange.movedBelow(features.snap.zoneLow)
        let moved = settings()
        XCTAssertEqual(controller.screenRange.highAngle, features.snap.zoneLow)
        XCTAssertGreaterThan(overlapping, moved + 20, "the overlap note goes once the screen range is below the zone")
    }

    // 207dec5 crashed in the axis Canvas when the lid sat just past the screen range's top end: a label
    // gap was built as a range with reversed bounds. Draw every bar at every half degree, over ranges and
    // zones pushed to the ends of the axis, so any value the Canvas draws from is exercised; the crash window was about 1.6° wide.
    func testEveryBarDrawsAtEveryLidAngleAndEdgeRange() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        let history = SettingsHistory(controller: controller, features: features)
        let hosts = try AxisLane.allCases.map { lane -> (NSHostingView<LidAxisView>, NSBitmapImageRep) in
            let host = NSHostingView(rootView: LidAxisView(lane: lane, controller: controller, features: features, history: history))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 604, height: host.fittingSize.height)
            return (host, try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)))
        }
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
            features.angleBlurRange = range
            var snap = features.snap
            (snap.zoneLow, snap.zoneHigh) = zones[index % zones.count]
            features.snap = snap
            for step in stride(from: -2.0, through: 132, by: 0.5) {
                controller.simulateLid(angle: step)
                features.setLidAngle(step)
                for (host, rep) in hosts {
                    host.layoutSubtreeIfNeeded()
                    host.cacheDisplay(in: host.bounds, to: rep)
                }
            }
        }
        controller.simulateLid(angle: nil)
        features.setLidAngle(nil)
        for (host, rep) in hosts { host.cacheDisplay(in: host.bounds, to: rep) }
    }

    // The view's own drag path: beginDrag is what its gesture calls on the first movement, then drag moves the
    // end, so the name Cmd+Z shows is the one the view opens the gesture with, not one the test supplies.
    func testDraggingEachBarNamesTheUndoStepAfterItsOwnLane() throws {
        let expected: [(AxisLane, String)] = [(.keyboard, "Brightness range"), (.screen, "Brightness range"),
                                              (.privacy, "Privacy settings"), (.blur, "Blur range")]
        for (lane, name) in expected {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
            let controller = DimmerController(defaults: defaults)
            let features = DimmerFeatures(defaults: defaults)
            defer { features.stop() }
            let history = SettingsHistory(controller: controller, features: features, isMouseDown: { true })
            let view = LidAxisView(lane: lane, controller: controller, features: features, history: history)
            let size = CGSize(width: 604, height: NSHostingView(rootView: view).fittingSize.height)

            let start = view.point(of: lane.handles[0], size: size)
            let handle = try XCTUnwrap(view.beginDrag(at: start, size: size), "\(lane): no end under the pointer")
            for step in 1...6 { view.drag(handle, to: CGPoint(x: start.x + CGFloat(step) * 6, y: start.y), size: size) }
            history.endGesture()

            XCTAssertTrue(history.canUndo, "\(lane): the drag registered no step")
            XCTAssertEqual(history.undoManager.undoActionName, L10n.string(String.LocalizationValue(name)), "\(lane)")
            history.undo()
            XCTAssertEqual(controller.keyboardRange, .keyboardDefault, "\(lane)")
            XCTAssertEqual(controller.screenRange, .screenDefault, "\(lane)")
            XCTAssertEqual(features.angleBlurRange, .blurDefault, "\(lane)")
            XCTAssertEqual(features.snap, SnapSettings().clamped(maximum: LidAxis.maximum), "\(lane)")
        }
    }

    // A box whose feature is off is its title row alone, and each switch opens only its own box.
    func testEachBoxOpensOnlyWithItsOwnSwitch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        defer { features.stop() }
        let history = SettingsHistory(controller: controller, features: features)
        func settingsHeight() -> CGFloat {
            let host = NSHostingView(rootView: SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults), login: LoginItem(), history: history, updates: UpdateController()).frame(width: 680))
            host.appearance = NSAppearance(named: .darkAqua)
            return host.fittingSize.height
        }
        XCTAssertFalse(features.privacyEnabled)
        XCTAssertTrue(features.privacyVeilEnabled)
        XCTAssertFalse(features.angleBlurEnabled)
        controller.dimsKeyboard = false
        controller.dimsScreen = false
        features.privacyVeilEnabled = false
        let allOff = settingsHeight()
        var previous = allOff
        let switches: [(String, () -> Void)] = [
            ("keyboard", { controller.dimsKeyboard = true }),
            ("screen", { controller.dimsScreen = true }),
            ("snap", { features.privacyEnabled = true }),
            ("blur", { features.angleBlurEnabled = true }),
            ("privacy veil", { features.privacyVeilEnabled = true }),
        ]
        for (name, turnOn) in switches {
            turnOn()
            let height = settingsHeight()
            XCTAssertGreaterThan(height, previous + 70, "\(name): its bar and restore link open under the title row")
            previous = height
        }
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

    func testAboutContentFitsItsWindow() {
        let size = AboutWindowController.contentSize
        let fitting = NSHostingController(rootView: AboutView().frame(width: size.width)).view.fittingSize
        XCTAssertLessThanOrEqual(fitting.height, size.height)
    }

    func testMenuPanelRenders() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
        let view = DimmerMenu(controller: DimmerController(defaults: defaults), features: DimmerFeatures(defaults: defaults), updates: UpdateController(), showSettings: {})
        XCTAssertNotNil(render(view, size: NSSize(width: 260, height: 360)))
    }

    func testMenuPanelIsFixedAt320Points() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsViewTests-\(UUID().uuidString)"))
        let view = DimmerMenu(controller: DimmerController(defaults: defaults), features: DimmerFeatures(defaults: defaults), updates: UpdateController(), showSettings: {})
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
        let panel = NSHostingView(rootView: DimmerMenu(controller: controller, features: features, updates: UpdateController(), showSettings: {}))
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
            let settings = SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults), login: LoginItem(), history: SettingsHistory(controller: controller, features: features), updates: UpdateController())
            XCTAssertNotNil(render(settings, size: NSSize(width: width, height: 640)))
        }
    }

    // Every translation, laid out in one process with every box open and then every box collapsed, at the
    // narrowest width the window allows. SwiftUI wraps text rather than clipping it, so a title row too long for
    // its box shows as the row growing taller than in English, and a long panel or help line as extra height.
    func testEveryLanguageFitsWithEveryBoxOpenAndCollapsed() throws {
        let name = "LocalisedFitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults)
        defer { features.stop(); L10n.testLanguage = nil; defaults.removePersistentDomain(forName: name) }
        let minimumWidth: CGFloat = 680

        func setBoxes(open: Bool) {
            controller.dimsKeyboard = open
            controller.dimsScreen = open
            features.privacyEnabled = open
            features.privacyVeilEnabled = open
            features.angleBlurEnabled = open
        }

        struct Measure { var panel: NSSize; var openHeaders: [CGFloat]; var collapsedHeaders: [CGFloat]; var tintRows: [NSSize]; var restoreLabels: [NSSize]; var openSettings: CGFloat; var collapsedSettings: CGFloat; var about: CGFloat }
        func measure() -> Measure {
            let history = SettingsHistory(controller: controller, features: features)
            setBoxes(open: true)
            let panel = NSHostingView(rootView: DimmerMenu(controller: controller, features: features, updates: UpdateController(), showSettings: {}))
            panel.appearance = NSAppearance(named: .darkAqua)
            let panelSize = panel.fittingSize
            panel.frame = NSRect(origin: .zero, size: panelSize)
            panel.layoutSubtreeIfNeeded()
            func checkSegments(_ view: NSView) {
                if let control = view as? NSSegmentedControl {
                    XCTAssertGreaterThanOrEqual(control.bounds.width + 1, control.intrinsicContentSize.width, "\(L10n.testLanguage ?? ""): duration labels must fit the segmented picker")
                }
                view.subviews.forEach(checkSegments)
            }
            checkSegments(panel)
            // The title row of each box, at the narrowest width a box has: a bar is a Canvas and cannot wrap,
            // so this row (name, reading, restore link, switch) is the part of a box that can.
            func headers(open: Bool) -> [CGFloat] {
                AxisLane.allCases.map { lane in
                    NSHostingView(rootView: LaneHeader(lane: lane, isOn: .constant(open), controller: controller, features: features, history: history).frame(width: minimumWidth - 80)).fittingSize.height
                }
            }
            let openHeaders = headers(open: true)
            let collapsedHeaders = headers(open: false)
            let tintRows = [
                ("Snap tint", "Sets the darkness of the snap veil", features.snapTint),
                ("Privacy veil tint", "Sets the darkness of the shortcut veil", features.privacyVeilTint),
                ("Blur tint", "Sets the darkness of the angle blur, scaled with its blur strength.", features.angleBlurTint)
            ].map { title, detail, tint in
                NSHostingView(rootView: TintSettingRow(title: L10n.string("Tint"), accessibilityTitle: L10n.string(String.LocalizationValue(title)),
                    detail: L10n.string(String.LocalizationValue(detail)), tint: tint, history: history,
                    actionName: String.LocalizationValue(title), set: { _ in }).frame(width: minimumWidth - 80)).fittingSize
            }
            let restoreLabels = ["Restore snap defaults", "Restore privacy veil defaults"].map { title in
                NSHostingView(rootView: RestoreLinkLabel(title: L10n.string(String.LocalizationValue(title)), enabled: true).fixedSize()).fittingSize
            }
            func settings() -> CGFloat {
                NSHostingView(rootView: SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults), login: LoginItem(), history: history, updates: UpdateController()).frame(width: minimumWidth)).fittingSize.height
            }
            let open = settings()
            setBoxes(open: false)
            let collapsed = settings()
            let about = NSHostingController(rootView: AboutView().frame(width: AboutWindowController.contentSize.width)).view.fittingSize.height
            return Measure(panel: panelSize, openHeaders: openHeaders, collapsedHeaders: collapsedHeaders, tintRows: tintRows, restoreLabels: restoreLabels, openSettings: open, collapsedSettings: collapsed, about: about)
        }

        L10n.testLanguage = "en-GB"
        let english = measure()
        for language in ["es", "pt-BR", "de", "fr", "ja"] {
            L10n.testLanguage = language
            XCTAssertNotEqual(L10n.string("Settings…"), "Settings…", "\(language) did not load")
            let found = measure()
            XCTAssertEqual(found.panel.width, 320, accuracy: 1, language)
            XCTAssertLessThanOrEqual(found.panel.height, english.panel.height + 20, "\(language): panel wraps")
            for (lane, (header, baseline)) in zip(AxisLane.allCases, zip(found.openHeaders, english.openHeaders)) {
                XCTAssertLessThanOrEqual(header, baseline + 1, "\(language): the open \(lane) title row wraps at \(minimumWidth) pt")
            }
            for (lane, (header, baseline)) in zip(AxisLane.allCases, zip(found.collapsedHeaders, english.collapsedHeaders)) {
                XCTAssertLessThanOrEqual(header, baseline + 1, "\(language): the collapsed \(lane) title row wraps at \(minimumWidth) pt")
            }
            XCTAssertLessThanOrEqual(found.openSettings, english.openSettings * 1.15, "\(language): Settings with every box open wraps far more than English")
            XCTAssertLessThanOrEqual(found.collapsedSettings, english.collapsedSettings * 1.15, "\(language): Settings with every box collapsed wraps far more than English")
            for (index, row) in found.tintRows.enumerated() {
                XCTAssertEqual(row.width, minimumWidth - 80, accuracy: 1, "\(language): tint row overflows")
                XCTAssertLessThanOrEqual(row.height, english.tintRows[index].height + 16, "\(language): tint row wraps excessively")
            }
            for label in found.restoreLabels {
                XCTAssertLessThanOrEqual(label.width, minimumWidth - 80, "\(language): restore label overflows its box")
            }
            XCTAssertLessThanOrEqual(found.about, AboutWindowController.contentSize.height, "\(language): About overflows its window")
        }
        XCTAssertLessThan(english.collapsedSettings, english.openSettings - 400, "collapsing every box should shrink Settings a lot")
        // The title-row measure must be able to fail: squeezed far narrower than any window, the same row grows.
        L10n.testLanguage = "en-GB"
        let squeezed = NSHostingView(rootView: LaneHeader(lane: .blur, isOn: .constant(true), controller: controller, features: features, history: SettingsHistory(controller: controller, features: features)).frame(width: 150)).fittingSize.height
        XCTAssertGreaterThan(squeezed, english.openHeaders[AxisLane.allCases.firstIndex(of: .blur)!] + 5, "a wrapped title row must read taller")
    }
}
