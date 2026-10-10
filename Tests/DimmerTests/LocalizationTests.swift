import XCTest
@testable import Dimmer

final class LocalizationTests: XCTestCase {
    func testEnglishStringsResolveFromPackageBundle() {
        XCTAssertNotNil(L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en-GB.lproj"))
        XCTAssertEqual(L10n.string("Starting…"), "Starting…")
        XCTAssertEqual(L10n.string("Uninstall Dimmer"), "Uninstall Dimmer")
        XCTAssertEqual(L10n.string("Version \("1.2") · Build \("3")"), "Version 1.2 · Build 3")
        XCTAssertEqual(L10n.displayUnit("°"), "°")
        XCTAssertEqual(L10n.displayUnit("%"), "%")
        XCTAssertEqual(L10n.displayUnit("ms"), "ms")
        XCTAssertEqual(L10n.displayUnit("°/s"), "°/s")
        XCTAssertEqual(L10n.string("Unavailable readout"), "—")
    }

    func testRecentlyAddedVisibleStringsHaveCatalogueEntries() throws {
        let keys = [
            "15 minutes", "1 hour", "2 hours", "5 hours", "Could not enable Launch at Login: %@",
            "Could not disable Launch at Login: %@", "130°", "100%", "0%", "%lld°",
            "Range %@ to %@. Activate to type an exact value.",
            "Range %@ to %@. Return applies. Escape cancels.", "Degree unit", "Percent unit",
            "Milliseconds unit", "Degrees per second unit", "Unavailable readout",
            "Dimming keeps running. Open Dimmer from Applications or Spotlight to bring Settings back, where Show in menu bar puts the icon back.",
            "How long the veil takes to fade once it clears.",
            "Screen and privacy control continue. Pause and resume to reconnect the keyboard."
        ]
        let stringsURL = try XCTUnwrap(L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en-GB.lproj"))
        let stringsData = try Data(contentsOf: stringsURL)
        let compiled = try XCTUnwrap(PropertyListSerialization.propertyList(from: stringsData, format: nil) as? [String: String])
        for key in keys { XCTAssertNotNil(compiled[key], "Missing catalogue key: \(key)") }
        XCTAssertEqual(compiled["Degree unit"], "°")
        XCTAssertEqual(compiled["Percent unit"], "%")
        XCTAssertEqual(compiled["Milliseconds unit"], "ms")
        XCTAssertEqual(compiled["Degrees per second unit"], "°/s")
        XCTAssertEqual(compiled["Unavailable readout"], "—")
    }

    func testCompiledPackageTableMatchesCatalogueKeys() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogueURL = root.appending(path: "Sources/Dimmer/Resources/Localizable.xcstrings")
        let catalogue = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogueURL)) as! [String: Any]
        let sourceKeys = Set((catalogue["strings"] as! [String: Any]).keys)

        let stringsURL = try XCTUnwrap(L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en-GB.lproj"))
        let stringsData = try Data(contentsOf: stringsURL)
        let compiled = try XCTUnwrap(PropertyListSerialization.propertyList(from: stringsData, format: nil) as? [String: String])
        let pluralURL = try XCTUnwrap(L10n.bundle.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: "en-GB.lproj"))
        let plurals = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: pluralURL), format: nil) as? [String: Any])
        XCTAssertEqual(Set(compiled.keys).union(plurals.keys), sourceKeys)
    }

    private let languages = ["en-GB", "es", "pt-BR", "de", "fr", "ja"]

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func units(in node: [String: Any]) -> [[String: String]] {
        if let unit = node["stringUnit"] as? [String: String] { return [unit] }
        return node.values.compactMap { $0 as? [String: Any] }.flatMap { units(in: $0) }
    }

    private func arguments(in value: String) throws -> [Int: String] {
        let pattern = #"%(?:(\d+)\$)?[-+ #0']*(?:\d+)?(?:\.\d+)?(hh|ll|h|l|L|z|j|t)?([@diuoxXfFeEgGaAcCsSp%])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let text = value as NSString
        var next = 1
        var result: [Int: String] = [:]
        for match in regex.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            let type = text.substring(with: match.range(at: 3))
            if type == "%" { continue }
            let positionRange = match.range(at: 1)
            let position = positionRange.location == NSNotFound ? next : Int(text.substring(with: positionRange))!
            next += 1
            let lengthRange = match.range(at: 2)
            let length = lengthRange.location == NSNotFound ? "" : text.substring(with: lengthRange)
            let signature = length + type
            if let existing = result[position] { XCTAssertEqual(existing, signature) }
            result[position] = signature
        }
        return result
    }

    func testEveryKeyHasReviewedTranslationsWithMatchingFormatArguments() throws {
        let catalogue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "Sources/Dimmer/Resources/Localizable.xcstrings"))) as? [String: Any])
        XCTAssertEqual(catalogue["sourceLanguage"] as? String, "en-GB")
        let entries = try XCTUnwrap(catalogue["strings"] as? [String: [String: Any]])
        for (key, entry) in entries {
            let translations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
            let english = units(in: try XCTUnwrap(translations["en-GB"], key))
            let expected = try arguments(in: XCTUnwrap(english.first?["value"], key))
            for language in languages {
                let localisation = try XCTUnwrap(translations[language], "\(language): \(key)")
                let values = units(in: localisation)
                XCTAssertFalse(values.isEmpty, "\(language): \(key)")
                for unit in values {
                    XCTAssertEqual(unit["state"], "translated", "\(language): \(key)")
                    let value = try XCTUnwrap(unit["value"], "\(language): \(key)")
                    XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    XCTAssertEqual(try arguments(in: value), expected, "\(language): \(key)")
                }
            }
        }
    }

    func testCompiledTablesContainEveryKeyInEveryLanguage() throws {
        let catalogue = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "Sources/Dimmer/Resources/Localizable.xcstrings"))) as! [String: Any]
        let keys = Set((catalogue["strings"] as! [String: Any]).keys)
        for language in languages {
            var compiledKeys = Set<String>()
            for ext in ["strings", "stringsdict"] {
                guard let url = L10n.bundle.url(forResource: "Localizable", withExtension: ext, subdirectory: "\(language).lproj") else { continue }
                let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
                compiledKeys.formUnion(table.keys)
            }
            XCTAssertEqual(compiledKeys, keys, language)
        }
    }

    func testSpokenUnitsUseCompiledPluralForms() throws {
        let expected: [String: [String]] = [
            "en-GB": ["1 degree", "2 degrees", "1 degree per second", "2 degrees per second", "1 millisecond", "2 milliseconds"],
            "es": ["1 grado", "2 grados", "1 grado por segundo", "2 grados por segundo", "1 milisegundo", "2 milisegundos"],
            "pt-BR": ["1 grau", "2 graus", "1 grau por segundo", "2 graus por segundo", "1 milissegundo", "2 milissegundos"],
            "de": ["1 Grad", "2 Grad", "1 Grad pro Sekunde", "2 Grad pro Sekunde", "1 Millisekunde", "2 Millisekunden"],
            "fr": ["1 degré", "2 degrés", "1 degré par seconde", "2 degrés par seconde", "1 milliseconde", "2 millisecondes"],
            "ja": ["1度", "2度", "毎秒1度", "毎秒2度", "1ミリ秒", "2ミリ秒"]
        ]
        for language in languages {
            let path = try XCTUnwrap(L10n.bundle.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let locale = Locale(identifier: language)
            let one: Int64 = 1, two: Int64 = 2
            let values = [
                String(localized: "\(one) degrees", bundle: bundle, locale: locale),
                String(localized: "\(two) degrees", bundle: bundle, locale: locale),
                String(localized: "\(one) degrees per second", bundle: bundle, locale: locale),
                String(localized: "\(two) degrees per second", bundle: bundle, locale: locale),
                String(localized: "\(one) milliseconds", bundle: bundle, locale: locale),
                String(localized: "\(two) milliseconds", bundle: bundle, locale: locale)
            ]
            XCTAssertEqual(values, expected[language], language)
        }
    }

    func testMainBundleAdvertisesAllLanguagesForAutomaticSelection() throws {
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appending(path: "Resources/Info.plist")), format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "en-GB")
        let declared = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(Set(declared), Set(languages))
        for language in languages {
            XCTAssertEqual(Bundle.preferredLocalizations(from: declared, forPreferences: [language]).first, language)
        }
        XCTAssertEqual(Bundle.preferredLocalizations(from: declared, forPreferences: ["es-MX"]).first, "es")
        XCTAssertEqual(Bundle.preferredLocalizations(from: declared, forPreferences: ["pt-BR"]).first, "pt-BR")
    }
}
