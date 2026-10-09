import XCTest
@testable import Dimmer

@MainActor
final class AppShellTests: XCTestCase {
    func testMenuBarPreferencePersistsAcrossLaunches() throws {
        let name = "AppShellTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ShellPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showMenuBarIcon)
        preferences.showMenuBarIcon = false
        XCTAssertFalse(ShellPreferences(defaults: defaults).showMenuBarIcon)
    }

    func testHiddenIconRecoversOnManualLaunchButStaysQuietAtLogin() {
        XCTAssertEqual(LaunchPresentation.initial(isLogin: false, showMenuBarIcon: false, hasSeenWelcome: true), .settings)
        XCTAssertEqual(LaunchPresentation.initial(isLogin: true, showMenuBarIcon: false, hasSeenWelcome: true), .quiet)
        XCTAssertEqual(LaunchPresentation.initial(isLogin: false, showMenuBarIcon: true, hasSeenWelcome: true), .quiet)
    }

    func testWelcomeWaitsForManualLaunchAndIsRemembered() throws {
        let name = "WelcomeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ShellPreferences(defaults: defaults)
        XCTAssertFalse(preferences.hasSeenWelcome)
        XCTAssertEqual(LaunchPresentation.initial(isLogin: true, showMenuBarIcon: true, hasSeenWelcome: false), .quiet)
        XCTAssertEqual(LaunchPresentation.initial(isLogin: false, showMenuBarIcon: true, hasSeenWelcome: false), .welcome)
        preferences.hasSeenWelcome = true
        XCTAssertTrue(ShellPreferences(defaults: defaults).hasSeenWelcome)
    }
}
