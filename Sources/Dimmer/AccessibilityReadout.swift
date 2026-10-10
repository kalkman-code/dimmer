import Foundation

enum AccessibilityReadout {
    static func value(_ value: Double, unit: String) -> String {
        guard value.isFinite else { return L10n.string("Invalid value") }
        // Catalogue plurals need an integer argument; keep the existing formatted readout for
        // finite values beyond Int64 so converting an accessibility value cannot trap.
        if let count = Int64(exactly: value.rounded(.toNearestOrEven)) {
            switch unit {
            case "°": return L10n.string("\(count) degrees")
            case "°/s": return L10n.string("\(count) degrees per second")
            case "ms": return L10n.string("\(count) milliseconds")
            default: break
            }
        }
        let spokenUnit: String = switch unit {
        case "°": L10n.string("degrees")
        case "°/s": L10n.string("degrees per second")
        case "ms": L10n.string("milliseconds")
        case "%": L10n.string("percent")
        default: unit
        }
        return L10n.string("\(value.formatted(.number.precision(.fractionLength(0)).grouping(.never))) \(spokenUnit)")
    }

    static func range(_ range: ClosedRange<Double>, unit: String) -> String {
        L10n.string("Range \(value(range.lowerBound, unit: unit)) to \(value(range.upperBound, unit: unit)).")
    }

    static func rangeForActivation(_ range: ClosedRange<Double>, unit: String) -> String {
        L10n.string("Range \(value(range.lowerBound, unit: unit)) to \(value(range.upperBound, unit: unit)). Activate to type an exact value.")
    }

    static func rangeForNumberEntry(_ range: ClosedRange<Double>, unit: String) -> String {
        L10n.string("Range \(value(range.lowerBound, unit: unit)) to \(value(range.upperBound, unit: unit)). Return applies. Escape cancels.")
    }
}
