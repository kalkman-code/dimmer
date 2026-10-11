import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Dimmer

// Toby, 10-10-2026: the Settings window felt low fps. The 10 Hz lid poll published through the
// objects the whole Settings view observes, so every sample rebuilt and re-laid out the full Form
// even with the lid still. This replays polls through the same publishing and the app's own lid
// sinks against the real Settings view, hosted in a window that is never put on screen.
@MainActor
final class SettingsFrameBudgetTests: XCTestCase {
    private struct Run {
        var ticks = 0
        var cpu: Double = 0
        var controllerChanges = 0
        var featureChanges = 0
        var readingChanges = 0
        // Body evaluations by view, counted from `Self._printChanges()` lines; empty unless a view body carries one.
        var bodies: [String: Int] = [:]
        var cpuPerTick: Double { cpu / Double(ticks) }
    }

    private func threadCPUms() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1e6
    }

    private func drain() {
        for _ in 0..<4 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001)) }
    }

    // Runs ten warm-up steps, then measures `steps`, each followed by the run loop turn and the layout and
    // display pass the window would get. A step is a lid sample (`angle`) or, for `drag`, a range edit.
    private func replay(angles: [Double], drag: Bool = false) throws -> Run {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsFrameBudgetTests-\(UUID().uuidString)"))
        let controller = DimmerController(defaults: defaults)
        controller.dimsScreen = true
        let features = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        features.privacyEnabled = true
        features.angleBlurEnabled = true
        var subscriptions = Set<AnyCancellable>()
        // The same two sinks AppDelegate wires from the controller to the features.
        controller.telemetry.$angle.sink { angle in
            Task { @MainActor in
                if angle == nil { features.angleUnavailable() }
                features.setLidAngle(angle)
            }
        }.store(in: &subscriptions)
        controller.telemetry.$rawSample.compactMap { $0 }
            .sink { sample in Task { @MainActor in features.update(sample: sample) } }
            .store(in: &subscriptions)

        var run = Run()
        controller.objectWillChange.sink { run.controllerChanges += 1 }.store(in: &subscriptions)
        features.objectWillChange.sink { run.featureChanges += 1 }.store(in: &subscriptions)
        controller.reading.objectWillChange.sink { run.readingChanges += 1 }.store(in: &subscriptions)
        features.laneReading.objectWillChange.sink { run.readingChanges += 1 }.store(in: &subscriptions)

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
        func tick(_ angle: Double) {
            time += 0.1
            if drag {
                // A keyboard-range end dragged sideways, one degree per event, with the lid still.
                controller.keyboardRange = DimRange(lowAngle: angle - 60, lowLevel: 0, highAngle: angle, highLevel: 1)
            }
            controller.simulatePoll((sample: LidSample(angle: drag ? 100 : angle, time: time), angle: drag ? 100 : angle, brightness: 0.5, written: nil,
                                     displayBrightness: 0.8, displayStatus: L10n.string("Dimmer leaves automatic brightness unchanged."),
                                     keyboardStatus: nil))
            drain()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        for _ in 0..<10 { tick(angles[0]) }
        run = Run()
        let changes = FileManager.default.temporaryDirectory.appendingPathComponent("settings-fps-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: changes.path, contents: nil)
        let capture = open(changes.path, O_WRONLY)
        fflush(stdout)
        let terminal = dup(STDOUT_FILENO)
        dup2(capture, STDOUT_FILENO)
        let start = threadCPUms()
        for angle in angles { tick(angle) }
        run.cpu = threadCPUms() - start
        fflush(stdout)
        dup2(terminal, STDOUT_FILENO)
        close(terminal)
        close(capture)
        for line in (try? String(contentsOf: changes, encoding: .utf8))?.split(separator: "\n") ?? [] {
            if let name = ["SettingsView", "LaneBox", "LidAxisView"].first(where: { line.hasPrefix($0) }) { run.bodies[name, default: 0] += 1 }
        }
        try? FileManager.default.removeItem(at: changes)
        run.ticks = angles.count
        window.close()
        return run
    }

    private func report(_ name: String, _ run: Run) {
        print(String(format: "[settings-fps] %@ ticks=%d cpu/tick=%.2fms controllerWillChange/tick=%.2f featuresWillChange/tick=%.2f readingChanges/tick=%.2f",
                     name, run.ticks, run.cpuPerTick,
                     Double(run.controllerChanges) / Double(run.ticks), Double(run.featureChanges) / Double(run.ticks),
                     Double(run.readingChanges) / Double(run.ticks)))
        let bodies = ["SettingsView", "LaneBox", "LidAxisView"].map { String(format: "%@=%.2f", $0, Double(run.bodies[$0, default: 0]) / Double(run.ticks)) }
        print("[settings-fps] \(name) bodies/tick " + bodies.joined(separator: " "))
    }

    func testLidStillCostsSettingsNothing() throws {
        let run = try replay(angles: Array(repeating: 100, count: 60))
        report("lid-still", run)
        XCTAssertEqual(run.controllerChanges, 0, "a still-lid sample must not reach an object the Settings boxes observe")
        XCTAssertEqual(run.featureChanges, 0, "a still-lid sample must not reach an object the Settings boxes observe")
        XCTAssertEqual(run.readingChanges, 0, "a still lid shows nothing new, so the readings must not change")
    }

    func testLidMovingCost() throws {
        let run = try replay(angles: (0..<60).map { 110 - Double($0) * 0.75 })
        report("lid-moving", run)
        XCTAssertEqual(run.controllerChanges, 0, "lid samples must reach the views only through the readings")
        XCTAssertEqual(run.featureChanges, 0, "lid samples must reach the views only through the readings")
        XCTAssertLessThanOrEqual(run.readingChanges, run.ticks * 3, "at most the angle and the two lane levels per sample")
    }

    // Not a budget the lid sets: dragging one range end republishes the controller, so every box redraws.
    // Measured for the diagnosis; see the fix spec's second stage.
    func testRangeDragCost() throws {
        let run = try replay(angles: (0..<60).map { 100 - Double($0 % 20) }, drag: true)
        report("range-drag", run)
    }

    func testTintEditsDoNotPublishToTheOtherSettingsBoxes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsFrameBudgetTests-\(UUID().uuidString)"))
        let features = DimmerFeatures(defaults: defaults, overlay: SilentBudgetOverlay())
        defer { features.stop() }
        var featureChanges = 0
        var snapTintChanges = 0
        var blurTintChanges = 0
        let featureSubscription = features.objectWillChange.sink { featureChanges += 1 }
        let snapSubscription = features.snapTint.objectWillChange.sink { snapTintChanges += 1 }
        let blurSubscription = features.angleBlurTint.objectWillChange.sink { blurTintChanges += 1 }

        features.snap.smoke = 0.6
        XCTAssertEqual(snapTintChanges, 1)
        XCTAssertEqual(blurTintChanges, 0)

        features.angleBlurSmoke = 0.7
        XCTAssertEqual(snapTintChanges, 1)
        XCTAssertEqual(blurTintChanges, 1)

        XCTAssertEqual(featureChanges, 0, "tint drags must update their own controls without rebuilding unrelated feature boxes")
        withExtendedLifetime([featureSubscription, snapSubscription, blurSubscription]) { }
    }
}

private final class SilentBudgetOverlay: PrivacyBlurOverlay {
    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {}
    #if DEBUG
    func describe() -> String { "" }
    #endif
    func stop() {}
}
