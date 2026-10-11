import XCTest
@testable import Dimmer

@MainActor
final class PauseTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)

    private func makeController(_ devices: TestHardware) throws -> DimmerController {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return DimmerController(defaults: defaults, hardware: devices.worker(), now: { [unowned self] in clock })
    }

    func testTimedPauseRecordsItsResumeTimeAndPlainPauseDoesNot() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = try makeController(devices)
        defer { controller.stop() }
        controller.pause(for: .fifteenMinutes)
        XCTAssertTrue(controller.paused)
        XCTAssertEqual(controller.resumeAt, clock.addingTimeInterval(900))
        controller.togglePaused()
        controller.pause(for: .oneHour)
        XCTAssertEqual(controller.resumeAt, clock.addingTimeInterval(3_600))
        controller.togglePaused()
        controller.togglePaused()
        XCTAssertTrue(controller.paused)
        XCTAssertNil(controller.resumeAt)
    }

    func testExpiryResumesOnceAndClearsTheSchedule() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = try makeController(devices)
        defer { controller.stop() }
        controller.pause(for: .fifteenMinutes)
        clock.addTimeInterval(899)
        XCTAssertFalse(controller.resumeIfPauseExpired())
        XCTAssertTrue(controller.paused)
        clock.addTimeInterval(1)
        XCTAssertTrue(controller.resumeIfPauseExpired())
        XCTAssertFalse(controller.paused)
        XCTAssertNil(controller.resumeAt)
        XCTAssertFalse(controller.resumeIfPauseExpired())
    }

    func testExpiredScheduleCannotEndALaterPause() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = try makeController(devices)
        defer { controller.stop() }
        controller.pause(for: .fifteenMinutes)
        controller.togglePaused()
        clock.addTimeInterval(100)
        controller.pause(for: .oneHour)
        let hourEnd = clock.addingTimeInterval(3_600)
        clock.addTimeInterval(800)
        XCTAssertFalse(controller.resumeIfPauseExpired(), "the first pause's deadline has passed, the second's has not")
        XCTAssertTrue(controller.paused)
        XCTAssertEqual(controller.resumeAt, hourEnd)

        controller.togglePaused()
        controller.togglePaused()
        clock.addTimeInterval(10_000)
        XCTAssertFalse(controller.resumeIfPauseExpired(), "an open-ended pause has no deadline to expire")
        XCTAssertTrue(controller.paused)
    }

    func testTimerFiringEarlyKeepsTheScheduleAndAStaleTimerDoesNothing() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = try makeController(devices)
        defer { controller.stop() }
        controller.pause(for: .fifteenMinutes)
        let token = try XCTUnwrap(controller.pauseToken)
        clock.addTimeInterval(899.9)
        controller.pauseTimerFired(token: token)
        XCTAssertTrue(controller.paused)
        XCTAssertEqual(controller.pauseToken, token)
        clock.addTimeInterval(0.1)
        controller.pauseTimerFired(token: UUID())
        XCTAssertTrue(controller.paused, "a timer from another schedule must not end this pause")
        controller.pauseTimerFired(token: token)
        XCTAssertFalse(controller.paused)
        XCTAssertNil(controller.pauseToken)
        controller.pauseTimerFired(token: token)
        XCTAssertFalse(controller.paused)
    }

    func testSleepAcrossTheDeadlineResumesOnWake() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = try makeController(devices)
        defer { controller.stop() }
        controller.pause(for: .fifteenMinutes)
        controller.prepareForSleep()
        XCTAssertNotNil(controller.resumeAt)
        clock.addTimeInterval(901)
        controller.resumeAfterWake()
        XCTAssertFalse(controller.paused)
        XCTAssertNil(controller.resumeAt)
        controller.resumeAfterWake()
        XCTAssertFalse(controller.paused)
    }

    func testSleepBeforeTheDeadlineStaysPausedWithTheSameResumeTime() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = try makeController(devices)
        defer { controller.stop() }
        controller.pause(for: .oneHour)
        let deadline = controller.resumeAt
        controller.prepareForSleep()
        clock.addTimeInterval(600)
        controller.resumeAfterWake()
        XCTAssertTrue(controller.paused)
        XCTAssertEqual(controller.resumeAt, deadline)
    }

    func testPausingWhileAlreadyPausedKeepsTheCurrentPause() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = try makeController(devices)
        defer { controller.stop() }
        controller.togglePaused()
        controller.pause(for: .fifteenMinutes)
        XCTAssertTrue(controller.paused)
        XCTAssertNil(controller.resumeAt)
    }

    func testPausingAndResumingLeavesKeepAwakeAlone() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = try makeController(devices)
        defer { controller.stop() }
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let features = DimmerFeatures(defaults: defaults, overlay: SilentOverlay())
        defer { features.stop() }
        features.setAwakeDuration(.oneHour)
        let deadline = features.awakeDeadline
        XCTAssertNotNil(deadline)
        controller.pause(for: .fifteenMinutes)
        features.suspend(reason: "pause")
        XCTAssertEqual(features.awakeDuration, .oneHour)
        XCTAssertEqual(features.awakeDeadline, deadline)
        clock.addTimeInterval(900)
        XCTAssertTrue(controller.resumeIfPauseExpired())
        XCTAssertEqual(features.awakeDuration, .oneHour)
        XCTAssertEqual(features.awakeDeadline, deadline)
    }
    // A timer that fired just before sleep queues its main-actor task; if that runs during sleep preparation it
    // must not restart polling. The deadline is honoured on wake instead.
    func testAnExpiryQueuedBeforeSleepDoesNotResumeUntilWake() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = try makeController(devices)
        defer { controller.stop() }
        controller.pause(for: .fifteenMinutes)
        let token = try XCTUnwrap(controller.pauseToken)
        clock.addTimeInterval(901)
        controller.prepareForSleep()
        controller.pauseTimerFired(token: token)
        XCTAssertTrue(controller.paused, "the queued expiry ran during sleep preparation")
        controller.resumeAfterWake()
        XCTAssertFalse(controller.paused)
    }
}

@MainActor
private final class SilentOverlay: PrivacyBlurOverlay {
    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {}
    func describe() -> String { "silent overlay" }
    func stop() {}
}
