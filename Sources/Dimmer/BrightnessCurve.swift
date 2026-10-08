import Foundation

enum BrightnessCurve {
    static func output(angle: Double, offAt: Double, fullAt: Double) -> Double {
        guard fullAt > offAt else { return angle >= fullAt ? 1 : 0 }
        return min(1, max(0, (angle - offAt) / (fullAt - offAt)))
    }
}
