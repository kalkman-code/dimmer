import XCTest
@testable import Dimmer

final class KeyboardTargetLatencyTests: XCTestCase {
    func testOpenLidWobbleDoesNotStartLatencyAndFirstCloseDoes() {
        var metric = KeyboardTargetLatency()
        let range = DimRange.keyboardDefault
        metric.observe(target: range.level(at: 110), readback: 1, time: 0, active: true)
        metric.observe(target: range.level(at: 109), readback: 1, time: 1, active: true)
        XCTAssertNil(metric.pendingAt)
        metric.observe(target: range.level(at: 84), readback: 1, time: 20, active: true)
        XCTAssertEqual(metric.didWrite(target: 0.5, readback: 0.5, time: 20.004)!, 4, accuracy: 0.001)
    }

    func testSubWriteToleranceWobbleDoesNotAccumulateSeconds() {
        var metric = KeyboardTargetLatency()
        metric.observe(target: 0.82, readback: 0.82, time: 0, active: true)
        metric.observe(target: 0.8125, readback: 0.82, time: 1, active: true)
        XCTAssertNil(metric.pendingAt)
        metric.observe(target: 0.84, readback: 0.82, time: 39, active: true)
        XCTAssertEqual(metric.didWrite(target: 0.84, readback: 0.84, time: 39.003)!, 3, accuracy: 0.001)
    }

    func testReturningToTargetOrSuspendingControlClearsPendingLatency() {
        var metric = KeyboardTargetLatency()
        metric.observe(target: 1, readback: 1, time: 0, active: true)
        metric.observe(target: 0.5, readback: 1, time: 1, active: true)
        XCTAssertEqual(metric.pendingAt, 1)
        metric.observe(target: 1, readback: 1, time: 2, active: true)
        XCTAssertNil(metric.pendingAt)
        metric.observe(target: 0.5, readback: 1, time: 3, active: true)
        metric.observe(target: 0.5, readback: 1, time: 4, active: false)
        XCTAssertNil(metric.pendingAt)
    }

    func testReadbackToleranceDoesNotAccumulateLatencyAndWriteAcknowledgesAppliedLevel() {
        var metric = KeyboardTargetLatency()
        _ = metric.didWrite(target: 0.8125, readback: 0.820125, time: 0)
        for time in [1.0, 20, 39] {
            metric.observe(target: 0.821, readback: 0.820125, time: time, active: true)
            XCTAssertNil(metric.pendingAt)
        }
        metric.observe(target: 0.85, readback: 0.820125, time: 40, active: false)
        XCTAssertNil(metric.pendingAt)
        metric.observe(target: 0.85, readback: 0.820125, time: 41, active: true)
        XCTAssertEqual(metric.didWrite(target: 0.832, readback: 0.8319, time: 41.004)!, 4, accuracy: 0.001)
        XCTAssertEqual(metric.appliedTarget, 0.832)
        XCTAssertEqual(metric.readback, 0.8319)
        metric.observe(target: 0.835, readback: 0.8319, time: 42, active: true)
        XCTAssertNil(metric.pendingAt)
    }
}
