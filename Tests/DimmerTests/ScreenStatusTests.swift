import Combine
import XCTest
@testable import Dimmer

@MainActor
final class ScreenStatusTests: XCTestCase {
    func testEveryWorkerMessageHasAStableExplanation() throws {
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

        devices.sensor.angle = 70
        var active = try devices.poll(worker, gate: gate, detector: &detector)
        for _ in 0..<12 { active = try devices.poll(worker, gate: gate, detector: &detector) }
        XCTAssertEqual(ScreenStatus.from(active.displayStatus), .active)

        let off = try devices.poll(worker, gate: gate, detector: &detector, dimsScreen: false)
        XCTAssertEqual(ScreenStatus.from(off.displayStatus), .off)

        let failing = HardwareWorker(makeSensor: { devices.sensor }, makeBacklight: { devices.keyboard },
                                     makeDisplay: { throw DisplayBrightnessError.controlsUnavailable },
                                     keyboardJournalURL: devices.directory.appendingPathComponent("k2.json"),
                                     displayJournalURL: devices.directory.appendingPathComponent("d2.json"))
        let unavailable = try devices.poll(failing, gate: gate, detector: &detector)
        XCTAssertEqual(ScreenStatus.from(unavailable.displayStatus), .unavailable)
        XCTAssertNil(unavailable.displayBrightness)
    }

    func testEveryNonRoutineStateExplainsItselfAndRoutineOnesStaySilent() {
        XCTAssertNil(ScreenStatus.ready.explanation)
        XCTAssertNil(ScreenStatus.active.explanation)
        for status in [ScreenStatus.off, .waitingForLid, .restoring, .retrying, .unavailable] {
            let text = try? XCTUnwrap(status.explanation)
            XCTAssertFalse(text?.isEmpty ?? true, "\(status)")
            XCTAssertEqual(status.explanation, status.explanation)
        }
        XCTAssertEqual(ScreenStatus.from(L10n.string("Display brightness restoration is retrying.")), .restoring)
        XCTAssertEqual(ScreenStatus.from(L10n.string("Screen dimming will retry shortly.")), .retrying)
        XCTAssertEqual(ScreenStatus.from(L10n.string("Dimmer leaves automatic brightness unchanged.")), .ready)
        XCTAssertEqual(ScreenStatus.retrying.explanation, ScreenStatus.unavailable.explanation,
                       "a retry loop must not flip the sentence every two seconds")
        XCTAssertEqual(ScreenStatus.from("Display brightness could not be read (-1)."), .unavailable)
    }

    func testControllerDoesNotRepublishAnUnchangedStatus() async throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DimmerController(defaults: defaults, hardware: devices.worker())
        defer { controller.stop() }
        var published: [ScreenStatus] = []
        let statusSubscription = controller.$screenStatus.sink { published.append($0) }
        defer { statusSubscription.cancel() }
        let polls = expectation(description: "Several polls complete")
        let sampleSubscription = controller.telemetry.$rawSample.compactMap { $0 }.prefix(5).sink(receiveCompletion: { _ in polls.fulfill() }, receiveValue: { _ in })
        defer { sampleSubscription.cancel() }
        controller.start()
        await fulfillment(of: [polls], timeout: 5)
        XCTAssertEqual(published, [.ready])
    }
}
