import AppKit
import Combine
import os
import ServiceManagement
import SwiftUI
import KeyboardShortcuts

@MainActor
final class DimmerAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DimmerController()
    private let features = DimmerFeatures()
    private let shell = ShellPreferences()
    private let login = LoginItem()
    private let aboutWindow = AboutWindowController()
    private lazy var settingsWindow = SettingsWindowController(
        controller: controller,
        features: features,
        shell: shell,
        login: login
    )
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var snapshotObserver: NSObjectProtocol?
    private var subscriptions = Set<AnyCancellable>()
    private var privacyShortcutTask: Task<Void, Never>?
    private var privacyShortcutGeneration = UUID()
    private var privacyShortcutTrigger = PrivacyShortcutTrigger()
    private var shortcutInputMonitor: Any?
    private var sleeping = false
    private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "launch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isLogin = LaunchPresentation.isLogin
        installAppMenu()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuitEvent(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusItem(paused: controller.paused)
            logger.info("status item created; visible=\(self.statusItem.isVisible, privacy: .public)")
        } else {
            logger.error("status item has no button")
        }
        controller.$paused.sink { [weak self] paused in
            self?.restartPrivacyShortcut()
            Task { @MainActor in
                self?.updateStatusItem(paused: paused)
                if paused { self?.features.suspend(reason: "pause") }
            }
        }.store(in: &subscriptions)
        shell.$showMenuBarIcon.sink { [weak self] visible in
            self?.statusItem.isVisible = visible
        }.store(in: &subscriptions)
        DisplayAccessibility.shared.$preferences.map(\.increaseContrast).removeDuplicates().dropFirst()
            .sink { [weak self] contrast in
                Task { @MainActor in
                    guard let self else { return }
                    self.statusItem.button?.image = StatusGlyph.image(paused: self.controller.paused, increaseContrast: contrast)
                }
            }.store(in: &subscriptions)
        controller.$angle.sink { [weak self] angle in
            Task { @MainActor in
                if angle == nil { self?.features.angleUnavailable() }
            }
        }.store(in: &subscriptions)
        controller.$rawSample.compactMap { $0 }
            .sink { [weak self] sample in
                Task { @MainActor in self?.features.update(sample: sample) }
            }
            .store(in: &subscriptions)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: menuView())
        NotificationCenter.default.publisher(for: .dimmerPrivacyShortcutDidChange)
            .sink { [weak self] _ in self?.restartPrivacyShortcut() }
            .store(in: &subscriptions)
        // Clicking or navigating to a recorder cancels a held chord even if recording ends without a change.
        shortcutInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.type != .keyDown || KeyboardShortcuts.Shortcut(event: event) != KeyboardShortcuts.getShortcut(for: .privacyBlur) {
                self?.restartPrivacyShortcut()
            }
            return event
        }
        restartPrivacyShortcut()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true
                self?.restartPrivacyShortcut()
                self?.features.suspend(reason: "sleep")
                self?.controller.prepareForSleep()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = false
                self?.restartPrivacyShortcut()
                self?.controller.resumeAfterWake()
            }
        }
        controller.start()
        switch LaunchPresentation.initial(isLogin: isLogin, showMenuBarIcon: shell.showMenuBarIcon,
                                           hasSeenWelcome: shell.hasSeenWelcome) {
        case .quiet: break
        case .settings, .welcome: presentSettings()
        }
        // Used by scripts/check-settings.sh to prove the window opens in the built app.
        if CommandLine.arguments.contains("--open-settings") { presentSettings() }
        // Design review only: with --snapshot-dir <folder>, a local "uk.co.kalkmancode.Dimmer.snapshot"
        // notification whose object is a file name writes the Settings window there.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-dir"), index + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            snapshotObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("uk.co.kalkmancode.Dimmer.snapshot"), object: nil, queue: .main
            ) { [weak self] note in
                guard let name = (note.object as? String).map({ URL(fileURLWithPath: $0).lastPathComponent }),
                      name.hasSuffix(".png") else { return }
                Task { @MainActor in
                    let wrote = self?.settingsWindow.snapshot(to: folder.appendingPathComponent(name)) ?? false
                    self?.logger.info("settings snapshot \(name, privacy: .public) written=\(wrote, privacy: .public)")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentSettings()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        login.refresh()
        restartPrivacyShortcut()
    }

    // AppKit's own quit Apple Event handler (AppleScript, logout, restart) answers "User cancelled"
    // while a sheet is up, before asking the delegate, so a welcome left open would block logout.
    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        // Quit after returning, so the sender (loginwindow at logout) gets its reply before the process exits.
        DispatchQueue.main.async { AppShell.quit() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        privacyShortcutTask?.cancel()
        shortcutInputMonitor.map(NSEvent.removeMonitor)
        controller.stop()
        features.stop()
        [sleepObserver, wakeObserver].compactMap { $0 }.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    private func restartPrivacyShortcut() {
        privacyShortcutTask?.cancel()
        privacyShortcutTrigger.cancel()
        let generation = UUID()
        privacyShortcutGeneration = generation
        privacyShortcutTask = Task { [weak self] in
            for await event in KeyboardShortcuts.events(for: .privacyBlur) {
                guard let self, !Task.isCancelled, generation == self.privacyShortcutGeneration else { return }
                let allowed = !self.controller.paused && !self.sleeping
                    && KeyboardShortcuts.getShortcut(for: .privacyBlur) != nil
                if self.privacyShortcutTrigger.receive(isKeyDown: event == .keyDown, allowed: allowed) {
                    self.features.activatePrivacyBlurFromShortcut(at: ProcessInfo.processInfo.systemUptime,
                                                                  angle: self.controller.rawSample?.angle ?? self.controller.angle)
                }
            }
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let eventType = event.map { Int($0.type.rawValue) } ?? -1
        logger.info("status item action received; eventType=\(eventType, privacy: .public)")
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            menu.addItem(withTitle: "About Dimmer", action: #selector(showAbout), keyEquivalent: "")
            menu.addItem(withTitle: "Report a bug…", action: #selector(reportBug), keyEquivalent: "")
            menu.addItem(withTitle: "View latest release…", action: #selector(viewLatestRelease), keyEquivalent: "")
            menu.addItem(.separator())
            let dark = menu.addItem(withTitle: "Go dark", action: controller.paused ? nil : #selector(goDark), keyEquivalent: "")
            dark.toolTip = "Keyboard and screen off until you type, touch the trackpad or move the lid."
            menu.addItem(withTitle: controller.paused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Dimmer", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: statusItem.button?.bounds.maxY ?? 0), in: statusItem.button)
        } else if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            logger.info("status popover shown=\(self.popover.isShown, privacy: .public)")
        }
    }

    @objc private func togglePause() { controller.togglePaused() }
    @objc private func goDark() { controller.goDark() }
    @objc private func quit() { AppShell.quit() }
    @objc private func showSettings() { presentSettings() }
    @objc private func showAbout() {
        popover.performClose(nil)
        aboutWindow.show()
    }
    @objc private func reportBug() {
        showAbout()
        NSWorkspace.shared.open(SupportDetails.issueURL)
    }
    @objc private func viewLatestRelease() { NSWorkspace.shared.open(SupportDetails.releaseURL) }

    private func installAppMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "Dimmer")
        let appItem = mainMenu.addItem(withTitle: "Dimmer", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Dimmer", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Dimmer", action: #selector(quit), keyEquivalent: "q")
        appMenu.items.forEach { $0.target = self }

        let editMenu = NSMenu(title: "Edit")
        mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu
        for (title, selector, key) in [
            ("Undo", NSSelectorFromString("undo:"), "z"),
            ("Redo", NSSelectorFromString("redo:"), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }

        let windowMenu = NSMenu(title: "Window")
        mainMenu.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    private func presentSettings() {
        restartPrivacyShortcut()
        if popover.isShown { popover.performClose(nil) }
        if !shell.hasSeenWelcome {
            shell.showWelcome = true
            shell.hasSeenWelcome = true
        }
        settingsWindow.show()
    }

    private func updateStatusItem(paused: Bool) {
        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel(paused ? "Dimmer paused" : "Dimmer active")
        button.image = StatusGlyph.image(paused: paused, increaseContrast: DisplayAccessibility.shared.preferences.increaseContrast)
        statusItem.isVisible = shell.showMenuBarIcon
    }

    private func menuView() -> some View {
        DimmerMenu(controller: controller, features: features,
                   showSettings: { [weak self] in self?.presentSettings() },
                   showAbout: { [weak self] in self?.showAbout() },
                   reportBug: { [weak self] in self?.reportBug() })
    }

}
