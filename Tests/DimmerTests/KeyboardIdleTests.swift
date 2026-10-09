import XCTest
@testable import Dimmer

final class KeyboardIdleTests: XCTestCase {
    func testAwakeKeyboardOwnershipRejectsOneBrightnessKeyStep() {
        var logic = KeyboardIdleLogic()
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.42, automatic: false,
                                    lastWritten: 0.42, now: 0), .apply)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.4375, automatic: false,
                                    lastWritten: 0.42, now: 1), .yield)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.42, automatic: false,
                                    lastWritten: 0.42, now: 2), .apply)
    }

    func testRecoveryJournalDoesNotOwnOneBrightnessKeyStepAway() {
        let journal = RecoveryJournal(originalBrightness: 0.7, originalAutomatic: false,
                                      lastWritten: 0.42)
        XCTAssertFalse(journal.owns(0.4375))
    }

    func testWakeAcceptsEitherSideOfAnInterruptedPendingWrite() {
        for restored in [0.4, 0.7] {
            var logic = KeyboardIdleLogic()
            _ = logic.update(idleDimmed: true, current: 0, automatic: false, lastWritten: 0.4,
                             pendingBrightness: 0.7, now: 0)
            XCTAssertEqual(logic.update(idleDimmed: false, current: restored, automatic: false,
                                        lastWritten: 0.4, pendingBrightness: 0.7, now: 10), .apply)
        }
    }

    func testFirstStaleRecoveryReadWaitsForNativeWakeBeforeRelinquishingOwnership() {
        var logic = KeyboardIdleLogic()
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0, automatic: false,
                                    lastWritten: 0.7, now: 10), .wait)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.7, automatic: false,
                                    lastWritten: 0.7, now: 10.1), .apply)
    }
    func testRestorationRetainsIdleRecoveryRegardlessOfApparentOwnership() {
        XCTAssertEqual(KeyboardIdleLogic.restoration(idleDimmed: true, ownsBrightness: true), .wait)
        XCTAssertEqual(KeyboardIdleLogic.restoration(idleDimmed: true, ownsBrightness: false), .wait)
        XCTAssertEqual(KeyboardIdleLogic.restoration(idleDimmed: false, ownsBrightness: true), .apply)
        XCTAssertEqual(KeyboardIdleLogic.restoration(idleDimmed: false, ownsBrightness: false), .yield)
    }
    func testIdleNeverYieldsOrAppliesEvenIfBrightnessAndAutomaticModeChange() {
        var logic = KeyboardIdleLogic()
        XCTAssertEqual(logic.update(idleDimmed: true, current: 0, automatic: true, lastWritten: 0.7, now: 0), .wait)
        XCTAssertEqual(logic.update(idleDimmed: true, current: 0, automatic: false, lastWritten: 0.7, now: 30), .wait)
    }

    func testWakeWaitsForNativeRestoreThenAppliesLatestLidTarget() {
        var logic = KeyboardIdleLogic()
        _ = logic.update(idleDimmed: true, current: 0, automatic: false, lastWritten: 0.7, now: 0)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0, automatic: false, lastWritten: 0.7, now: 10), .wait)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.7, automatic: false, lastWritten: 0.7, now: 10.1), .apply)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.3, automatic: false, lastWritten: 0.7, now: 10.2), .yield)
    }

    func testManualChangeWakingFromIdleIsRespectedAfterBoundedNativeRestoreWindow() {
        var logic = KeyboardIdleLogic()
        _ = logic.update(idleDimmed: true, current: 0, automatic: false, lastWritten: 0.7, now: 0)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.4, automatic: false, lastWritten: 0.7, now: 10), .wait)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.4, automatic: false, lastWritten: 0.7, now: 10.6), .yield)
    }

    func testFreshIdleLaunchDoesNotCaptureZeroAndOrdinaryUserChangesStillYield() {
        var logic = KeyboardIdleLogic()
        XCTAssertEqual(logic.update(idleDimmed: true, current: 0, automatic: false, lastWritten: nil, now: 0), .wait)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.5, automatic: true, lastWritten: nil, now: 10), .wait)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.5, automatic: true, lastWritten: nil, now: 10.6), .apply)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.4, automatic: false, lastWritten: 0.7, now: 11), .yield)
        XCTAssertEqual(logic.update(idleDimmed: false, current: 0.7, automatic: true, lastWritten: 0.7, now: 12), .yield)
    }
}
