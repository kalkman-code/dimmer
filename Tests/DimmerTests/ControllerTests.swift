import Combine
import XCTest
@testable import Dimmer

@MainActor
final class ControllerTests: XCTestCase {
    func testFirstPartialCloseAfterLaunchAndWakeDimsBothOutputs() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        for _ in 0..<2 {
            devices.keyboard.brightness = 1
            devices.keyboard.automatic = true
            devices.sensor.angle = 110
            _ = try devices.poll(worker, gate: gate, detector: &detector)
            devices.sensor.angle = 84
            let closed = try devices.poll(worker, gate: gate, detector: &detector)
            XCTAssertNil(closed.keyboardStatus)
            XCTAssertLessThan(devices.keyboard.brightness, 1)
            XCTAssertLessThan(devices.display.brightness, 0.6)
            worker.restoreAndClose()
        }
    }

    func testFirstCloseAfterOpeningExactlyToFullBoundaryDimsBothOutputs() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        devices.keyboard.brightness = 1
        devices.sensor.angle = 99
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.sensor.angle = 100
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.sensor.angle = 84
        let closed = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNil(closed.keyboardStatus)
        XCTAssertLessThan(devices.keyboard.brightness, 1)
        XCTAssertLessThan(devices.display.brightness, 0.6)
    }

    func testKeyboardEndpointDoesNotResetScreenFilterWithDifferentRanges() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        let keyboard = DimRange(lowAngle: 68, lowLevel: 0, highAngle: 80, highLevel: 1)
        func poll(_ angle: Double) throws {
            devices.sensor.angle = angle
            _ = try worker.poll(keyboardRange: keyboard, screenRange: .screenDefault,
                                dimsKeyboard: true, dimsScreen: true, darkness: 0,
                                generation: gate.current, gate: gate)
        }
        try poll(110)
        try poll(90)
        try poll(92)
        XCTAssertEqual(devices.keyboard.brightness, 1)
        XCTAssertEqual(devices.display.brightness, 0.6 * DimRange.screenDefault.level(at: 90.7), accuracy: 0.0001)
        try poll(90)
        XCTAssertEqual(devices.display.brightness, 0.6 * DimRange.screenDefault.level(at: 90.455), accuracy: 0.0001)
    }

    func testEndpointWobbleDoesNotRepeatKeyboardOrDisplayWrites() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        var displayWrites = 0
        devices.display.onWrite = { _ in displayWrites += 1 }
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let keyboardWrites = devices.keyboard.writes.count
        for angle in [99.0, 100, 99, 100, 99] {
            devices.sensor.angle = angle
            _ = try devices.poll(worker, gate: gate, detector: &detector)
        }
        XCTAssertEqual(devices.keyboard.writes.count, keyboardWrites)
        XCTAssertEqual(displayWrites, 0)
        devices.sensor.angle = 97
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertLessThan(devices.keyboard.brightness, 1)
        XCTAssertLessThan(devices.display.brightness, 0.6)
        devices.sensor.angle = 68
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let lowKeyboardWrites = devices.keyboard.writes.count
        let lowDisplayWrites = displayWrites
        for angle in [69.0, 68, 69, 68] {
            devices.sensor.angle = angle
            _ = try devices.poll(worker, gate: gate, detector: &detector)
        }
        XCTAssertEqual(devices.keyboard.writes.count, lowKeyboardWrites)
        XCTAssertEqual(displayWrites, lowDisplayWrites)
    }

    func testFirstPartialCloseAfterIdleLeavesKeyboardDarkButDimsScreen() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        devices.keyboard.brightness = 1
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let owned = devices.keyboard.brightness
        devices.keyboard.isIdleDimmed = true
        devices.keyboard.brightness = 0
        for _ in 0..<10 { _ = try devices.poll(worker, gate: gate, detector: &detector) }
        let writes = devices.keyboard.writes.count
        devices.sensor.angle = 80
        let closed = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNil(closed.keyboardStatus)
        XCTAssertEqual(devices.keyboard.brightness, 0)
        XCTAssertEqual(devices.keyboard.writes.count, writes)
        XCTAssertLessThan(devices.display.brightness, 0.6)
        devices.keyboard.isIdleDimmed = false
        devices.keyboard.brightness = owned
        let awake = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNil(awake.keyboardStatus)
        XCTAssertNotNil(awake.written)
        XCTAssertLessThan(devices.keyboard.brightness, 1)
    }

    func testAutomaticModeChangeWhileRunningLatchesOnlyKeyboardUntilResume() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        for _ in 0..<10 { _ = try devices.poll(worker, gate: gate, detector: &detector) }
        devices.keyboard.automatic = true
        XCTAssertNotNil(try devices.poll(worker, gate: gate, detector: &detector).keyboardStatus)
        devices.keyboard.automatic = false
        devices.sensor.angle = 80
        let closed = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNotNil(closed.keyboardStatus)
        XCTAssertNil(closed.written)
        XCTAssertLessThan(devices.display.brightness, 0.6)
        worker.resumeKeyboard()
        let resumed = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNil(resumed.keyboardStatus)
        XCTAssertNotNil(resumed.written)
    }

    func testSensorFailureDuringGoDarkRestoresYieldedKeyboard() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.keyboard.brightness = 0.3
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.keyboard.automatic = true
        _ = try devices.poll(worker, gate: gate, detector: &detector, darkness: 1)
        devices.sensor.fails = true
        XCTAssertThrowsError(try devices.poll(worker, gate: gate, detector: &detector, darkness: 1))
        XCTAssertEqual(devices.keyboard.brightness, 0.3)
        XCTAssertTrue(devices.keyboard.automatic)
        XCTAssertEqual(devices.display.brightness, 0.6)
        devices.sensor.fails = false
        let writes = devices.keyboard.writes.count
        let resumed = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNotNil(resumed.keyboardStatus)
        XCTAssertEqual(devices.keyboard.writes.count, writes)
    }

    func testGoDarkAvailabilityRequiresCurrentSample() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: defaults)
        XCTAssertFalse(controller.canGoDark)
        controller.goDark()
        XCTAssertFalse(controller.isDark)
        controller.simulateLid(angle: 110)
        XCTAssertTrue(controller.canGoDark)
        controller.simulateLid(angle: nil)
        XCTAssertFalse(controller.canGoDark)
    }

    func testSensorlessWakeAppliesQueuedZeroAfterDelayedDisplayWrite() async throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let started = expectation(description: "The first sensorless display write starts")
        let restored = expectation(description: "The queued zero darkness restores the display")
        let release = DispatchSemaphore(value: 0)
        var delayed = false
        var restorationSeen = false
        devices.display.onWrite = { value in
            if !delayed {
                delayed = true
                started.fulfill()
                release.wait()
            }
            if value > 0.59 && !restorationSeen {
                restorationSeen = true
                restored.fulfill()
            }
        }
        defer { release.signal() }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DimmerController(defaults: defaults, hardware: devices.worker())
        defer { controller.stop() }
        controller.simulateSensorAvailability(.unavailable)
        controller.goDark()

        await fulfillment(of: [started], timeout: 3)
        controller.simulateWake()
        try await Task.sleep(nanoseconds: 700_000_000)
        release.signal()
        await fulfillment(of: [restored], timeout: 3)
        XCTAssertEqual(devices.display.brightness, 0.6, accuracy: 0.01)
    }

    func testSensorlessGoDarkDimsDisplayWhenKeyboardFactoryThrows() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        try FileManager.default.createDirectory(at: devices.directory, withIntermediateDirectories: true)
        let worker = HardwareWorker(makeBacklight: { throw NSError(domain: "NoKeyboard", code: 1) },
                                    makeDisplay: { devices.display },
                                    keyboardJournalURL: devices.directory.appendingPathComponent("keyboard.json"),
                                    displayJournalURL: devices.directory.appendingPathComponent("display.json"))
        let gate = PollGeneration()
        try worker.darkTick(darkness: 1, generation: gate.current, gate: gate)
        try worker.darkTick(darkness: 1, generation: gate.current, gate: gate)
        XCTAssertLessThan(devices.display.brightness, 0.6)
    }

    func testGoDarkDoesNotBrightenAnAlreadyDimmedLane() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.sensor.angle = 70
        let dimmed = try devices.poll(worker, gate: gate, detector: &detector)
        let dark = try devices.poll(worker, gate: gate, detector: &detector, darkness: 0.5)
        XCTAssertEqual(dark.brightness, dimmed.brightness * 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(dark.displayBrightness), try XCTUnwrap(dimmed.displayBrightness) * 0.5, accuracy: 0.001)
    }

    func testGoDarkUsesCurrentBrightnessWithBothLanesOffAndRestoresIt() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        devices.sensor.angle = 70
        let half = try devices.poll(worker, gate: gate, detector: &detector, darkness: 0.5,
                                    dimsKeyboard: false, dimsScreen: false)
        XCTAssertEqual(half.brightness, 0.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(half.displayBrightness), 0.3, accuracy: 0.001)
        _ = try devices.poll(worker, gate: gate, detector: &detector, darkness: 1,
                             dimsKeyboard: false, dimsScreen: false)
        XCTAssertEqual(devices.keyboard.brightness, 0)
        XCTAssertEqual(devices.display.brightness, 0)
        _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false, dimsScreen: false)
        XCTAssertEqual(devices.keyboard.brightness, 0.8)
        XCTAssertEqual(devices.display.brightness, 0.6)
    }

    func testGoDarkOverridesYieldThenRestoresUserBrightnessWithoutReclaimingLane() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.keyboard.brightness = 0.3
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let dark = try devices.poll(worker, gate: gate, detector: &detector, darkness: 1)
        XCTAssertEqual(dark.brightness, 0)
        XCTAssertNotNil(dark.keyboardStatus)
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertEqual(devices.keyboard.brightness, 0.3)
        let writes = devices.keyboard.writes.count
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertEqual(devices.keyboard.writes.count, writes)
    }

    func testGoDarkLaneSwitchesDoNotChangeFadeBaseline() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector, darkness: 0.1,
                             dimsKeyboard: false, dimsScreen: false)
        devices.sensor.angle = 70
        let switched = try devices.poll(worker, gate: gate, detector: &detector, darkness: 0.5)
        XCTAssertEqual(switched.brightness, 0.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(switched.displayBrightness), 0.3, accuracy: 0.001)
    }

    func testIdleKeyboardKeepsDisplayAndSamplesAliveThenWakeAppliesLatestLid() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let owned = devices.keyboard.brightness
        let writes = devices.keyboard.writes.count
        devices.keyboard.isIdleDimmed = true
        devices.keyboard.brightness = 0
        devices.sensor.angle = 80
        let idle = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertEqual(idle.sample.angle, 80)
        XCTAssertNil(idle.keyboardStatus)
        XCTAssertEqual(devices.keyboard.writes.count, writes)
        XCTAssertLessThan(try XCTUnwrap(idle.displayBrightness), 0.6)
        devices.keyboard.isIdleDimmed = false
        devices.keyboard.brightness = owned
        let wake = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNil(wake.keyboardStatus)
        XCTAssertEqual(devices.keyboard.brightness, DimRange.keyboardDefault.level(at: 80), accuracy: 0.001)
        devices.keyboard.brightness = 0.2
        let yielded = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNotNil(yielded.keyboardStatus)
        XCTAssertNotNil(yielded.displayBrightness)
        XCTAssertEqual(devices.keyboard.brightness, 0.2)
    }

    func testIdleStopDefersRecoveryUntilNativeWake() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let owned = devices.keyboard.brightness
        devices.keyboard.isIdleDimmed = true
        devices.keyboard.brightness = 0
        let writes = devices.keyboard.writes.count
        worker.restoreAndClose()
        XCTAssertEqual(devices.keyboard.writes.count, writes)
        XCTAssertFalse(try worker.retryKeyboardRecovery())
        devices.keyboard.isIdleDimmed = false
        devices.keyboard.brightness = owned
        XCTAssertTrue(try worker.retryKeyboardRecovery())
        XCTAssertEqual(devices.keyboard.brightness, 0.8)
    }

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
        let subscription = controller.telemetry.$rawSample.compactMap { $0 }.prefix(2).sink { sample in
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

    func testKeyboardYieldRestoresUsersBrightnessAfterAutomaticMode() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        devices.keyboard.automaticAmbientBrightness = 1
        devices.keyboard.automatic = true
        devices.sensor.angle = 70
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let dimmed = devices.keyboard.brightness
        XCTAssertFalse(devices.keyboard.automatic)

        devices.keyboard.brightness = 0.3125
        _ = try devices.poll(worker, gate: gate, detector: &detector)

        XCTAssertTrue(devices.keyboard.automatic)
        XCTAssertEqual(devices.keyboard.brightness, 0.3125, accuracy: 0.001)
        XCTAssertNotEqual(dimmed, 0.3125)
        XCTAssertEqual(devices.keyboard.writes.last, 0.3125)
    }

    func testOwnedKeyboardRestoreLetsAutomaticModeUseAmbientBrightness() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        devices.keyboard.automaticAmbientBrightness = 1
        devices.keyboard.automatic = true
        devices.sensor.angle = 70
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let dimmed = devices.keyboard.brightness
        XCTAssertFalse(devices.keyboard.automatic)

        _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)

        XCTAssertTrue(devices.keyboard.automatic)
        XCTAssertEqual(devices.keyboard.brightness, 1, accuracy: 0.001)
        XCTAssertEqual(devices.keyboard.writes.count, 2)
        XCTAssertEqual(devices.keyboard.writes.last, 0.8)
        XCTAssertNotEqual(devices.keyboard.writes.last, dimmed)
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
        let subscription = controller.telemetry.$rawSample.compactMap { $0 }.prefix(1).sink { _ in resumed.fulfill() }
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
        worker.restoreAndClose(resetKeyboardYield: false)
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.sensor.angle = 80
        let resumed = try devices.poll(worker, gate: gate, detector: &detector, darkness: 1)
        XCTAssertNotNil(resumed.keyboardStatus)
        XCTAssertEqual(resumed.brightness, 0)
        XCTAssertFalse(devices.keyboard.automatic)
        XCTAssertEqual(resumed.displayBrightness, 0)
        worker.restoreAndClose(resetKeyboardYield: false)
        XCTAssertTrue(devices.keyboard.automatic)
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

    func testBrightnessChangedMidCloseSticksThenGlidesBackToTheOpenLevel() {
        let range = DimRange(lowAngle: 0, lowLevel: 0, highAngle: 100, highLevel: 1)
        var logic = DisplayDimmingLogic()
        XCTAssertEqual(logic.update(angle: 100, current: 0.8, range: range), .capture(0.8))
        guard case .dim(let half, _) = logic.update(angle: 50, current: 0.8, range: range) else { return XCTFail() }
        XCTAssertEqual(half, 0.4, accuracy: 0.0001)
        logic.markWritten(half)
        guard case .dim(let kept, let override) = logic.update(angle: 50, current: 0.6, range: range) else { return XCTFail() }
        XCTAssertEqual(kept, 0.6, accuracy: 0.0001)
        XCTAssertTrue(override)
        logic.markWritten(kept)
        guard case .dim(let lower, _) = logic.update(angle: 25, current: 0.6, range: range) else { return XCTFail() }
        XCTAssertEqual(lower, 0.3, accuracy: 0.0001)
        logic.markWritten(lower)
        guard case .dim(let gliding, _) = logic.update(angle: 75, current: 0.3, range: range) else { return XCTFail() }
        XCTAssertEqual(gliding, 0.7, accuracy: 0.0001)
        logic.markWritten(gliding)
        XCTAssertEqual(logic.prepareRestore(), 0.8)
    }

    func testNearShutKeyPressNeverSendsTheOpenLevelToMax() {
        let range = DimRange.screenDefault
        var logic = DisplayDimmingLogic()
        _ = logic.update(angle: 110, current: 0.8125, range: range)
        guard case .dim(let target, _) = logic.update(angle: 71, current: 0.8125, range: range) else { return XCTFail() }
        logic.markWritten(target)
        guard case .dim(let kept, _) = logic.update(angle: 71, current: 0.4375, range: range) else { return XCTFail() }
        XCTAssertEqual(kept, 0.4375, accuracy: 0.0001)
        logic.markWritten(kept)
        guard case .dim(let nearlyOpen, _) = logic.update(angle: 98, current: kept, range: range) else { return XCTFail() }
        XCTAssertLessThanOrEqual(nearlyOpen, 0.8125)
        XCTAssertGreaterThan(nearlyOpen, kept)
        XCTAssertEqual(logic.prepareRestore(), 0.8125)
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

final class TestHardware {
    final class Sensor: LidSensing {
        var angle = 110.0
        var fails = false
        func open() throws {}
        func close() {}
        func readAngleDegrees() throws -> Double {
            if fails { throw NSError(domain: "TestSensor", code: 1) }
            return angle
        }
    }

    final class Keyboard: KeyboardBacklightControlling {
        var isIdleDimmed = false
        var brightness = 0.8
        var automatic = false
        var automaticAmbientBrightness: Double?
        var ignoresWritesWhileIdleDimmed = false
        var writes: [Double] = []
        func read() throws -> (brightness: Double, automatic: Bool) { (brightness, automatic) }
        func write(_ value: Double) throws -> Double {
            writes.append(value)
            if isIdleDimmed && ignoresWritesWhileIdleDimmed { return brightness }
            brightness = value
            return value
        }
        func setAutomatic(_ enabled: Bool) {
            automatic = enabled
            if enabled, let automaticAmbientBrightness { brightness = automaticAmbientBrightness }
        }
    }

    final class Display: DisplayBrightnessControlling {
        var brightness = 0.6
        var onWrite: ((Double) -> Void)?
        var displayID: UInt32 { 0 }
        func read() throws -> Double { brightness }
        func write(_ value: Double) throws -> Double {
            onWrite?(value)
            brightness = min(max(value, 0), 1)
            return brightness
        }
        func setGammaScale(_ factor: Double) throws {}
        func clearCapturedGamma() {}
        func restoreGamma() {}
    }

    let sensor = Sensor()
    let keyboard = Keyboard()
    let display = Display()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var keyboardJournal: RecoveryJournal? { RecoveryJournal.load(from: directory.appendingPathComponent("keyboard.json")) }
    private var sampleTime = 0.0

    func worker() -> HardwareWorker {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return HardwareWorker(makeSensor: { self.sensor }, makeBacklight: { self.keyboard },
                              makeDisplay: { self.display },
                              keyboardJournalURL: directory.appendingPathComponent("keyboard.json"),
                              displayJournalURL: directory.appendingPathComponent("display.json"))
    }

    func poll(_ worker: HardwareWorker, gate: PollGeneration, detector: inout SnapDetector,
              darkness: Double = 0, dimsKeyboard: Bool = true, dimsScreen: Bool = true) throws -> HardwarePoll {
        let result = try worker.poll(keyboardRange: .keyboardDefault, screenRange: .screenDefault,
                                     dimsKeyboard: dimsKeyboard, dimsScreen: dimsScreen, darkness: darkness,
                                     generation: gate.current, gate: gate)
        _ = detector.observe(LidSample(angle: result.sample.angle, time: sampleTime), settings: SnapSettings())
        sampleTime += 0.1
        return result
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
