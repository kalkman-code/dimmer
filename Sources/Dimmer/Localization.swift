import Foundation

enum L10n {
    static let bundle = Bundle.module

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle)
    }

    static func displayUnit(_ unit: String) -> String {
        switch unit {
        case "°": string("Degree unit")
        case "%": string("Percent unit")
        case "ms": string("Milliseconds unit")
        case "°/s": string("Degrees per second unit")
        default: unit
        }
    }
}
