import AppKit

enum UninstallGuide {
    static func cleanupFiles(home: URL) -> [URL] {
        [home.appendingPathComponent("Library/Preferences/uk.co.kalkmancode.Dimmer.plist"),
         home.appendingPathComponent("Library/Application Support/Dimmer/keyboard-recovery.json"),
         home.appendingPathComponent("Library/Application Support/Dimmer/display-recovery.json")]
    }

    // Restoration can remain unresolved while the keyboard is idle or a hardware interface fails.
    // Never delete its only recovery record or trash the running app on the strength of a Quit call.
    @MainActor static func show() {
        let alert = NSAlert()
        alert.messageText = L10n.string("Uninstall Dimmer")
        let text = L10n.string("In Settings, turn off Launch at Login. Quit Dimmer to restore brightness, automatic keyboard brightness and screen colour (even while macOS has dimmed the keyboard). Check that brightness has returned before moving Dimmer from Applications to the Bin in Finder.\n\nOptional cleanup after restoration and quitting: remove Dimmer’s preferences and any remaining recovery files at the paths below. If the keyboard did not come back, the recovery file stays and reopening Dimmer finishes it.")
        let paths = cleanupFiles(home: FileManager.default.homeDirectoryForCurrentUser).map(\.path).joined(separator: "\n")
        alert.informativeText = "\(text)\n\n\(paths)"
        alert.addButton(withTitle: L10n.string("OK"))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
