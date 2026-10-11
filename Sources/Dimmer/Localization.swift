import Foundation

enum L10n {
    #if DEBUG
    // Tests set this to lay the real views out in each translation inside one process; release builds omit it.
    nonisolated(unsafe) static var testLanguage: String?
    #else
    static let testLanguage: String? = nil
    #endif

    static var bundle: Bundle {
        if let language = testLanguage, let path = Bundle.module.path(forResource: language, ofType: "lproj"), let table = Bundle(path: path) {
            return table
        }
        return Bundle.module
    }

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle, locale: testLanguage.map(Locale.init(identifier:)) ?? .current)
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
