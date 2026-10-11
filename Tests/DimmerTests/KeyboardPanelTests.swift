import XCTest
@testable import Dimmer

@MainActor
final class KeyboardPanelTests: XCTestCase {
    private func dimmedAt70(_ devices: TestHardware, automatic: Bool = false) throws -> (HardwareWorker, PollGeneration, Double) {
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        devices.keyboard.automatic = automatic
        devices.sensor.angle = 70
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        let dimmed = devices.keyboard.brightness
        XCTAssertLessThan(dimmed, 0.8)
        XCTAssertFalse(devices.keyboard.automatic)
        return (worker, gate, dimmed)
    }

    func testQuitWhileIdleDimmedRestoresOriginalBrightnessAndAutomaticMode() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let (worker, _, _) = try dimmedAt70(devices, automatic: true)
        devices.keyboard.isIdleDimmed = true
        devices.keyboard.brightness = 0
        worker.restoreAndClose(finalQuit: true)
        XCTAssertEqual(devices.keyboard.brightness, 0.8, accuracy: 0.001)
        XCTAssertTrue(devices.keyboard.automatic)
        XCTAssertNil(devices.keyboardJournal)
    }

    func testQuitKeepsTheJournalWhenTheHardwareIgnoresTheIdleWriteThenRecoversOnWake() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let (worker, _, dimmed) = try dimmedAt70(devices)
        devices.keyboard.isIdleDimmed = true
        devices.keyboard.ignoresWritesWhileIdleDimmed = true
        devices.keyboard.brightness = 0
        worker.restoreAndClose(finalQuit: true)
        XCTAssertEqual(devices.keyboard.brightness, 0)
        XCTAssertNotNil(devices.keyboardJournal)

        let relaunched = devices.worker()
        devices.keyboard.isIdleDimmed = false
        devices.keyboard.brightness = dimmed
        XCTAssertTrue(try relaunched.retryKeyboardRecovery())
        XCTAssertEqual(devices.keyboard.brightness, 0.8, accuracy: 0.001)
        XCTAssertNil(devices.keyboardJournal)
    }

    func testPauseAndSleepStillDeferWhileIdleDimmed() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let (worker, _, _) = try dimmedAt70(devices)
        devices.keyboard.isIdleDimmed = true
        devices.keyboard.brightness = 0
        let writes = devices.keyboard.writes.count
        worker.restoreAndClose()
        worker.restoreAndClose(resetKeyboardYield: false)
        XCTAssertEqual(devices.keyboard.writes.count, writes)
        XCTAssertNotNil(devices.keyboardJournal)
    }

    // Pause leaves the journal on disk while macOS holds the keyboard dark, and the paused app may reopen
    // the backlight to retry; Quit must still restore from that on-disk journal.
    func testPauseWhileIdleDimmedThenQuitRestoresFromTheStaleJournal() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let (worker, _, dimmed) = try dimmedAt70(devices, automatic: true)
        devices.keyboard.isIdleDimmed = true
        devices.keyboard.brightness = 0
        worker.restoreAndClose()
        XCTAssertNotNil(devices.keyboardJournal)
        XCTAssertFalse(try worker.retryKeyboardRecovery(), "still idle-dimmed, so the retry waits")
        XCTAssertNotNil(devices.keyboardJournal)
        _ = dimmed
        worker.restoreAndClose(finalQuit: true)
        XCTAssertEqual(devices.keyboard.brightness, 0.8, accuracy: 0.001)
        XCTAssertTrue(devices.keyboard.automatic)
        XCTAssertNil(devices.keyboardJournal)
    }

    func testControllerStopIsTheFinalQuit() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let (worker, _, _) = try dimmedAt70(devices)
        devices.keyboard.isIdleDimmed = true
        devices.keyboard.brightness = 0
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        DimmerController(defaults: defaults, hardware: worker).stop()
        XCTAssertEqual(devices.keyboard.brightness, 0.8, accuracy: 0.001)
        XCTAssertNil(devices.keyboardJournal)
    }

    private func yielded(_ devices: TestHardware, to level: Double, automatic: Bool = false) throws
        -> (HardwareWorker, PollGeneration, SnapDetector) {
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.keyboard.brightness = level
        devices.keyboard.automatic = automatic
        let result = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNotNil(result.keyboardStatus)
        return (worker, gate, detector)
    }

    func testResumeKeyboardCapturesTheLatestBrightnessAndAutomaticMode() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        var (worker, gate, detector) = try yielded(devices, to: 0.3, automatic: true)
        devices.keyboard.brightness = 0.5
        worker.resumeKeyboard()
        let resumed = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNil(resumed.keyboardStatus)
        let journal = try XCTUnwrap(devices.keyboardJournal)
        XCTAssertEqual(journal.originalBrightness, 0.5, accuracy: 0.001)
        XCTAssertTrue(journal.originalAutomatic)
        XCTAssertFalse(devices.keyboard.automatic)
        XCTAssertEqual(devices.keyboard.brightness, DimRange.keyboardDefault.level(at: 110), accuracy: 0.001)
        worker.restoreAndClose()
        XCTAssertEqual(devices.keyboard.brightness, 0.5, accuracy: 0.001)
        XCTAssertTrue(devices.keyboard.automatic)
    }

    func testResumeWhileIdleDimmedWaitsForTheNativeWakeLevel() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        var (worker, gate, detector) = try yielded(devices, to: 0.3)
        devices.keyboard.isIdleDimmed = true
        devices.keyboard.brightness = 0
        worker.resumeKeyboard()
        let writes = devices.keyboard.writes.count
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertEqual(devices.keyboard.writes.count, writes)
        XCTAssertNil(devices.keyboardJournal)

        devices.keyboard.isIdleDimmed = false
        devices.keyboard.brightness = 0.3
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNil(devices.keyboardJournal, "macOS gets half a second to settle the wake level")
        Thread.sleep(forTimeInterval: 0.6)
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertEqual(try XCTUnwrap(devices.keyboardJournal).originalBrightness, 0.3, accuracy: 0.001)
    }

    func testNothingReclaimsTheKeyboardUntilResumeIsChosen() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        var (worker, gate, detector) = try yielded(devices, to: 0.3)
        let writes = devices.keyboard.writes.count
        for angle in [110.0, 80, 70, 110] {
            devices.sensor.angle = angle
            let result = try devices.poll(worker, gate: gate, detector: &detector)
            XCTAssertNotNil(result.keyboardStatus)
        }
        XCTAssertEqual(devices.keyboard.writes.count, writes)
        XCTAssertEqual(devices.keyboard.brightness, 0.3)
    }

    func testResumeKeyboardLeavesScreenDimmingRunning() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        var (worker, gate, detector) = try yielded(devices, to: 0.3)
        worker.resumeKeyboard()
        devices.sensor.angle = 70
        var result = try devices.poll(worker, gate: gate, detector: &detector)
        for _ in 0..<12 { result = try devices.poll(worker, gate: gate, detector: &detector) }
        XCTAssertLessThan(devices.display.brightness, 0.6)
        XCTAssertEqual(try XCTUnwrap(result.displayBrightness), devices.display.brightness, accuracy: 0.001)
        XCTAssertLessThan(devices.keyboard.brightness, 0.8)
    }

    func testControllerOffersResumeOnlyWhileYieldedRunningAndNotDark() async throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.keyboard.brightness = 0.3
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: defaults, hardware: worker)
        defer { controller.stop() }
        XCTAssertFalse(controller.canResumeKeyboard)

        let offered = expectation(description: "The yield reaches the panel")
        let subscription = controller.keyboardYieldedPublisher.filter { $0 }.prefix(1).sink { _ in offered.fulfill() }
        defer { subscription.cancel() }
        controller.start()
        await fulfillment(of: [offered], timeout: 3)
        XCTAssertTrue(controller.canResumeKeyboard)

        controller.togglePaused()
        XCTAssertFalse(controller.keyboardYielded)
        XCTAssertFalse(controller.canResumeKeyboard)
        controller.togglePaused()

        let again = expectation(description: "A fresh poll after Resume")
        again.assertForOverFulfill = false
        let after = controller.telemetry.$rawSample.compactMap { $0 }.dropFirst().prefix(1).sink { _ in again.fulfill() }
        defer { after.cancel() }
        await fulfillment(of: [again], timeout: 3)
        XCTAssertFalse(controller.canResumeKeyboard, "Pause and Resume hands the keyboard back, so nothing is left to resume")
    }

    func testResumeKeyboardButtonPathClearsTheYieldAndTheStaleStatus() async throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: defaults, hardware: worker)
        defer { controller.stop() }
        let started = expectation(description: "First poll")
        let first = controller.telemetry.$rawSample.compactMap { $0 }.prefix(1).sink { _ in started.fulfill() }
        defer { first.cancel() }
        controller.start()
        await fulfillment(of: [started], timeout: 3)
        devices.keyboard.brightness = 0.3
        let offered = expectation(description: "Yield shown")
        let yieldSubscription = controller.keyboardYieldedPublisher.filter { $0 }.prefix(1).sink { _ in offered.fulfill() }
        defer { yieldSubscription.cancel() }
        await fulfillment(of: [offered], timeout: 3)

        controller.resumeKeyboard()
        XCTAssertFalse(controller.keyboardYielded)
        XCTAssertEqual(controller.errorMessage, "Active")
        let settled = expectation(description: "Dimmer controls the keyboard again")
        let level = DimRange.keyboardDefault.level(at: 110)
        let brightness = controller.telemetry.$keyboardBrightness.compactMap { $0 }.filter { abs($0 - level) < 0.001 }.prefix(1)
            .sink { _ in settled.fulfill() }
        defer { brightness.cancel() }
        await fulfillment(of: [settled], timeout: 3)
        XCTAssertFalse(controller.keyboardYielded)
        XCTAssertEqual(controller.errorMessage, "Active")
    }
}
