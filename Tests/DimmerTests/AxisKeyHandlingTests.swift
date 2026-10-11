import SwiftUI
import XCTest
@testable import Dimmer

@MainActor
final class AxisKeyHandlingTests: XCTestCase {
    func testHorizontalArrowsOnStrengthNumbersMoveAnglesAndEachNumberHasItsOwnUndoBurst() throws {
        for lane in [AxisLane.keyboard, .screen, .blur] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
            let controller = DimmerController(defaults: defaults)
            let features = DimmerFeatures(defaults: defaults)
            defer { features.stop() }
            let history = SettingsHistory(controller: controller, features: features)
            let view = LidAxisView(lane: lane, controller: controller, features: features, history: history)
            let handle = lane.handles[0]
            let angleField = AxisField.angle(handle), levelField = AxisField.level(handle)
            view.moveCommand(.right, field: angleField)
            view.moveCommand(.right, field: angleField)
            view.moveCommand(.right, field: levelField)
            view.moveCommand(.left, field: levelField)
            view.moveCommand(.right, field: levelField)
            func lowAngle() -> Double {
                switch lane {
                case .keyboard: controller.keyboardRange.lowAngle
                case .screen: controller.screenRange.lowAngle
                case .blur: features.angleBlurRange.lowAngle
                case .privacy: features.snap.zoneLow
                }
            }
            let finalAngle = lowAngle()
            history.undo()
            XCTAssertEqual(lowAngle(), finalAngle - 1, "\(lane): changing focused number starts another step")
            XCTAssertTrue(history.canUndo)
            history.undo()
            XCTAssertEqual(lowAngle(), finalAngle - 3)
            XCTAssertFalse(history.canUndo)
        }
    }

    // Calls the same move-command entry point the focused number cell registers, including its dispatch
    // by field, rather than the range maths below it. No window or hardware brightness is involved.
    func testVerticalArrowsOnEachBarsAngleAndStrengthNumbers() throws {
        for lane in AxisLane.allCases {
            for handle in lane.handles {
                let fields: [AxisField] = handle.isZone ? [.angle(handle)] : [.angle(handle), .level(handle)]
                for field in fields {
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
                    let controller = DimmerController(defaults: defaults)
                    let features = DimmerFeatures(defaults: defaults)
                    defer { features.stop() }
                    let range = DimRange(lowAngle: 40, lowLevel: 0.5, highAngle: 90, highLevel: 0.5)
                    controller.keyboardRange = range
                    controller.screenRange = range
                    features.angleBlurRange = range
                    features.snap.blurStrength = 0.5
                    features.privacyVeilBlurStrength = 0.3
                    let beforeSnap = features.snap
                    let history = SettingsHistory(controller: controller, features: features)
                    let view = LidAxisView(lane: lane, controller: controller, features: features, history: history)
                    func strength() -> Double {
                        let current: DimRange
                        switch lane {
                        case .keyboard: current = controller.keyboardRange
                        case .screen: current = controller.screenRange
                        case .blur: current = features.angleBlurRange
                        case .privacy: return features.snap.blurStrength
                        }
                        return handle.isLow ? current.lowLevel : current.highLevel
                    }
                    view.moveCommand(.up, field: field)
                    XCTAssertEqual(strength(), 0.55, accuracy: 1e-9, "\(field): up changes strength")
                    if lane == .privacy {
                        XCTAssertEqual(features.privacyVeilBlurStrength, 0.3, accuracy: 1e-9,
                                       "Snap zone arrows must leave Privacy veil strength unchanged")
                        XCTAssertEqual(history.undoManager.undoActionName, L10n.string("Snap blur strength"))
                    }
                    view.moveCommand(.down, field: field)
                    view.moveCommand(.down, field: field)
                    XCTAssertEqual(strength(), 0.45, accuracy: 1e-9, "\(field): down changes strength")
                    if lane == .privacy {
                        XCTAssertEqual(features.privacyVeilBlurStrength, 0.3, accuracy: 1e-9)
                    }
                    XCTAssertEqual(features.snap.zoneLow, beforeSnap.zoneLow)
                    XCTAssertEqual(features.snap.zoneHigh, beforeSnap.zoneHigh)
                    history.undo()
                    XCTAssertEqual(strength(), 0.5, accuracy: 1e-9)
                    XCTAssertFalse(history.canUndo, "\(field): held keys form one step")
                    history.redo()
                    XCTAssertEqual(strength(), 0.45, accuracy: 1e-9)
                    XCTAssertEqual(controller.keyboardRange.lowAngle, 40)
                    XCTAssertEqual(controller.screenRange.highAngle, 90)
                    XCTAssertEqual(features.angleBlurRange.highAngle, 90)
                }
            }
        }
    }
}
