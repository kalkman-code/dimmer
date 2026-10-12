import XCTest
@testable import Dimmer

@MainActor
private final class SensorlessOverlay: PrivacyBlurOverlay {
    private(set) var isVisible = false
    private(set) var strength = 0.0

    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {
        isVisible = privacyBlur
        self.strength = strength
    }

    #if DEBUG
    func describe() -> String { isVisible ? "visible" : "hidden" }
    #endif

    func stop() { isVisible = false; strength = 0 }
}

@MainActor
final class SensorlessTests: XCTestCase {
    private final class ScriptedSensor: LidSensing {
        var openError: Error?
        var readErrors: [Error] = []
        var angle = 110.0

        func open() throws {
            if let openError { throw openError }
        }

        func close() {}

        func readAngleDegrees() throws -> Double {
            if !readErrors.isEmpty { throw readErrors.removeFirst() }
            return angle
        }
    }

    private func hardware(sensor: ScriptedSensor, devices: TestHardware) -> HardwareWorker {
        try! FileManager.default.createDirectory(at: devices.directory, withIntermediateDirectories: true)
        return HardwareWorker(makeSensor: { sensor }, makeBacklight: { devices.keyboard },
                              makeDisplay: { devices.display },
                              keyboardJournalURL: devices.directory.appendingPathComponent("keyboard.json"),
                              displayJournalURL: devices.directory.appendingPathComponent("display.json"))
    }

    func testForcedSensorlessStartSchedulesNoLidPollAndAllowsGoDark() throws {
        let suite = "SensorlessController-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = DimmerController(defaults: defaults, forceSensorless: true)
        defer { controller.stop(); defaults.removePersistentDomain(forName: suite) }

        controller.start()

        XCTAssertEqual(controller.lidSensorState, .unavailable)
        XCTAssertFalse(controller.sensorPollTimerScheduled)
        XCTAssertTrue(controller.canGoDark)
    }

    func testProbeReadFailureRetriesThenStartsPolling() async throws {
        let suite = "SensorProbeRetry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sensor = ScriptedSensor()
        let devices = TestHardware()
        defer { devices.cleanUp() }
        sensor.readErrors = [SensorError.readFailed(-1)]
        let controller = DimmerController(defaults: defaults,
                                           hardware: hardware(sensor: sensor, devices: devices))
        defer { controller.stop() }

        controller.start()
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertEqual(controller.lidSensorState, .available)
        XCTAssertTrue(controller.sensorPollTimerScheduled)
        XCTAssertNotEqual(controller.errorMessage,
                          L10n.string("No readable lid sensor. Privacy veil, Go dark and Keep awake are available."))
    }

    func testProbeFailingPastFiveTriesNeverReportsSensorless() async throws {
        let suite = "SensorProbeSlowWake-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sensor = ScriptedSensor()
        let devices = TestHardware()
        defer { devices.cleanUp() }
        sensor.readErrors = Array(repeating: SensorError.readFailed(-1), count: 5)
        let controller = DimmerController(defaults: defaults,
                                           hardware: hardware(sensor: sensor, devices: devices))
        defer { controller.stop() }

        controller.start()
        try await Task.sleep(nanoseconds: 9_500_000_000)

        XCTAssertTrue(sensor.readErrors.isEmpty)
        XCTAssertNotEqual(controller.lidSensorState, .unavailable)
        XCTAssertFalse(controller.sensorPollTimerScheduled)
        XCTAssertNotEqual(controller.errorMessage,
                          L10n.string("No readable lid sensor. Privacy veil, Go dark and Keep awake are available."))
    }

    func testProbeUnavailableUsesSensorlessModeWithoutPolling() async throws {
        let suite = "SensorProbeAbsent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sensor = ScriptedSensor()
        sensor.openError = SensorError.unavailable
        let controller = DimmerController(defaults: defaults,
                                           hardware: HardwareWorker(makeSensor: { sensor }))
        defer { controller.stop() }

        controller.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.lidSensorState, .unavailable)
        XCTAssertFalse(controller.sensorPollTimerScheduled)
    }

    func testMidRunReadFailureKeepsPollTimerAndRecovers() async throws {
        let suite = "SensorPollRetry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sensor = ScriptedSensor()
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = DimmerController(defaults: defaults,
                                           hardware: hardware(sensor: sensor, devices: devices))
        defer { controller.stop() }

        controller.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        sensor.readErrors = [SensorError.readFailed(-1)]
        controller.pollForTesting()
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(controller.lidSensorState, .available)
        XCTAssertTrue(controller.sensorPollTimerScheduled)

        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertEqual(controller.lidSensorState, .available)
        XCTAssertTrue(controller.sensorPollTimerScheduled)
        XCTAssertTrue(controller.hasLidAngle)
    }

    func testSensorlessDarkTimerWaitsForRestorationThenStops() async throws {
        let suite = "SensorlessDarkRestore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = DimmerController(defaults: defaults, hardware: devices.worker())
        defer { controller.stop() }
        controller.simulateSensorAvailability(.unavailable)
        controller.goDark()
        try await Task.sleep(nanoseconds: 700_000_000)
        devices.keyboard.isIdleDimmed = true
        controller.simulateWake()
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(controller.darknessForTesting, 0)
        XCTAssertTrue(controller.darkTimerScheduledForTesting)

        devices.keyboard.isIdleDimmed = false
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertFalse(controller.darkTimerScheduledForTesting)
    }

    func testPrivacyShortcutShowsVeilWithoutALidAngle() throws {
        let suite = "SensorlessPrivacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let overlay = SensorlessOverlay()
        let features = DimmerFeatures(defaults: defaults, overlay: overlay,
                                      lastInput: { (100, "keyboard") }, uptime: { 101 })
        defer { features.stop(); defaults.removePersistentDomain(forName: suite) }

        features.activatePrivacyBlurFromShortcut(at: 101, angle: nil)

        XCTAssertTrue(features.privacyBlurActive)
        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(overlay.strength, features.privacyVeilBlurStrength, accuracy: 1e-9)
    }
}
