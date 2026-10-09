import Foundation

enum AccessibilityReadout {
    static func value(_ value: Double, unit: String) -> String {
        guard value.isFinite else { return "Invalid value" }
        let spokenUnit: String = switch unit {
        case "°": "degrees"
        case "°/s": "degrees per second"
        case "ms": "milliseconds"
        case "%": "percent"
        default: unit
        }
        return "\(value.formatted(.number.precision(.fractionLength(0)).grouping(.never))) \(spokenUnit)"
    }

    static func range(_ range: ClosedRange<Double>, unit: String) -> String {
        "Range \(value(range.lowerBound, unit: unit)) to \(value(range.upperBound, unit: unit))."
    }
}
