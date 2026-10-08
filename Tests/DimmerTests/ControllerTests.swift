import XCTest
@testable import Dimmer

@MainActor
final class ControllerTests: XCTestCase {
    private var saved: [String: Any] = [:]

    override func setUp() async throws {
        for key in ["offAt", "fullAt"] { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() async throws {
        for key in ["offAt", "fullAt"] {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    // A pre-release build crashed with a stack overflow on any slider move: the didSet reassigned the
    // @Published value unconditionally, which re-entered didSet forever.
    func testSliderValuesSettleAndPersist() {
        let controller = DimmerController()
        controller.fullAt = 85
        controller.offAt = 40
        XCTAssertEqual(controller.offAt, 40)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "offAt"), 40)
        controller.fullAt = 100
        XCTAssertEqual(controller.fullAt, 100)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "fullAt"), 100)
    }

    func testOutOfRangeValuesAreClamped() {
        let controller = DimmerController()
        controller.fullAt = 85
        controller.offAt = 120
        XCTAssertEqual(controller.offAt, 84)
        controller.offAt = -10
        XCTAssertEqual(controller.offAt, 0)
        controller.fullAt = 500
        XCTAssertEqual(controller.fullAt, 140)
        controller.offAt = 60
        controller.fullAt = 10
        XCTAssertEqual(controller.fullAt, 61)
    }

    func testBrightnessCurve() {
        XCTAssertEqual(BrightnessCurve.output(angle: 30, offAt: 30, fullAt: 85), 0)
        XCTAssertEqual(BrightnessCurve.output(angle: 85, offAt: 30, fullAt: 85), 1)
        XCTAssertEqual(BrightnessCurve.output(angle: 57.5, offAt: 30, fullAt: 85), 0.5, accuracy: 0.0001)
    }

    func testDisplayTargetScalesCapturedBrightnessAndNeverExceedsIt() {
        XCTAssertEqual(DisplayBrightnessTarget.value(captured: 0.72, factor: 0), 0)
        XCTAssertEqual(DisplayBrightnessTarget.value(captured: 0.72, factor: 0.5), 0.36, accuracy: 0.0001)
        XCTAssertEqual(DisplayBrightnessTarget.value(captured: 0.72, factor: 1), 0.72)
        XCTAssertEqual(DisplayBrightnessTarget.value(captured: 0.72, factor: 2), 0.72)
    }

    func testDisplayBrightnessOwnershipAllowsSmallReadbackDriftOnly() {
        XCTAssertTrue(DisplayBrightnessTarget.owns(current: 0.401, lastWritten: 0.4))
        XCTAssertFalse(DisplayBrightnessTarget.owns(current: 0.45, lastWritten: 0.4))
    }

    func testDisplayBaselineWaitsForOpenAndNeverUsesClosedOrDimmedReadback() {
        var logic = DisplayDimmingLogic()
        XCTAssertEqual(logic.update(angle: 66, current: 0.2, offAt: 66, fullAt: 99), .waitForOpen)
        XCTAssertNil(logic.baseline)

        XCTAssertEqual(logic.update(angle: 99, current: 0.5, offAt: 66, fullAt: 99), .capture(0.5))
        guard case .dim(let target, _) = logic.update(angle: 66.8, current: 0.5, offAt: 66, fullAt: 99) else {
            return XCTFail("Expected the saved baseline to drive the closed target")
        }
        logic.markWritten(target)
        guard case .dim(let targetAfterOutsideChange, let override) = logic.update(angle: 66.8, current: 0.0626, offAt: 66, fullAt: 99) else {
            return XCTFail("Expected Dimmer to keep enforcing the target")
        }
        XCTAssertTrue(override)
        XCTAssertEqual(targetAfterOutsideChange, target, accuracy: 0.0001)
        XCTAssertEqual(logic.baseline, 0.5)
    }

    func testLoggedYieldSequenceReopensByRestoringOriginalBaseline() {
        var logic = DisplayDimmingLogic()
        XCTAssertEqual(logic.update(angle: 99, current: 0.5, offAt: 66, fullAt: 99), .capture(0.5))
        guard case .dim(let target, _) = logic.update(angle: 66.8, current: 0.5, offAt: 66, fullAt: 99) else {
            return XCTFail("Expected dimming after the lid closes")
        }
        logic.markWritten(target)
        guard case .dim(_, let override) = logic.update(angle: 66.8, current: 0.0626, offAt: 66, fullAt: 99) else {
            return XCTFail("Expected the outside adjustment to be overridden")
        }
        XCTAssertTrue(override)
        // Reopening: HardwareWorker hands back prepareRestore()'s baseline before any new capture.
        XCTAssertTrue(logic.isDimming)
        XCTAssertEqual(logic.prepareRestore(), 0.5)
        XCTAssertFalse(logic.isDimming)
        XCTAssertEqual(logic.baseline, 0.5)
        XCTAssertEqual(logic.update(angle: 99, current: 0.55, offAt: 66, fullAt: 99), .capture(0.55))
        XCTAssertEqual(logic.baseline, 0.55)
    }

    func testGammaFadeIsOneAboveZoneZeroAtOffAtAndMonotonic() {
        let offAt = 66.0
        let fullAt = 99.0
        XCTAssertEqual(DisplayGammaFade.factor(angle: 73, offAt: offAt, fullAt: fullAt), 1)
        XCTAssertEqual(DisplayGammaFade.factor(angle: offAt, offAt: offAt, fullAt: fullAt), 0)
        XCTAssertEqual(DisplayGammaFade.factor(angle: 60, offAt: offAt, fullAt: fullAt), 0)
        let values = stride(from: offAt, through: 73, by: 0.5).map {
            DisplayGammaFade.factor(angle: $0, offAt: offAt, fullAt: fullAt)
        }
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
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
