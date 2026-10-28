import Foundation
import XCTest
@testable import Dimmer

final class CoffeeLinkTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Dimmer/\(name).swift"), encoding: .utf8)
    }

    // SwiftUI Menu defers its children until opened. Check the actual call sites without showing UI
    // or opening a browser, including the separate AppKit right-click menu and its action.
    func testBothMenuPathsAndSettingsContainOneCoffeeLink() throws {
        for name in ["DimmerMenu", "SettingsView"] {
            let view = try source(name)
            let link = "Link(L10n.string(\"Buy me a coffee\"), destination: SupportDetails.coffeeURL)"
            XCTAssertEqual(view.components(separatedBy: link).count - 1, 1, name)
        }
        let app = try source("DimmerApp")
        XCTAssertEqual(app.components(separatedBy: "menu.addItem(withTitle: L10n.string(\"Buy me a coffee\"), action: #selector(buyMeACoffee), keyEquivalent: \"\")").count - 1, 1)
        XCTAssertTrue(app.contains("@objc private func buyMeACoffee() { NSWorkspace.shared.open(SupportDetails.coffeeURL) }"))
        XCTAssertEqual(SupportDetails.coffeeURL.absoluteString, "https://kalkmancode.co.uk/coffee/")
    }

    func testCoffeeLinkIsLocalisedInEverySupportedLanguage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/Dimmer/Resources/Localizable.xcstrings"))
        let catalogue = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let strings = catalogue["strings"] as! [String: [String: Any]]
        let coffee = strings["Buy me a coffee"]?["localizations"] as? [String: Any] ?? [:]
        let expected: Set<String> = ["de", "en-GB", "es", "fr", "ja", "pt-BR"]
        XCTAssertTrue(Set(coffee.keys) == expected && expected.allSatisfy { locale in
            let entry = coffee[locale] as? [String: Any]
            let unit = entry?["stringUnit"] as? [String: String]
            return !(unit?["value"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        })
    }
}
