import Combine
import Observation
import XCTest
@testable import Dimmer

@MainActor
final class ControllerSinkTests: XCTestCase {
    private func pump() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testPausedPublisherContract() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = DimmerController(defaults: defaults, hardware: devices.worker())
        defer { controller.stop() }

        var published: [Bool] = []
        var observedOnController: [Bool] = []
        let sub = controller.pausedPublisher.sink { value in
            published.append(value)
            observedOnController.append(controller.paused)
        }
        defer { sub.cancel() }

        XCTAssertEqual(published, [false])
        XCTAssertEqual(observedOnController, [false])

        controller.togglePaused()
        XCTAssertEqual(published, [false, true])
        XCTAssertEqual(observedOnController, [false, false])
        XCTAssertTrue(controller.paused)

        controller.togglePaused()
        XCTAssertEqual(published, [false, true, false])
        XCTAssertEqual(observedOnController, [false, false, true])
        XCTAssertFalse(controller.paused)
    }

    func testIsDarkPublisherContract() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = DimmerController(defaults: defaults, hardware: devices.worker())
        defer { controller.stop() }
        controller.simulateLid(angle: 110)

        var published: [Bool] = []
        var observedOnController: [Bool] = []
        let sub = controller.isDarkPublisher.sink { value in
            published.append(value)
            observedOnController.append(controller.isDark)
        }
        defer { sub.cancel() }

        XCTAssertEqual(published, [false])
        XCTAssertEqual(observedOnController, [false])

        controller.goDark()
        XCTAssertEqual(published, [false, true])
        XCTAssertEqual(observedOnController, [false, false])
        XCTAssertTrue(controller.isDark)

        controller.simulateWake()
        XCTAssertEqual(published, [false, true, false])
        XCTAssertEqual(observedOnController, [false, false, true])
        XCTAssertFalse(controller.isDark)
    }

    func testKeyboardYieldedPublisherContract() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector)
        devices.keyboard.brightness = 0.3
        let yieldedPoll = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertNotNil(yieldedPoll.keyboardStatus)

        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: defaults, hardware: worker)
        defer { controller.stop() }

        var published: [Bool] = []
        var observedOnController: [Bool] = []
        let sub = controller.keyboardYieldedPublisher.sink { value in
            published.append(value)
            observedOnController.append(controller.keyboardYielded)
        }
        defer { sub.cancel() }

        XCTAssertEqual(published, [false])
        XCTAssertEqual(observedOnController, [false])

        controller.simulatePoll(yieldedPoll)
        XCTAssertEqual(published, [false, true])
        XCTAssertEqual(observedOnController, [false, false])
        XCTAssertTrue(controller.keyboardYielded)

        controller.resumeKeyboard()
        XCTAssertEqual(published, [false, true, false])
        XCTAssertEqual(observedOnController, [false, false, true])
        XCTAssertFalse(controller.keyboardYielded)
    }

    func testScreenStatusPublisherContract() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()

        devices.sensor.angle = 70
        let waiting = try devices.poll(worker, gate: gate, detector: &detector)
        XCTAssertEqual(ScreenStatus.from(waiting.displayStatus), .waitingForLid)

        devices.sensor.angle = 110
        var ready = try devices.poll(worker, gate: gate, detector: &detector)
        for _ in 0..<12 { ready = try devices.poll(worker, gate: gate, detector: &detector) }
        XCTAssertEqual(ScreenStatus.from(ready.displayStatus), .ready)

        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: defaults, hardware: worker)
        defer { controller.stop() }

        var published: [ScreenStatus] = []
        var observedOnController: [ScreenStatus] = []
        let sub = controller.screenStatusPublisher.sink { value in
            published.append(value)
            observedOnController.append(controller.screenStatus)
        }
        defer { sub.cancel() }

        XCTAssertEqual(published, [.ready])
        XCTAssertEqual(observedOnController, [.ready])

        controller.simulatePoll(waiting)
        XCTAssertEqual(published, [.ready, .waitingForLid])
        XCTAssertEqual(observedOnController, [.ready, .ready])
        XCTAssertEqual(controller.screenStatus, .waitingForLid)

        controller.simulatePoll(ready)
        XCTAssertEqual(published, [.ready, .waitingForLid, .ready])
        XCTAssertEqual(observedOnController, [.ready, .ready, .waitingForLid])
        XCTAssertEqual(controller.screenStatus, .ready)
    }

    func testPrivacyVeilEnabledPublisherContract() throws {
        let suite = "ControllerSinkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "privacyVeilEnabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = DimmerFeatures(defaults: defaults, overlay: SilentOverlay())
        defer { features.stop() }

        var published: [Bool] = []
        var observedBeforeStore: [Bool] = []
        let subscription = features.privacyVeilEnabledPublisher.sink { value in
            published.append(value)
            observedBeforeStore.append(features.privacyVeilEnabled)
        }
        defer { subscription.cancel() }

        XCTAssertEqual(published, [false], "subscription starts with the persisted switch value")
        XCTAssertEqual(observedBeforeStore, [false])

        features.privacyVeilEnabled = false
        XCTAssertEqual(published, [false, false], "equal assignments retain @Published delivery semantics")
        XCTAssertEqual(observedBeforeStore, [false, false])

        features.privacyVeilEnabled = true
        XCTAssertEqual(published, [false, false, true])
        XCTAssertEqual(observedBeforeStore, [false, false, false], "the sink fires before the property stores the new value")
        XCTAssertTrue(features.privacyVeilEnabled)
        XCTAssertEqual(defaults.bool(forKey: "privacyVeilEnabled"), true)

        features.privacyVeilEnabled = true
        XCTAssertEqual(published, [false, false, true, true], "an equal true assignment still publishes")
        XCTAssertEqual(observedBeforeStore, [false, false, false, true])
    }

    // The panel's Go dark button reads canGoDark. The sample behind it is not observed, so the button must still
    // hear the first sample arrive, or it stays disabled.
    func testGoDarkAvailabilityIsObserved() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = DimmerController(defaults: defaults, hardware: devices.worker())
        defer { controller.stop() }

        let changeFlag = ObservationChangeFlag()
        withObservationTracking { _ = controller.canGoDark } onChange: {
            MainActor.assumeIsolated { changeFlag.changed = true }
        }
        XCTAssertFalse(controller.canGoDark)
        controller.simulateLid(angle: 110)
        XCTAssertTrue(changeFlag.changed)
        XCTAssertTrue(controller.canGoDark)
    }

    func testPausedToFeaturesSink() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = DimmerController(defaults: defaults, hardware: devices.worker())
        defer { controller.stop() }
        let features = DimmerFeatures(defaults: defaults, overlay: SilentOverlay())
        defer { features.stop() }
        features.privacyEnabled = true

        let subs = features.follow(controller)
        defer { subs.forEach { $0.cancel() } }

        for (i, angle) in [110.0, 110.0, 95.0, 80.0].enumerated() {
            features.update(sample: LidSample(angle: angle, time: 10 + Double(i) / 10))
        }
        XCTAssertTrue(features.privacyBlurActive)

        controller.togglePaused()
        await pump()

        XCTAssertFalse(features.privacyBlurActive)
        features.setLidAngle(85)
        XCTAssertNil(features.lidAngle)

        controller.togglePaused()
        await pump()

        features.setLidAngle(85)
        XCTAssertEqual(features.lidAngle, 85)
    }

    func testIsDarkToFeaturesSink() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = DimmerController(defaults: defaults, hardware: devices.worker())
        defer { controller.stop() }
        let features = DimmerFeatures(defaults: defaults, overlay: SilentOverlay())
        defer { features.stop() }

        let subs = features.follow(controller)
        defer { subs.forEach { $0.cancel() } }

        controller.simulateLid(angle: 110)
        features.setLidAngle(110)
        XCTAssertEqual(features.lidAngle, 110)

        controller.goDark()
        await pump()

        XCTAssertNil(features.lidAngle)
        features.setLidAngle(100)
        XCTAssertNil(features.lidAngle)

        controller.simulateWake()
        await pump()

        features.setLidAngle(100)
        XCTAssertEqual(features.lidAngle, 100)
    }

    func testTelemetryAngleToFeaturesSink() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = DimmerController(defaults: defaults, hardware: devices.worker())
        defer { controller.stop() }
        let features = DimmerFeatures(defaults: defaults, overlay: SilentOverlay())
        defer { features.stop() }

        let subs = features.follow(controller)
        defer { subs.forEach { $0.cancel() } }

        controller.simulateLid(angle: 75)
        await pump()
        XCTAssertEqual(features.lidAngle, 75)

        controller.simulateLid(angle: nil)
        await pump()
        XCTAssertNil(features.lidAngle)
    }

    func testTelemetryRawSampleToFeaturesSink() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let controller = DimmerController(defaults: defaults, hardware: devices.worker())
        defer { controller.stop() }
        let features = DimmerFeatures(defaults: defaults, overlay: SilentOverlay())
        defer { features.stop() }
        features.privacyEnabled = true

        let subs = features.follow(controller)
        defer { subs.forEach { $0.cancel() } }

        var time = 10.0
        for angle in [110.0, 110.0, 95.0, 80.0] {
            controller.simulatePoll((sample: LidSample(angle: angle, time: time),
                                     angle: angle,
                                     brightness: 0.8,
                                     written: nil,
                                     displayBrightness: 0.8,
                                     displayStatus: "Screen dimming will retry shortly.",
                                     keyboardStatus: nil))
            await pump()
            time += 0.1
        }

        XCTAssertTrue(features.privacyBlurActive)
    }
}

@MainActor
private final class SilentOverlay: PrivacyBlurOverlay {
    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {}
    func describe() -> String { "silent overlay" }
    func stop() {}
}

@MainActor
private final class ObservationChangeFlag {
    var changed = false
}
