import AppKit
import Combine
import Observation
import SwiftUI
import XCTest
@testable import Dimmer

// A 10 Hz lid poll once published through the objects the whole Settings view observes, so every
// sample rebuilt and re-laid out the full Form even with the lid still. This replays polls through
// the app's own lid sinks against the real Settings view, hosted in a window that is never put on screen.
@MainActor
final class SettingsFrameBudgetTests: XCTestCase {
    private struct Run {
        var ticks = 0
        var cpu: Double = 0
        var bodies: [String: Int] = [:]
        var cpuPerTick: Double { ticks > 0 ? cpu / Double(ticks) : 0 }
    }

    private func threadCPUms() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1e6
    }

    private func drain() {
        for _ in 0..<4 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001)) }
    }

    private enum DragTarget {
        case none
        case keyboard
        case screen
        case blur
        case snapZone
        case snapTint
        case snapStrength
        case blurTint
        case privacyTint
        case privacyStrength
        case veilSwitch
    }

    // Runs ten warm-up steps, then measures `steps`, each followed by the run loop turn and the layout and
    // display pass the window would get. A step is a lid sample (`angle`) or one control change.
    private func replay(angles: [Double], drag: DragTarget = .none) throws -> Run {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsFrameBudgetTests-\(UUID().uuidString)"))
        let previousLanguage = L10n.testLanguage
        L10n.testLanguage = "en-GB"
        defer { L10n.testLanguage = previousLanguage }
        let controller = DimmerController(defaults: defaults)
        controller.dimsKeyboard = true
        controller.dimsScreen = true
        let features = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        features.privacyEnabled = true
        features.angleBlurEnabled = true
        var subscriptions = Set<AnyCancellable>()
        subscriptions.formUnion(features.follow(controller))

        let view = SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults),
                                login: LoginItem(), history: SettingsHistory(controller: controller, features: features),
                                updates: UpdateController())
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1728, height: 1084), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        var time = ProcessInfo.processInfo.systemUptime
        func tick(_ value: Double, index: Int) {
            time += 0.1
            switch drag {
            case .none:
                break
            case .keyboard:
                // A range end dragged sideways, one degree per event, with the lid still.
                controller.keyboardRange = DimRange(lowAngle: value - 60, lowLevel: 0, highAngle: value, highLevel: 1)
            case .screen:
                controller.screenRange = DimRange(lowAngle: value - 60, lowLevel: 0, highAngle: value, highLevel: 1)
            case .blur:
                features.angleBlurRange = DimRange(lowAngle: value - 60, lowLevel: 0, highAngle: value, highLevel: 1)
            case .snapZone:
                var snap = features.snap
                snap.zoneHigh = value
                features.snap = snap
            case .snapTint:
                features.snap.smoke = value
            case .snapStrength:
                features.snap.blurStrength = value
            case .blurTint:
                features.angleBlurSmoke = value
            case .privacyTint:
                features.privacyVeilSmoke = value
            case .privacyStrength:
                features.privacyVeilBlurStrength = value
            case .veilSwitch:
                features.privacyVeilEnabled = index.isMultiple(of: 2) ? false : true
            }
            let lidAngle = drag == .none ? value : 100.0
            controller.simulatePoll((sample: LidSample(angle: lidAngle, time: time), angle: lidAngle, brightness: 0.5, written: nil,
                                     displayBrightness: 0.8, displayStatus: L10n.string("Dimmer leaves automatic brightness unchanged."),
                                     keyboardStatus: nil))
            drain()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }

        for (index, value) in angles.prefix(10).enumerated() { tick(value, index: index) }

        BodyCount.reset()
        let start = threadCPUms()
        for (index, value) in angles.enumerated() { tick(value, index: index) }
        let cpu = threadCPUms() - start

        var run = Run()
        run.ticks = angles.count
        run.cpu = cpu
        run.bodies = BodyCount.counts
        window.close()
        return run
    }

    private func report(_ name: String, _ run: Run) {
        print(String(format: "[settings-fps] %@ ticks=%d cpu/tick=%.2fms", name, run.ticks, run.cpuPerTick))
        let settingsViewCount = Double(run.bodies["SettingsView", default: 0]) / Double(run.ticks)
        let laneBoxCount = Double(AxisLane.allCases.reduce(0) { $0 + run.bodies["LaneBox.\($1)", default: 0] }) / Double(run.ticks)
        let laneHeaderCount = Double(AxisLane.allCases.reduce(0) { $0 + run.bodies["LaneHeader.\($1)", default: 0] }) / Double(run.ticks)
        let lidAxisCount = Double(AxisLane.allCases.reduce(0) { $0 + run.bodies["LidAxisView.\($1)", default: 0] }) / Double(run.ticks)
        let markerCount = Double(AxisLane.allCases.reduce(0) { $0 + run.bodies["LidMarker.\($1)", default: 0] }) / Double(run.ticks)
        let liveTextCount = Double(AxisLane.allCases.reduce(0) { $0 + run.bodies["LaneLiveText.\($1)", default: 0] }) / Double(run.ticks)
        let isolatedCount = Double(run.bodies["Isolated", default: 0]) / Double(run.ticks)
        print(String(format: "[settings-fps] %@ bodies/tick SettingsView=%.2f LaneBox=%.2f LaneHeader=%.2f LidAxisView=%.2f LidMarker=%.2f LaneLiveText=%.2f Isolated=%.2f",
                     name, settingsViewCount, laneBoxCount, laneHeaderCount, lidAxisCount, markerCount, liveTextCount, isolatedCount))
        let details = run.bodies.sorted(by: { $0.key < $1.key })
            .map { String(format: "%@=%.2f", $0.key, Double($0.value) / Double(run.ticks)) }
            .joined(separator: " ")
        if !details.isEmpty {
            print("[settings-fps] \(name) details: \(details)")
        }
    }

    private func bodiesPerTick(_ name: String, in run: Run) -> Double {
        Double(run.bodies[name, default: 0]) / Double(run.ticks)
    }

    private func assertBodyRange(_ name: String, in run: Run, minimum: Double, maximum: Double,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let count = bodiesPerTick(name, in: run)
        XCTAssertGreaterThanOrEqual(count, minimum, "\(name) must draw at least \(minimum) bodies per event (got \(count))", file: file, line: line)
        XCTAssertLessThanOrEqual(count, maximum, "\(name) must draw at most \(maximum) bodies per event (got \(count))", file: file, line: line)
    }

    func testLidStillCostsSettingsNothing() throws {
        let run = try replay(angles: Array(repeating: 100, count: 60), drag: .none)
        report("lid-still", run)
        XCTAssertEqual(run.bodies.values.reduce(0, +), 0, "every counted body must stay at 0 with lid still")
    }

    func testLidMovingCost() throws {
        let run = try replay(angles: (0..<60).map { 110 - Double($0) * 0.75 }, drag: .none)
        report("lid-moving", run)
        XCTAssertEqual(run.bodies["SettingsView", default: 0], 0, "SettingsView must not evaluate during lid motion")
        for lane in AxisLane.allCases {
            XCTAssertEqual(run.bodies["LaneBox.\(lane)", default: 0], 0, "LaneBox.\(lane) must not evaluate during lid motion")
            XCTAssertEqual(run.bodies["LaneHeader.\(lane)", default: 0], 0, "LaneHeader.\(lane) must not evaluate during lid motion")
        }
        let totalLidAxisBodies = AxisLane.allCases.reduce(0) { $0 + run.bodies["LidAxisView.\($1)", default: 0] }
        let lidAxisPerTick = Double(totalLidAxisBodies) / Double(run.ticks)
        XCTAssertLessThanOrEqual(lidAxisPerTick, 0.5, "LidAxisView bodies per tick summed over the four bars must be at most 0.5 (got \(lidAxisPerTick))")

        let totalMarkerBodies = AxisLane.allCases.reduce(0) { $0 + run.bodies["LidMarker.\($1)", default: 0] }
        let markerPerTick = Double(totalMarkerBodies) / Double(run.ticks)
        XCTAssertGreaterThanOrEqual(markerPerTick, 3.9, "moving lid must redraw all four marker layers (got \(markerPerTick))")
        XCTAssertLessThanOrEqual(markerPerTick, 4.1, "Marker bodies per tick must match the four visible bars (got \(markerPerTick))")

        let totalLiveTextBodies = AxisLane.allCases.reduce(0) { $0 + run.bodies["LaneLiveText.\($1)", default: 0] }
        let liveTextPerTick = Double(totalLiveTextBodies) / Double(run.ticks)
        XCTAssertGreaterThanOrEqual(liveTextPerTick, 3.6, "moving lid must update the four visible readouts (got \(liveTextPerTick))")
        XCTAssertLessThanOrEqual(liveTextPerTick, 4.0, "live readout bodies per tick must stay within the four bars (got \(liveTextPerTick))")
        XCTAssertEqual(run.bodies["Isolated", default: 0], 0, "a moving lid must not rebuild the isolated Privacy veil section")
        for name in ["SnapTintContent", "BlurRestoreLink", "PrivacyVeilHeader", "PrivacyVeilRestoreLink",
                     "TintSettingRow.Snap tint", "TintSettingRow.Blur tint", "TintSettingRow.Privacy veil tint",
                     "BlurPreview.Snap", "BlurPreview.Angle", "BlurPreview.Privacy", "OverlapNote"] {
            XCTAssertEqual(run.bodies[name, default: 0], 0, "\(name) must not evaluate during lid motion")
        }
    }

    func testRangeDragCost() throws {
        let angles = (0..<60).map { 100 - Double($0 % 20) }
        let laneTargets: [(AxisLane, DragTarget)] = [
            (.keyboard, .keyboard),
            (.screen, .screen),
            (.blur, .blur)
        ]

        for (lane, target) in laneTargets {
            let run = try replay(angles: angles, drag: target)
            report("drag-\(lane)", run)

            for preview in ["BlurPreview.Snap", "BlurPreview.Angle", "BlurPreview.Privacy"] {
                XCTAssertEqual(run.bodies[preview, default: 0], 0,
                               "Lid range edits must not rebuild \(preview) for \(lane)")
            }

            XCTAssertLessThan(run.cpuPerTick, 16.0, "CPU per drag event must be under 16 ms for \(lane)")

            XCTAssertEqual(run.bodies["SettingsView", default: 0], 0,
                           "SettingsView must not evaluate during drag of \(lane)")

            for other in AxisLane.allCases where other != lane {
                XCTAssertEqual(run.bodies["LaneBox.\(other)", default: 0], 0,
                               "LaneBox.\(other) must not evaluate during drag of \(lane)")
                XCTAssertEqual(run.bodies["LaneHeader.\(other)", default: 0], 0,
                               "LaneHeader.\(other) must not evaluate during drag of \(lane)")
                XCTAssertEqual(run.bodies["LidAxisView.\(other)", default: 0], 0,
                               "LidAxisView.\(other) must not evaluate during drag of \(lane)")
                XCTAssertEqual(run.bodies["LidMarker.\(other)", default: 0], 0,
                               "LidMarker.\(other) must not evaluate during drag of \(lane)")
                XCTAssertEqual(run.bodies["LaneLiveText.\(other)", default: 0], 0,
                               "LaneLiveText.\(other) must not evaluate during drag of \(lane)")
            }

            let summedCoreBodies = run.bodies["SettingsView", default: 0]
                + run.bodies["LaneBox.\(lane)", default: 0]
                + run.bodies["LaneHeader.\(lane)", default: 0]
                + run.bodies["LidAxisView.\(lane)", default: 0]
                + run.bodies["LidMarker.\(lane)", default: 0]
                + run.bodies["LaneLiveText.\(lane)", default: 0]
                + (lane == .blur ? run.bodies["BlurRestoreLink", default: 0] : 0)
            let corePerEvent = Double(summedCoreBodies) / Double(run.ticks)
            // Header, live text, bar and marker run once; a tag stepping around the still lid line can run the bar again.
            XCTAssertLessThanOrEqual(corePerEvent, 4.2,
                                     "Core summed bodies per event for \(lane) must be at most 4.2 (got \(corePerEvent))")

            let expectedBlurRestore = lane == .blur ? 1.0 : 0.0
            assertBodyRange("BlurRestoreLink", in: run, minimum: expectedBlurRestore * 0.9,
                            maximum: expectedBlurRestore == 0 ? 0 : 1.1)
            let expectedOverlapNote = lane == .screen ? 1.0 : 0.0
            assertBodyRange("OverlapNote", in: run, minimum: expectedOverlapNote * 0.9,
                            maximum: expectedOverlapNote == 0 ? 0 : 1.1)
            if lane == .screen {
                XCTAssertLessThanOrEqual(corePerEvent + bodiesPerTick("OverlapNote", in: run), 5.2,
                                         "Screen total including its existing OverlapNote must be at most 5.2 bodies/event")
            }
        }

        let snapRun = try replay(angles: angles, drag: .snapZone)
        report("drag-snap-zone", snapRun)
        XCTAssertLessThan(snapRun.cpuPerTick, 16.0, "CPU per snap-zone drag event must be under 16 ms")
        XCTAssertEqual(snapRun.bodies["SettingsView", default: 0], 0, "a snap-zone drag must not rebuild the window")
        for other in AxisLane.allCases where other != .privacy {
            XCTAssertEqual(snapRun.bodies["LaneBox.\(other)", default: 0], 0, "LaneBox.\(other) must not evaluate during a snap-zone drag")
            XCTAssertEqual(snapRun.bodies["LidAxisView.\(other)", default: 0], 0, "LidAxisView.\(other) must not evaluate during a snap-zone drag")
            XCTAssertEqual(snapRun.bodies["LidMarker.\(other)", default: 0], 0, "LidMarker.\(other) must not evaluate during a snap-zone drag")
            XCTAssertEqual(snapRun.bodies["LaneLiveText.\(other)", default: 0], 0, "LaneLiveText.\(other) must not evaluate during a snap-zone drag")
        }
        let laneBoxPerEvent = Double(snapRun.bodies["LaneBox.privacy", default: 0]) / Double(snapRun.ticks)
        XCTAssertLessThanOrEqual(laneBoxPerEvent, 1.05, "LaneBox.privacy must evaluate at most 1.05 times per snap-zone drag event (got \(laneBoxPerEvent))")
        let isolatedPerEvent = Double(snapRun.bodies["Isolated", default: 0]) / Double(snapRun.ticks)
        XCTAssertEqual(isolatedPerEvent, 0, "zone edits must not rebuild Privacy veil's unrelated Clear speed control")
        for (name, minimum, maximum) in [
            ("SnapTintContent", 0.9, 1.1),
            ("TintSettingRow.Snap tint", 0.0, 0.0),
            ("PrivacyVeilRestoreLink", 0.9, 1.1),
            ("BlurPreview.Snap", 0.0, 0.0),
            ("BlurPreview.Angle", 0.0, 0.0),
            ("BlurPreview.Privacy", 0.0, 0.0),
            ("OverlapNote", 0.9, 1.1),
            ("BlurRestoreLink", 0.0, 0.0),
            ("PrivacyVeilHeader", 0.0, 0.0),
            ("TintSettingRow.Blur tint", 0.0, 0.0),
            ("TintSettingRow.Privacy veil tint", 0.0, 0.0),
        ] {
            assertBodyRange(name, in: snapRun, minimum: minimum, maximum: maximum)
        }
    }

    func testRangeEditPlacesTagAgainstCurrentLidInOneBarRender() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsFrameBudgetTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        controller.keyboardRange = DimRange(lowAngle: 20, lowLevel: 0.1, highAngle: 60, highLevel: 0.9)
        let features = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        let bar = LidAxisView(lane: .keyboard, controller: controller, features: features,
                              history: SettingsHistory(controller: controller, features: features))
        let host = NSHostingView(rootView: bar.frame(width: 640))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 140), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }

        func drainAndDisplay() {
            drain()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        controller.simulatePoll((sample: LidSample(angle: 100, time: ProcessInfo.processInfo.systemUptime), angle: 100,
                                 brightness: 0.5, written: nil, displayBrightness: 0.8,
                                 displayStatus: L10n.string("Dimmer leaves automatic brightness unchanged."), keyboardStatus: nil))
        drainAndDisplay()

        BodyCount.reset()
        controller.keyboardRange = DimRange(lowAngle: 20, lowLevel: 0.1, highAngle: 88, highLevel: 0.9)
        drainAndDisplay()

        XCTAssertEqual(BodyCount.counts["LidAxisView.keyboard", default: 0], 1,
                       "the edited high tag overlaps the still 100° lid line and must be placed in the range edit render")
    }

    // The budgets count bodies, and a body that never runs is cheap for the wrong reason. This draws one bar on
    // its own and proves a range edit and a lid move each still change its pixels.
    func testBarStillRedrawsForARangeEditAndALidMove() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsFrameBudgetTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        let bar = LidAxisView(lane: .keyboard, controller: controller, features: features,
                              history: SettingsHistory(controller: controller, features: features))
        let host = NSHostingView(rootView: bar.frame(width: 640))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 140), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }

        func pixels() throws -> Data {
            drain()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try XCTUnwrap(rep.tiffRepresentation)
        }
        func poll(_ angle: Double) {
            controller.simulatePoll((sample: LidSample(angle: angle, time: ProcessInfo.processInfo.systemUptime), angle: angle,
                                     brightness: 0.5, written: nil, displayBrightness: 0.8,
                                     displayStatus: L10n.string("Dimmer leaves automatic brightness unchanged."), keyboardStatus: nil))
        }

        poll(100)
        let before = try pixels()
        controller.keyboardRange = DimRange(lowAngle: 20, lowLevel: 0.1, highAngle: 70, highLevel: 0.9)
        let edited = try pixels()
        XCTAssertNotEqual(before, edited, "a range edit must redraw its bar")
        poll(45)
        let moved = try pixels()
        XCTAssertNotEqual(edited, moved, "a lid move must redraw the bar's lid layer")
    }

    func testTintEditsDoNotPublishToTheOtherSettingsBoxes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsFrameBudgetTests-\(UUID().uuidString)"))
        let features = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        defer { features.stop() }

        let snapFlag = ObservationChangeFlag()
        let blurFlag = ObservationChangeFlag()
        let privacyFlag = ObservationChangeFlag()
        let snapConfigurationFlag = ObservationChangeFlag()
        func trackTintValues() {
            withObservationTracking {
                _ = features.snapConfiguration
            } onChange: {
                MainActor.assumeIsolated { snapConfigurationFlag.changed = true }
            }
            withObservationTracking {
                _ = features.snapTint.value
            } onChange: {
                MainActor.assumeIsolated { snapFlag.changed = true }
            }
            withObservationTracking {
                _ = features.angleBlurTint.value
            } onChange: {
                MainActor.assumeIsolated { blurFlag.changed = true }
            }
            withObservationTracking {
                _ = features.privacyVeilTint.value
            } onChange: {
                MainActor.assumeIsolated { privacyFlag.changed = true }
            }
        }

        trackTintValues()
        features.snap.smoke = 0.6
        XCTAssertTrue(snapFlag.changed)
        XCTAssertFalse(blurFlag.changed)
        XCTAssertFalse(privacyFlag.changed)
        XCTAssertFalse(snapConfigurationFlag.changed,
                       "Snap tint edits must not invalidate shared controls or bar geometry")

        snapFlag.changed = false
        blurFlag.changed = false
        privacyFlag.changed = false
        snapConfigurationFlag.changed = false
        trackTintValues()
        features.angleBlurSmoke = 0.7
        XCTAssertFalse(snapFlag.changed)
        XCTAssertTrue(blurFlag.changed)
        XCTAssertFalse(privacyFlag.changed)
        XCTAssertFalse(snapConfigurationFlag.changed)

        snapFlag.changed = false
        blurFlag.changed = false
        privacyFlag.changed = false
        snapConfigurationFlag.changed = false
        trackTintValues()
        features.privacyVeilSmoke = 0.8
        XCTAssertFalse(snapFlag.changed)
        XCTAssertFalse(blurFlag.changed)
        XCTAssertTrue(privacyFlag.changed)
        XCTAssertFalse(snapConfigurationFlag.changed)
    }

    func testSnapControlFieldsObserveOnlyTheirOwnChanges() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SnapControlObservation-\(UUID().uuidString)"))
        let features = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        defer { features.stop() }
        let fields: [(KeyPath<DimmerFeatures, Double>, WritableKeyPath<SnapSettings, Double>)] = [
            (\.snapDegrees, \.snapDegrees), (\.snapMinimumSpeed, \.minimumSpeed), (\.snapClearSeconds, \.clearSeconds)
        ]
        func track() -> [ObservationChangeFlag] {
            fields.map { field, _ in
                let flag = ObservationChangeFlag()
                withObservationTracking { _ = features[keyPath: field] } onChange: {
                    MainActor.assumeIsolated { flag.changed = true }
                }
                return flag
            }
        }
        let zoneFlags = track()
        features.snap.zoneHigh = 95
        XCTAssertTrue(zoneFlags.allSatisfy { !$0.changed }, "zone edits must leave distance, speed and Clear speed controls untouched")
        for (index, (field, setting)) in fields.enumerated() {
            let flags = track()
            let updated = features[keyPath: field] + 0.01
            features.snap[keyPath: setting] = updated
            XCTAssertEqual(features[keyPath: field], updated)
            for (other, flag) in flags.enumerated() {
                XCTAssertEqual(flag.changed, other == index, "only the changed control may invalidate")
            }
            let noOpFlags = track()
            features.snap[keyPath: setting] = updated
            XCTAssertTrue(noOpFlags.allSatisfy { !$0.changed }, "equal assignment must not invalidate controls")
        }
        let replacementFlags = track()
        var replacement = features.snap
        replacement.snapDegrees = 9
        replacement.minimumSpeed = 120
        replacement.clearSeconds = 0.15
        features.snap = replacement
        XCTAssertTrue(replacementFlags.allSatisfy(\.changed), "whole configuration assignment must update every changed field")
        let reloaded = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        defer { reloaded.stop() }
        XCTAssertEqual(reloaded.snap, replacement, "field observation must preserve the complete persisted configuration")
    }

    func testSnapControlFieldsUpdateTheirRenderedValues() throws {
        let previousLanguage = L10n.testLanguage
        L10n.testLanguage = "en-GB"
        defer { L10n.testLanguage = previousLanguage }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SnapControlRendering-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        defer { features.stop() }
        features.privacyEnabled = true
        let history = SettingsHistory(controller: controller, features: features)
        let view = SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults),
                                login: LoginItem(), history: history, updates: UpdateController())
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 1600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func fields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { fields(in: $0) }
        }
        func render() {
            drain()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        render()
        let controls = fields(in: host)
        let distance = try XCTUnwrap(controls.first { $0.stringValue == "5" })
        let speed = try XCTUnwrap(controls.first { $0.stringValue == "60" })
        let clear = try XCTUnwrap(controls.first { $0.stringValue == "80" })

        BodyCount.reset()
        history.setSnap(\.snapDegrees, 13)
        render()
        XCTAssertEqual(distance.stringValue, "13")
        XCTAssertEqual(speed.stringValue, "60")
        XCTAssertEqual(clear.stringValue, "80")
        XCTAssertGreaterThan(BodyCount.counts["LaneBox.privacy", default: 0], 0)
        XCTAssertEqual(BodyCount.counts["Isolated", default: 0], 0)

        BodyCount.reset()
        history.setSnap(\.minimumSpeed, 145)
        render()
        XCTAssertEqual(distance.stringValue, "13")
        XCTAssertEqual(speed.stringValue, "145")
        XCTAssertEqual(clear.stringValue, "80")
        XCTAssertGreaterThan(BodyCount.counts["LaneBox.privacy", default: 0], 0)
        XCTAssertEqual(BodyCount.counts["Isolated", default: 0], 0)

        BodyCount.reset()
        history.setSnap(\.clearSeconds, 0.23)
        render()
        XCTAssertEqual(distance.stringValue, "13")
        XCTAssertEqual(speed.stringValue, "145")
        XCTAssertEqual(clear.stringValue, "230")
        XCTAssertEqual(BodyCount.counts["LaneBox.privacy", default: 0], 0)
        XCTAssertGreaterThan(BodyCount.counts["Isolated", default: 0], 0, "Clear speed must update its own Privacy controls")
        for preview in ["BlurPreview.Snap", "BlurPreview.Angle", "BlurPreview.Privacy"] {
            XCTAssertEqual(BodyCount.counts[preview, default: 0], 0)
        }
        history.undoManager.undo()
        render()
        XCTAssertEqual(clear.stringValue, "80", "Clear speed undo must reach the actual field")
        history.undoManager.redo()
        render()
        XCTAssertEqual(clear.stringValue, "230", "Clear speed redo must reach the actual field")

        var replacement = features.snap
        replacement.snapDegrees = 17
        replacement.minimumSpeed = 175
        replacement.clearSeconds = 0.36
        features.snap = replacement
        render()
        XCTAssertEqual(distance.stringValue, "17")
        XCTAssertEqual(speed.stringValue, "175")
        XCTAssertEqual(clear.stringValue, "360")
    }

    func testStrengthEditsPublishOnlyToTheirOwnSettingsControls() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsStrengthBudget-\(UUID().uuidString)"))
        let features = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        defer { features.stop() }

        let snapFlag = ObservationChangeFlag()
        let privacyFlag = ObservationChangeFlag()
        let geometryFlag = ObservationChangeFlag()
        func trackStrengthControls() {
            withObservationTracking {
                _ = features.snap.blurStrength
            } onChange: {
                MainActor.assumeIsolated { snapFlag.changed = true }
            }
            withObservationTracking {
                _ = features.privacyVeilBlurStrength
            } onChange: {
                MainActor.assumeIsolated { privacyFlag.changed = true }
            }
            withObservationTracking {
                _ = features.snapConfiguration.blurStrength
            } onChange: {
                MainActor.assumeIsolated { geometryFlag.changed = true }
            }
        }

        trackStrengthControls()
        features.snap.blurStrength = 0.4
        XCTAssertTrue(snapFlag.changed, "Snap's slider must observe Snap strength")
        XCTAssertFalse(privacyFlag.changed, "Snap strength must not redraw the Privacy veil slider")
        XCTAssertFalse(geometryFlag.changed, "strength must not invalidate zone geometry controls")

        snapFlag.changed = false
        privacyFlag.changed = false
        geometryFlag.changed = false
        trackStrengthControls()
        features.privacyVeilBlurStrength = 0.6
        XCTAssertFalse(snapFlag.changed, "Privacy strength must not redraw the Snap slider")
        XCTAssertTrue(privacyFlag.changed, "Privacy veil's slider must observe its own strength")
        XCTAssertFalse(geometryFlag.changed, "Privacy strength must not invalidate Snap zone geometry controls")
    }

    func testTintAndSwitchReplaysRebuildOnlyTheirOwnSettings() throws {
        let angles = (0..<60).map { Double($0) / 100 + 0.1 }
        let targets: [(String, DragTarget, String)] = [
            ("snap-tint", .snapTint, "TintSettingRow.Snap tint"),
            ("blur-tint", .blurTint, "TintSettingRow.Blur tint"),
            ("privacy-tint", .privacyTint, "TintSettingRow.Privacy veil tint"),
        ]
        for (label, target, row) in targets {
            let run = try replay(angles: angles, drag: target)
            report(label, run)
            assertBodyRange(row, in: run, minimum: 0.9, maximum: 1.1)
            XCTAssertLessThan(run.cpuPerTick, 25.0, "Tint edit should stay below 25 ms/event for \(label)")
            XCTAssertEqual(run.bodies["SettingsView", default: 0], 0)
            for lane in AxisLane.allCases {
                for view in ["LaneBox", "LaneHeader", "LidAxisView", "LidMarker", "LaneLiveText"] {
                    XCTAssertEqual(run.bodies["\(view).\(lane)", default: 0], 0,
                                   "\(view).\(lane) must not rebuild during \(label)")
                }
            }
            for other in targets.map(\.2) where other != row {
                XCTAssertEqual(run.bodies[other, default: 0], 0, "\(other) must not rebuild during \(label)")
            }
            let previewName: String = switch target {
            case .snapTint, .snapStrength: "BlurPreview.Snap"
            case .blurTint: "BlurPreview.Angle"
            case .privacyTint, .privacyStrength: "BlurPreview.Privacy"
            default: ""
            }
            if !previewName.isEmpty { assertBodyRange(previewName, in: run, minimum: 0.9, maximum: 1.1) }
            for other in ["BlurPreview.Snap", "BlurPreview.Angle", "BlurPreview.Privacy"] where other != previewName {
                XCTAssertEqual(run.bodies[other, default: 0], 0, "\(other) must not rebuild during \(label)")
            }
            if target == .snapTint {
                assertBodyRange("SnapTintContent", in: run, minimum: 0.9, maximum: 1.1)
            } else {
                XCTAssertEqual(run.bodies["SnapTintContent", default: 0], 0)
            }
            if target == .privacyTint {
                XCTAssertEqual(run.bodies["Isolated", default: 0], 0,
                               "Tint changes must not invalidate the isolated section container")
                assertBodyRange("PrivacyVeilRestoreLink", in: run, minimum: 0.9, maximum: 1.1)
            } else {
                XCTAssertEqual(run.bodies["Isolated", default: 0], 0)
                XCTAssertEqual(run.bodies["PrivacyVeilRestoreLink", default: 0], 0)
            }
            XCTAssertEqual(run.bodies["PrivacyVeilHeader", default: 0], 0)
            let expectedBlurRestore = target == .blurTint ? 1.0 : 0.0
            assertBodyRange("BlurRestoreLink", in: run, minimum: expectedBlurRestore * 0.9,
                            maximum: expectedBlurRestore == 0 ? 0 : 1.1)
            XCTAssertEqual(run.bodies["OverlapNote", default: 0], 0)
        }

        let switchRun = try replay(angles: (0..<60).map { Double($0) }, drag: .veilSwitch)
        report("privacy-veil-switch", switchRun)
        XCTAssertLessThan(switchRun.cpuPerTick, 100.0, "Privacy veil mount/collapse must stay below 100 ms/event")
        assertBodyRange("Isolated", in: switchRun, minimum: 0.9, maximum: 1.1)
        assertBodyRange("PrivacyVeilHeader", in: switchRun, minimum: 0.9, maximum: 1.1)
        XCTAssertEqual(switchRun.bodies["SettingsView", default: 0], 0)
        for name in ["SnapTintContent", "TintSettingRow.Snap tint", "TintSettingRow.Blur tint",
                     "OverlapNote", "BlurRestoreLink"] {
            XCTAssertEqual(switchRun.bodies[name, default: 0], 0, "\(name) must not rebuild when only the switch changes")
        }
        for (name, expected) in [("TintSettingRow.Privacy veil tint", 0.5), ("BlurPreview.Privacy", 0.5),
                                 ("PrivacyVeilRestoreLink", 0.5)] {
            assertBodyRange(name, in: switchRun, minimum: expected - 0.1, maximum: expected + 0.1)
        }
        for name in ["BlurPreview.Snap", "BlurPreview.Angle"] {
            XCTAssertEqual(switchRun.bodies[name, default: 0], 0, "\(name) must not rebuild with the Privacy veil switch")
        }
        for lane in AxisLane.allCases {
            for view in ["LaneBox", "LaneHeader", "LidAxisView", "LidMarker", "LaneLiveText"] {
                XCTAssertEqual(switchRun.bodies["\(view).\(lane)", default: 0], 0,
                               "\(view).\(lane) must not rebuild when only the veil switch changes")
            }
        }
    }

    func testStrengthDragsRebuildOnlyTheirOwnPreview() throws {
        let angles = (0..<60).map { Double($0) / 100 + 0.1 }
        for (label, target, preview) in [
            ("snap-strength", DragTarget.snapStrength, "BlurPreview.Snap"),
            ("privacy-strength", DragTarget.privacyStrength, "BlurPreview.Privacy"),
        ] {
            let run = try replay(angles: angles, drag: target)
            report(label, run)
            XCTAssertLessThan(run.cpuPerTick, 25.0, "Strength edit should stay below 25 ms/event for \(label)")
            assertBodyRange(preview, in: run, minimum: 0.9, maximum: 1.1)
            for other in ["BlurPreview.Snap", "BlurPreview.Angle", "BlurPreview.Privacy"] where other != preview {
                XCTAssertEqual(run.bodies[other, default: 0], 0, "\(other) must not rebuild during \(label)")
            }
            XCTAssertEqual(run.bodies["SettingsView", default: 0], 0, "Strength edit must not rebuild SettingsView")
            for lane in AxisLane.allCases {
                let ownSnapBox = target == .snapStrength && lane == .privacy
                XCTAssertEqual(run.bodies["LaneBox.\(lane)", default: 0], ownSnapBox ? run.ticks : 0,
                               "Only Snap's containing box may evaluate during \(label)")
                for view in ["LaneHeader", "LidAxisView", "LidMarker", "LaneLiveText"] {
                    XCTAssertEqual(run.bodies["\(view).\(lane)", default: 0], 0,
                                   "\(view).\(lane) must not rebuild during \(label)")
                }
            }
        }
    }

    func testTintPixelsChangeAndPrivacyVeilSwitchChangesGeometry() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsFrameBudgetTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        let features = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        features.privacyEnabled = true
        features.angleBlurEnabled = true
        features.privacyVeilEnabled = true
        let history = SettingsHistory(controller: controller, features: features)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 90), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }

        func pixels() throws -> Data {
            drain()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try XCTUnwrap(rep.tiffRepresentation)
        }
        func renderTintRow(_ kind: AxisLane, start: Double, end: Double, set: @escaping (Double) -> Void) throws -> (Data, Data) {
            let tint: VeilTintSettings
            switch kind {
            case .keyboard, .screen: tint = features.snapTint
            case .blur: tint = features.angleBlurTint
            case .privacy: tint = features.privacyVeilTint
            }
            set(start)
            let title: String = kind == .privacy ? "Privacy veil tint" : "\(kind) tint"
            let root = VStack {
                TintSettingRow(title: "Tint", accessibilityTitle: title, detail: "Tint darkness", tint: tint,
                               history: history, actionName: "Tint", set: set)
            }.frame(width: 680, height: 90)
            host.rootView = AnyView(root)
            let before = try pixels()
            set(end)
            return (before, try pixels())
        }
        for (kind, start, end, set) in [
            (AxisLane.keyboard, 0.10, 0.80, { features.snap.smoke = $0 }),
            (AxisLane.blur, 0.10, 0.80, { features.angleBlurSmoke = $0 }),
            (AxisLane.privacy, 0.10, 0.80, { features.privacyVeilSmoke = $0 }),
        ] {
            let (before, after) = try renderTintRow(kind, start: start, end: end, set: set)
            XCTAssertNotEqual(before, after, "\(kind) tint must change rendered pixels")
        }

        let settings = SettingsView(controller: controller, features: features, shell: ShellPreferences(defaults: defaults),
                                    login: LoginItem(), history: history, updates: UpdateController())
        host.rootView = AnyView(settings.frame(width: 680))
        let openHeight = host.fittingSize.height
        features.privacyVeilEnabled = false
        drain()
        host.layoutSubtreeIfNeeded()
        let closedHeight = host.fittingSize.height
        XCTAssertGreaterThan(openHeight - closedHeight, 70, "Turning Privacy veil off must collapse its settings rows")
        features.privacyVeilEnabled = true
        drain()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, openHeight, accuracy: 2, "Turning Privacy veil on must restore its rows")
    }
}

@MainActor
private final class ObservationChangeFlag {
    var changed = false
}

private final class SilentBudgetOverlay: PrivacyBlurOverlay {
    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {}
    #if DEBUG
    func describe() -> String { "" }
    #endif
    func stop() {}
}
