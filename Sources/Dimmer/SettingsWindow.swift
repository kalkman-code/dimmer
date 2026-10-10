import AppKit
import os
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let controller: DimmerController
    private let features: DimmerFeatures
    private let shell: ShellPreferences
    private let login: LoginItem
    private var window: NSWindow?
    private var hasShown = false

    init(controller: DimmerController, features: DimmerFeatures, shell: ShellPreferences, login: LoginItem) {
        self.controller = controller
        self.features = features
        self.shell = shell
        self.login = login
    }

    func show() {
        login.refresh()
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let view = SettingsView(controller: controller, features: features, shell: shell, login: login)
            let host = NSHostingController(rootView: view)
            // A grouped Form scrolls, so its ideal height is zero; left to size the window, the hosting
            // controller shrank it to a bare 28 pt title bar.
            host.sizingOptions = []
            // Tall enough for every section on a 16-inch screen; a shorter screen scrolls the Form.
            let screenHeight = (NSScreen.main?.visibleFrame.height ?? 1010) - 40
            let height = min(1046, screenHeight)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: height),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.string("Dimmer Settings")
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 20.0 / 255, green: 20.0 / 255, blue: 22.0 / 255, alpha: 1)
            window.contentViewController = host
            // Assigning the controller resizes the window to the controller's view, which is still empty.
            window.setContentSize(NSSize(width: 760, height: height))
            window.contentMinSize = NSSize(width: 680, height: 480)
            window.delegate = self
            window.setFrameAutosaveName("DimmerSettings")
            self.window = window
        }
        guard let window else { return }
        if !hasShown {
            if window.setFrameUsingName("DimmerSettings") {
                let restored = window.contentLayoutRect.size
                window.setContentSize(NSSize(width: max(680, restored.width), height: max(480, restored.height)))
            } else {
                window.center()
                let height = min(1046, (window.screen?.visibleFrame.height ?? 1010) - 40)
                window.setContentSize(NSSize(width: 760, height: height))
            }
            window.setFrame(window.constrainFrameRect(window.frame, to: window.screen), display: false)
            hasShown = true
        }
        window.makeKeyAndOrderFront(nil)
        // Otherwise AppKit hands the first text field the keyboard and it opens looking selected.
        window.makeFirstResponder(nil)
        NSApp.activate()
        Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "settings")
            .info("settings window shown visible=\(window.isVisible, privacy: .public) frame=\(NSStringFromRect(window.frame), privacy: .public)")
    }

    func windowWillClose(_ notification: Notification) {
        // Ends a value being typed in a tag, so it commits now rather than when the window next opens.
        window?.endEditing(for: nil)
        AppShell.returnToMenuBar(closing: window)
    }

    #if DEBUG
    // Renders this app's own Settings window, title bar included, to a PNG. An app may always draw its
    // own views, so unlike screencapture this needs no Screen Recording permission and sees nothing else
    // on the screen. Driven by scripts/snapshot-settings.sh for design review.
    @discardableResult
    func snapshot(to url: URL) -> Bool {
        guard let frameView = window?.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        // Atomic: written beside the target and renamed over it, so a symlink planted at that name is
        // replaced rather than followed out of the snapshot folder.
        return (try? data.write(to: url, options: .atomic)) != nil
    }
    #endif
}
