import AppKit
import XCTest
@testable import Dimmer

@MainActor
final class UpdateTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testUpdaterConfigurationRequiresSecureFeedAndPublicKey() throws {
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appending(path: "Resources/Info.plist")), format: nil
        ) as? [String: Any])
        XCTAssertTrue(UpdateController.isConfigured(info))
        XCTAssertFalse(UpdateController.isConfigured(nil))
        XCTAssertFalse(UpdateController.isConfigured(["SUFeedURL": "https://example.com/appcast.xml"]))

        var emptyKey = info
        emptyKey["SUPublicEDKey"] = ""
        XCTAssertFalse(UpdateController.isConfigured(emptyKey))

        var insecureFeed = info
        insecureFeed["SUFeedURL"] = "http://kalkmancode.co.uk/dimmer/appcast.xml"
        XCTAssertFalse(UpdateController.isConfigured(insecureFeed))
    }

    func testInfoPlistKeepsSparkleSecurityAndPrivacySafeguards() throws {
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appending(path: "Resources/Info.plist")), format: nil
        ) as? [String: Any])
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
        XCTAssertNil(info["SUEnableAutomaticChecks"])
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://kalkmancode.co.uk/dimmer/appcast.xml")
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: key)).count, 32)
    }

    func testUpdateReminderTracksScheduledUpdateAndAttention() {
        var reminder = UpdateReminder()
        reminder.scheduledUpdateFound(userInitiated: false)
        XCTAssertTrue(reminder.pending)
        reminder.userAttended()
        XCTAssertFalse(reminder.pending)

        reminder.scheduledUpdateFound(userInitiated: true)
        XCTAssertFalse(reminder.pending)
        reminder.scheduledUpdateFound(userInitiated: false)
        reminder.sessionFinished()
        XCTAssertFalse(reminder.pending)
    }

    func testQuitEventHandlerInvokesInjectedQuitAsynchronously() {
        let expectation = expectation(description: "quit handler")
        let handler = QuitEventHandler(quit: { expectation.fulfill() })
        handler.handle(NSAppleEventDescriptor(), withReply: NSAppleEventDescriptor())
        wait(for: [expectation], timeout: 1)
    }

    func testControllerDoesNotStartSparkleWithoutConfiguredBundle() {
        let before = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("SU") }.sorted()
        let updates = UpdateController()
        XCTAssertFalse(updates.canCheckForUpdates)
        XCTAssertFalse(updates.automaticallyChecksForUpdates)
        XCTAssertFalse(updates.automaticallyDownloadsUpdates)
        let after = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("SU") }.sorted()
        XCTAssertEqual(after, before)
    }
}
