import AppKit
import os
import SwiftUI

@MainActor
final class SettingsWindow: NSWindow {
    nonisolated static let minimumContentSize = NSSize(width: 680, height: 480)
    private let history: SettingsHistory
    // A number being typed in keeps its own undo, so Cmd+Z mid-edit never reaches the settings history.
    // The field editor reaches its undo manager through the window, so the window hands it this one.
    private let fieldUndoManager = UndoManager()

    init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool, history: SettingsHistory) {
        self.history = history
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
    }

    // While a number is typed the Edit menu's Undo and Redo belong to the field editor, not the settings history.
    // The shared field editor keeps its own undo manager, so that is the one the typing registers with.
    private var isTyping: Bool { (firstResponder as? NSText)?.isFieldEditor == true }
    private var typingUndoManager: UndoManager { (firstResponder as? NSTextView)?.undoManager ?? fieldUndoManager }

    override var undoManager: UndoManager? { isTyping ? typingUndoManager : history.undoManager }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if isTyping { typingUndoManager.removeAllActions() }
        fieldUndoManager.removeAllActions()
        return super.makeFirstResponder(responder)
    }

    @objc func undo(_ sender: Any?) { if isTyping { typingUndoManager.undo() } else { history.undo() } }
    @objc func redo(_ sender: Any?) { if isTyping { typingUndoManager.redo() } else { history.redo() } }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let manager = isTyping ? typingUndoManager : history.undoManager
        if menuItem.action == #selector(undo(_:)) {
            menuItem.title = manager.canUndo ? manager.undoMenuItemTitle : L10n.string("Undo")
            return isTyping ? manager.canUndo : history.canUndo
        }
        if menuItem.action == #selector(redo(_:)) {
            menuItem.title = manager.canRedo ? manager.redoMenuItemTitle : L10n.string("Redo")
            return isTyping ? manager.canRedo : history.canRedo
        }
        return super.validateMenuItem(menuItem)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let controller: DimmerController
    private let features: DimmerFeatures
    private let shell: ShellPreferences
    private let login: LoginItem
    private let history: SettingsHistory
    private let updates: UpdateController
    private var window: NSWindow?
    private var hasShown = false

    init(controller: DimmerController, features: DimmerFeatures, shell: ShellPreferences, login: LoginItem, updates: UpdateController) {
        self.controller = controller
        self.features = features
        self.shell = shell
        self.login = login
        self.history = SettingsHistory(controller: controller, features: features)
        self.updates = updates
        super.init()
    }

    func show() {
        login.refresh()
        NSApp.setActivationPolicy(.regular)
        let window = loadWindow()
        if !hasShown {
            if window.setFrameUsingName("DimmerSettings") {
                let restored = window.contentLayoutRect.size
                window.setContentSize(NSSize(width: max(SettingsWindow.minimumContentSize.width, restored.width),
                                             height: max(SettingsWindow.minimumContentSize.height, restored.height)))
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

    // Construction is separate from presentation so geometry can be tested without opening a window.
    func loadWindow() -> NSWindow {
        if window == nil {
            let view = SettingsView(controller: controller, features: features, shell: shell, login: login, history: history, updates: updates)
            let host = NSHostingController(rootView: view)
            // A grouped Form has no useful ideal height. Propagate only its minimum: disabling sizing
            // lets the hosting controller replace our contentMinSize with zero on the next layout.
            host.sizingOptions = [.minSize]
            // Tall enough for every section on a 16-inch screen; a shorter screen scrolls the Form.
            let screenHeight = (NSScreen.main?.visibleFrame.height ?? 1010) - 40
            let height = min(1046, screenHeight)
            let window = SettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: height),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false,
                history: history
            )
            window.title = L10n.string("Dimmer Settings")
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 20.0 / 255, green: 20.0 / 255, blue: 22.0 / 255, alpha: 1)
            window.contentViewController = host
            // Assigning the controller resizes the window to the controller's view, which is still empty.
            window.setContentSize(NSSize(width: 760, height: height))
            window.contentMinSize = SettingsWindow.minimumContentSize
            window.delegate = self
            window.setFrameAutosaveName("DimmerSettings")
            self.window = window
        }
        return window!
    }

    func windowWillClose(_ notification: Notification) {
        // Ends a value being typed in a tag, so it commits now rather than when the window next opens.
        window?.endEditing(for: nil)
        history.cancelGesture()
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
