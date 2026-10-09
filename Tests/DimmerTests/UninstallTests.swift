import XCTest
@testable import Dimmer

final class UninstallTests: XCTestCase {
    func testCleanupListContainsOnlyDimmerPreferencesAndItsTwoRecoveryFiles() {
        let home = URL(fileURLWithPath: "/fixture/user", isDirectory: true)
        let cleanup = UninstallGuide.cleanupFiles(home: home)
        XCTAssertEqual(cleanup.map(\.path), [
            "/fixture/user/Library/Preferences/uk.co.kalkmancode.Dimmer.plist",
            "/fixture/user/Library/Application Support/Dimmer/keyboard-recovery.json",
            "/fixture/user/Library/Application Support/Dimmer/display-recovery.json",
        ])
        XCTAssertEqual(Set(cleanup).count, 3)
    }

    func testRecoveryCleanupNamesMatchTheFilesUsedByBothJournals() {
        let files = UninstallGuide.cleanupFiles(home: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertTrue(files.contains(RecoveryJournal.url))
        XCTAssertTrue(files.contains(DisplayRecoveryJournal.url))
    }
}
