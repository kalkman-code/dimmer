import XCTest
@testable import Dimmer

final class PrivacyShortcutTests: XCTestCase {
    func testPressDoesNotActivateUntilReleaseAndReleaseIsConsumedOnce() {
        var trigger = PrivacyShortcutTrigger()
        XCTAssertFalse(trigger.receive(isKeyDown: true, allowed: true))
        XCTAssertFalse(trigger.receive(isKeyDown: true, allowed: true))
        XCTAssertTrue(trigger.receive(isKeyDown: false, allowed: true))
        XCTAssertFalse(trigger.receive(isKeyDown: false, allowed: true))
    }

    func testCancelledAndDisallowedPressCannotActivateLater() {
        var trigger = PrivacyShortcutTrigger()
        XCTAssertFalse(trigger.receive(isKeyDown: true, allowed: true))
        trigger.cancel()
        XCTAssertFalse(trigger.receive(isKeyDown: false, allowed: true))
        XCTAssertFalse(trigger.receive(isKeyDown: true, allowed: false))
        XCTAssertFalse(trigger.receive(isKeyDown: false, allowed: true))
        XCTAssertFalse(trigger.receive(isKeyDown: true, allowed: true))
        XCTAssertFalse(trigger.receive(isKeyDown: false, allowed: false))
        XCTAssertFalse(trigger.receive(isKeyDown: false, allowed: true))
    }

    func testTriggerPressIsExcludedButSubsequentTypingClearsWithoutSnapGrace() {
        let activation = 100.0
        XCTAssertFalse(SnapDetector.inputArrived(idleSeconds: 0.2, now: 100.1, blurredAt: activation, grace: 0))
        XCTAssertTrue(SnapDetector.inputArrived(idleSeconds: 0.05, now: 100.1, blurredAt: activation, grace: 0))
        XCTAssertFalse(SnapDetector.inputArrived(idleSeconds: 0.05, now: 100.1, blurredAt: activation))
    }

    func testManualBlurAboveSnapZoneWaitsForAnUpwardLidMovement() {
        var lift = ManualPrivacyLift(angle: 110)
        XCTAssertFalse(lift.shouldClear(at: 110))
        XCTAssertFalse(lift.shouldClear(at: 108))
        XCTAssertFalse(lift.shouldClear(at: 110))
        XCTAssertTrue(lift.shouldClear(at: 111))
    }

    func testManualBlurWithNoSensorEstablishesItsFirstAngleAsBaseline() {
        var lift = ManualPrivacyLift(angle: nil)
        XCTAssertFalse(lift.shouldClear(at: 115))
        XCTAssertFalse(lift.shouldClear(at: 117))
        XCTAssertTrue(lift.shouldClear(at: 118))
    }
}
