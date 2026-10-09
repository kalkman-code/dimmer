import Combine
import XCTest
@testable import Dimmer

@MainActor
final class ControllerTests: XCTestCase {
    func testKeyboardYieldKeepsScreenDimmingAndSnapSamples() async throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.keyboard.brightness = 0.3
        devices.sensor.angle = 100
        let keyboardWrites = devices.keyboard.writes.count
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: defaults, hardware: worker)
        defer { controller.stop() }
        let samples = expectation(description: "The timer publishes the yield and a later lid sample")
        samples.expectedFulfillmentCount = 2
        var sampleCount = 0
        var screenAtYield = 0.0
        var snapVerdict = SnapDetector.Veil.none
        let subscription = controller.$rawSample.compactMap { $0 }.prefix(2).sink { sample in
            sampleCount += 1
            snapVerdict = detector.observe(LidSample(angle: sample.angle, time: Double(sampleCount) / 10),
                                          settings: SnapSettings())
            if sampleCount == 1 {
                screenAtYield = devices.display.brightness
                devices.sensor.angle = 80
            }
            samples.fulfill()
        }
        defer { subscription.cancel() }
        controller.start()
        await fulfillment(of: [samples], timeout: 3)
        XCTAssertLessThan(devices.display.brightness, screenAtYield)
        XCTAssertEqual(controller.keyboardBrightness, 0.3)
        XCTAssertEqual(controller.errorMessage,
                       "Keyboard brightness changed outside Dimmer; control paused to respect it.")
        XCTAssertEqual(devices.keyboard.writes.count, keyboardWrites)
        XCTAssertEqual(snapVerdict, .snapped)
    }

    func testPauseThenResumeReclaimsYieldedKeyboard() async throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.keyboard.brightness = 0.3
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: defaults, hardware: worker)
        defer { controller.stop() }
        let resumed = expectation(description: "A resumed poll publishes a lid sample")
        let subscription = controller.$rawSample.compactMap { $0 }.prefix(1).sink { _ in resumed.fulfill() }
        defer { subscription.cancel() }
        controller.togglePaused()
        controller.togglePaused()
        await fulfillment(of: [resumed], timeout: 3)
        XCTAssertEqual(controller.errorMessage, "Active")
        XCTAssertEqual(controller.keyboardBrightness, 1)
        XCTAssertEqual(devices.keyboard.brightness, 1)
    }

    func testSleepKeepsYieldedKeyboardPausedWhileScreenPollingResumes() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.keyboard.automatic = true
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let keyboardWrites = devices.keyboard.writes.count
        worker.restoreAndClose(resetKeyboardYield: false)
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.sensor.angle = 80
        let resumed = try devices.poll(worker, gate: gate, detector: &detector, darkness: 1)
        XCTAssertNotNil(resumed.keyboardStatus)
        XCTAssertEqual(devices.keyboard.writes.count, keyboardWrites)
        XCTAssertTrue(devices.keyboard.automatic)
        XCTAssertEqual(resumed.displayBrightness, 0)
    }

    func testDimRangeLevelsAtAndBetweenEndpoints() {
        let range = DimRange(lowAngle: 30, lowLevel: 0.1, highAngle: 80, highLevel: 0.9)
        XCTAssertEqual(range.level(at: 20), 0.1)
        XCTAssertEqual(range.level(at: 30), 0.1)
        XCTAssertEqual(range.level(at: 55), 0.5, accuracy: 0.0001)
        XCTAssertEqual(range.level(at: 80), 0.9)
        XCTAssertEqual(range.level(at: 100), 0.9)
    }

    func testSettingLowPushesHighAndClampsAtBothAxisEnds() {
        let range = DimRange(lowAngle: 40, lowLevel: 0, highAngle: 75, highLevel: 0.71)
        let pushed = range.settingLow(angle: 90, level: 0.4, maximum: 130)
        XCTAssertEqual(pushed.lowAngle, 90)
        XCTAssertEqual(pushed.highAngle, 91)
        let atMaximum = range.settingLow(angle: 130, level: 0.4, maximum: 130)
        XCTAssertEqual(atMaximum.lowAngle, 129)
        XCTAssertEqual(atMaximum.highAngle, 130)
        let atZero = range.settingLow(angle: -20, level: -1, maximum: 130)
        XCTAssertEqual(atZero.lowAngle, 0)
        XCTAssertEqual(atZero.lowLevel, 0)
    }

    func testSettingHighPushesLowAndClampsAtBothAxisEnds() {
        let range = DimRange.keyboardDefault
        let pushed = range.settingHigh(angle: 20, level: 1.5, maximum: 130)
        XCTAssertEqual(pushed.lowAngle, 19)
        XCTAssertEqual(pushed.highAngle, 20)
        let atZero = range.settingHigh(angle: 0, level: 0.4, maximum: 130)
        XCTAssertEqual(atZero.lowAngle, 0)
        XCTAssertEqual(atZero.highAngle, 1)
        let atMaximum = range.settingHigh(angle: 500, level: 0.4, maximum: 130)
        XCTAssertEqual(atMaximum.highAngle, 130)
        XCTAssertEqual(atMaximum.highLevel, 0.4)
    }

    func testLegacyRangesMigrateForBothControls() throws {
        let name = UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        suite.set(40.0, forKey: "offAt")
        suite.set(95.0, forKey: "fullAt")
        let controller = DimmerController(defaults: suite)
        let expected = DimRange(lowAngle: 40, lowLevel: 0, highAngle: 95, highLevel: 1)
        XCTAssertEqual(controller.keyboardRange, expected)
        XCTAssertEqual(controller.screenRange, expected)
        XCTAssertNotNil(suite.data(forKey: "keyboardRange"))
        XCTAssertNotNil(suite.data(forKey: "screenRange"))
    }

    func testRangesDefaultWhenLegacyValuesAreAbsentAndPersistAsJSON() throws {
        let name = UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: suite)
        // Toby's settings of 08-10-2026 evening.
        XCTAssertEqual(controller.keyboardRange, DimRange(lowAngle: 68, lowLevel: 0, highAngle: 100, highLevel: 1))
        XCTAssertEqual(controller.screenRange, DimRange(lowAngle: 68, lowLevel: 0, highAngle: 100, highLevel: 1))
        let snap = SnapSettings()
        XCTAssertEqual([snap.zoneLow, snap.zoneHigh, snap.snapDegrees, snap.minimumSpeed, snap.blurStrength,
                        snap.smoke, snap.clearSeconds], [68, 99, 5, 60, 1, 0, 0.08])
        let changed = DimRange(lowAngle: 20, lowLevel: 0.1, highAngle: 90, highLevel: 0.8)
        controller.keyboardRange = changed
        XCTAssertEqual(try JSONDecoder().decode(DimRange.self, from: XCTUnwrap(suite.data(forKey: "keyboardRange"))), changed)
    }

    func testKeyboardDimmingDefaultsOnAndPersists() throws {
        let name = UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: suite)
        XCTAssertTrue(controller.dimsKeyboard)
        controller.dimsKeyboard = false
        XCTAssertFalse(suite.bool(forKey: "dimsKeyboard"))
    }

    func testMovingScreenRangeBelowZonePreservesLevelsAndClampsAtZero() {
        let range = DimRange(lowAngle: 40, lowLevel: 0.2, highAngle: 80, highLevel: 0.9)
        XCTAssertEqual(range.movedBelow(70), DimRange(lowAngle: 30, lowLevel: 0.2, highAngle: 70, highLevel: 0.9))
        XCTAssertEqual(range.movedBelow(20), DimRange(lowAngle: 0, lowLevel: 0.2, highAngle: 20, highLevel: 0.9))
        XCTAssertEqual(range.movedBelow(1), DimRange(lowAngle: 0, lowLevel: 0.2, highAngle: 2, highLevel: 0.9))
    }

    func testDisplayTargetScalesCapturedBrightnessAndNeverExceedsIt() {
        XCTAssertEqual(DisplayBrightnessTarget.value(captured: 0.72, factor: 0), 0)
        XCTAssertEqual(DisplayBrightnessTarget.value(captured: 0.72, factor: 0.5), 0.36, accuracy: 0.0001)
        XCTAssertEqual(DisplayBrightnessTarget.value(captured: 0.72, factor: 1), 0.72)
        XCTAssertEqual(DisplayBrightnessTarget.value(captured: 0.72, factor: 2), 0.72)
    }

    func testDisplayBaselineWaitsForOpenAndUsesIndependentRange() {
        let range = DimRange(lowAngle: 66, lowLevel: 0, highAngle: 99, highLevel: 1)
        var logic = DisplayDimmingLogic()
        XCTAssertEqual(logic.update(angle: 66, current: 0.2, range: range), .waitForOpen)
        XCTAssertNil(logic.baseline)
        XCTAssertEqual(logic.update(angle: 99, current: 0.5, range: range), .capture(0.5))
        guard case .dim(let target, _) = logic.update(angle: 66.8, current: 0.5, range: range) else {
            return XCTFail("Expected the saved baseline to drive the screen target")
        }
        XCTAssertEqual(target, 0.0121, accuracy: 0.001)
    }

    func testDisplayGammaFadeReturnsOneForNonzeroLowLevel() {
        let range = DimRange(lowAngle: 30, lowLevel: 0.2, highAngle: 85, highLevel: 1)
        XCTAssertEqual(DisplayGammaFade.factor(angle: 30, range: range), 1)
        XCTAssertEqual(DisplayGammaFade.factor(angle: 10, range: range), 1)
    }

    func testDisplayGammaFadeIsSmoothForBlackToFullRange() {
        let range = DimRange(lowAngle: 66, lowLevel: 0, highAngle: 99, highLevel: 1)
        XCTAssertEqual(DisplayGammaFade.factor(angle: 73, range: range), 1)
        XCTAssertEqual(DisplayGammaFade.factor(angle: 66, range: range), 0)
        XCTAssertEqual(DisplayGammaFade.factor(angle: 60, range: range), 0)
        let values = stride(from: 66.0, through: 73, by: 0.5).map { DisplayGammaFade.factor(angle: $0, range: range) }
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testRampPlannerRespectsCapAndEndsExactlyAtTarget() {
        let values = DisplayRampPlanner.values(from: 0.1, to: 0.83, maximumStep: 0.04)
        XCTAssertEqual(values.last, 0.83)
        XCTAssertTrue(zip([0.1] + values, values).allSatisfy { abs($1 - $0) <= 0.04 + 0.000_000_1 })
    }

    func testRampPlannerIsMonotonicInEitherDirection() {
        let rising = DisplayRampPlanner.values(from: 0.2, to: 0.9, maximumStep: 0.08)
        let falling = DisplayRampPlanner.values(from: 0.9, to: 0.2, maximumStep: 0.08)
        XCTAssertTrue(zip(rising, rising.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertTrue(zip(falling, falling.dropFirst()).allSatisfy { $0 >= $1 })
    }

    func testBlackToFullGammaRampHasAtLeastTwelveSteps() {
        let values = DisplayRampPlanner.values(from: 0, to: 1, maximumStep: 0.08)
        XCTAssertGreaterThanOrEqual(values.count, 12)
        XCTAssertEqual(values.last, 1)
    }
}

private final class TestHardware {
    final class Sensor: LidSensing {
        var angle = 110.0
        func open() throws {}
        func close() {}
        func readAngleDegrees() throws -> Double { angle }
    }

    final class Keyboard: KeyboardBacklightControlling {
        var brightness = 0.8
        var automatic = false
        var writes: [Double] = []
        func read() throws -> (brightness: Double, automatic: Bool) { (brightness, automatic) }
        func write(_ value: Double) throws -> Double {
            writes.append(value)
            brightness = value
            return value
        }
        func setAutomatic(_ enabled: Bool) { automatic = enabled }
    }

    final class Display: DisplayBrightnessControlling {
        var brightness = 0.6
        var displayID: UInt32 { 0 }
        func read() throws -> Double { brightness }
        func write(_ value: Double) throws -> Double { brightness = value; return value }
        func setGammaScale(_ factor: Double) throws {}
        func clearCapturedGamma() {}
        func restoreGamma() {}
    }

    let sensor = Sensor()
    let keyboard = Keyboard()
    let display = Display()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var sampleTime = 0.0

    func worker() -> HardwareWorker {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return HardwareWorker(makeSensor: { self.sensor }, makeBacklight: { self.keyboard },
                              makeDisplay: { self.display },
                              keyboardJournalURL: directory.appendingPathComponent("keyboard.json"),
                              displayJournalURL: directory.appendingPathComponent("display.json"))
    }

    func poll(_ worker: HardwareWorker, gate: PollGeneration, detector: inout SnapDetector,
              darkness: Double = 0) throws -> HardwarePoll {
        let result = try worker.poll(keyboardRange: .keyboardDefault, screenRange: .screenDefault,
                                     dimsKeyboard: true, dimsScreen: true, darkness: darkness,
                                     generation: gate.current, gate: gate)
        _ = detector.observe(LidSample(angle: result.sample.angle, time: sampleTime), settings: SnapSettings())
        sampleTime += 0.1
        return result
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
