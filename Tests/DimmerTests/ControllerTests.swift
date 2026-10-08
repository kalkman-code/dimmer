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
}
