import Foundation
import XCTest
@testable import Dimmer

final class WebsiteLinkTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Sources/Dimmer/\(name).swift"), encoding: .utf8)
    }

    func testThreeInAppEntriesUseTheWebsiteDestination() throws {
        let link = "Link(L10n.string(\"kalkmancode.co.uk\"), destination: SupportDetails.websiteURL)"
        for name in ["DimmerMenu", "SettingsView"] {
            XCTAssertEqual(try source(name).components(separatedBy: link).count - 1, 1, name)
        }

        let app = try source("DimmerApp")
        XCTAssertEqual(app.components(separatedBy: "menu.addItem(withTitle: L10n.string(\"kalkmancode.co.uk\"), action: #selector(openWebsite), keyEquivalent: \"\")").count - 1, 1)
        XCTAssertTrue(app.contains("@objc private func openWebsite() { NSWorkspace.shared.open(SupportDetails.websiteURL) }"))
    }

    func testWebsiteDestinationIsTheRequestedURL() {
        XCTAssertEqual(SupportDetails.websiteURL.absoluteString, "https://kalkmancode.co.uk/dimmer")
    }

    func testWebsiteLabelHasEverySupportedLocalisation() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/Dimmer/Resources/Localizable.xcstrings"))
        let catalogue = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let strings = catalogue["strings"] as! [String: [String: Any]]
        let localisations = strings["kalkmancode.co.uk"]?["localizations"] as? [String: Any] ?? [:]
        let expected: Set<String> = ["de", "en-GB", "es", "fr", "ja", "pt-BR"]

        XCTAssertEqual(Set(localisations.keys), expected)
        for language in expected {
            let unit = (localisations[language] as? [String: Any])?["stringUnit"] as? [String: String]
            XCTAssertEqual(unit?["value"], "kalkmancode.co.uk", language)
        }
    }

    func testSourcesContainNoCoffeeReferencesOrCatalogueKeys() throws {
        let sources = repoRoot.appendingPathComponent("Sources/Dimmer")
        guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate Sources/Dimmer")
            return
        }
        for case let file as URL in files {
            guard file.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(contents.localizedCaseInsensitiveContains("coffee"), file.lastPathComponent)
        }

        let data = try Data(contentsOf: sources.appendingPathComponent("Resources/Localizable.xcstrings"))
        let catalogue = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let strings = catalogue["strings"] as! [String: Any]
        XCTAssertFalse(strings.keys.contains { $0.localizedCaseInsensitiveContains("coffee") })
    }
}
