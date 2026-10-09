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
        XCTAssertEqual(Set(compiled.keys), sourceKeys)
    }
}
