import AppKit
import Combine
import os
import ServiceManagement
import SwiftUI
import KeyboardShortcuts

@MainActor
final class DimmerAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let controller = DimmerController()
    private let features = DimmerFeatures()
    private let shell = ShellPreferences()
    private let login = LoginItem()
    private let updates = UpdateController()
    private let aboutWindow = AboutWindowController()
    private let quitEventHandler = QuitEventHandler()
    private lazy var settingsWindow = SettingsWindowController(
        controller: controller,
        features: features,
        shell: shell,
        login: login,
        updates: updates
    )
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    #if DEBUG
    private var snapshotObserver: NSObjectProtocol?
    #endif
    private var subscriptions = Set<AnyCancellable>()
    private var privacyShortcut: ShortcutListener?
    private var goDarkShortcut: ShortcutListener?
    private var shortcutInputMonitor: Any?
    private var sleeping = false
    private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "launch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isLogin = LaunchPresentation.isLogin
        installAppMenu()
        NSAppleEventManager.shared().setEventHandler(quitEventHandler, andSelector: #selector(QuitEventHandler.handle(_:withReply:)),
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
        features.follow(controller).forEach { $0.store(in: &subscriptions) }
        controller.pausedPublisher.sink { [weak self] paused in
            self?.restartShortcuts()
            Task { @MainActor in
                self?.updateStatusItem(paused: paused)
            }
        }.store(in: &subscriptions)
        shell.$showMenuBarIcon.sink { [weak self] visible in
            self?.statusItem.isVisible = visible
        }.store(in: &subscriptions)
        features.privacyVeilEnabledPublisher.dropFirst().sink { [weak self] enabled in
            self?.privacyShortcut?.restart(enabled: enabled)
        }.store(in: &subscriptions)
        DisplayAccessibility.shared.$preferences.map(\.increaseContrast).removeDuplicates().dropFirst()
            .sink { [weak self] contrast in
                Task { @MainActor in
                    guard let self else { return }
                    self.statusItem.button?.image = StatusGlyph.image(paused: self.controller.paused, increaseContrast: contrast)
                }
            }.store(in: &subscriptions)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: menuView())
        NotificationCenter.default.publisher(for: .dimmerShortcutDidChange)
            .sink { [weak self] _ in self?.restartShortcuts() }
            .store(in: &subscriptions)

        privacyShortcut = ShortcutListener(name: .privacyBlur) { [weak self] in
            guard let self else { return false }
            return !self.controller.paused && !self.sleeping && KeyboardShortcuts.getShortcut(for: .privacyBlur) != nil
        } onTrigger: { [weak self] in
            guard let self else { return }
            self.features.activatePrivacyBlurFromShortcut(at: ProcessInfo.processInfo.systemUptime,
                                                          angle: self.controller.rawSample?.angle ?? self.controller.angle)
        }

        goDarkShortcut = ShortcutListener(name: .goDark) { [weak self] in
            guard let self else { return false }
            return !self.controller.paused && !self.sleeping && KeyboardShortcuts.getShortcut(for: .goDark) != nil
        } onTrigger: { [weak self] in
            self?.controller.goDark()
        }

        // Clicking or navigating to a recorder cancels a held chord even if recording ends without a change.
        shortcutInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let shortcut = KeyboardShortcuts.Shortcut(event: event)
            if event.type != .keyDown || shortcut != KeyboardShortcuts.getShortcut(for: .privacyBlur) {
                self?.privacyShortcut?.restart(enabled: self?.features.privacyVeilEnabled ?? false)
            }
            if event.type != .keyDown || shortcut != KeyboardShortcuts.getShortcut(for: .goDark) {
                self?.goDarkShortcut?.restart()
            }
            return event
        }
        restartShortcuts()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = true
                self?.restartShortcuts()
                self?.features.suspend(reason: "sleep")
                self?.features.holdAngleLanes("sleep", true)
                self?.controller.prepareForSleep()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = false
                self?.features.holdAngleLanes("sleep", false)
                self?.restartShortcuts()
                self?.controller.resumeAfterWake()
            }
        }
        controller.start()
        updates.start()
        switch LaunchPresentation.initial(isLogin: isLogin, showMenuBarIcon: shell.showMenuBarIcon,
                                           hasSeenWelcome: shell.hasSeenWelcome) {
        case .quiet: break
        case .settings, .welcome: presentSettings()
        }
        #if DEBUG
        // Used by scripts/check-settings.sh to prove the window opens in a debug build.
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
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentSettings()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        login.refresh()
        restartShortcuts()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates) else { return true }
        return updates.canCheckForUpdates || updates.updateAvailable
    }

    func applicationWillTerminate(_ notification: Notification) {
        privacyShortcut?.stop()
        goDarkShortcut?.stop()
        shortcutInputMonitor.map(NSEvent.removeMonitor)
        controller.stop()
        features.stop()
        [sleepObserver, wakeObserver].compactMap { $0 }.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    private func restartShortcuts() {
        privacyShortcut?.restart(enabled: features.privacyVeilEnabled)
        goDarkShortcut?.restart()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let eventType = event.map { Int($0.type.rawValue) } ?? -1
        logger.info("status item action received; eventType=\(eventType, privacy: .public)")
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.addItem(withTitle: L10n.string("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
            menu.addItem(withTitle: L10n.string("About Dimmer"), action: #selector(showAbout), keyEquivalent: "")
            menu.addItem(withTitle: updates.updateAvailable ? L10n.string("Update available…") : L10n.string("Check for updates…"),
                         action: updates.canCheckForUpdates || updates.updateAvailable ? #selector(checkForUpdates) : nil, keyEquivalent: "")
            menu.addItem(withTitle: L10n.string("Report a bug…"), action: #selector(reportBug), keyEquivalent: "")
            menu.addItem(withTitle: L10n.string("View latest release…"), action: #selector(viewLatestRelease), keyEquivalent: "")
            menu.addItem(withTitle: L10n.string("kalkmancode.co.uk"), action: #selector(openWebsite), keyEquivalent: "")
            menu.addItem(.separator())
            let dark = menu.addItem(withTitle: L10n.string("Go dark"), action: controller.canGoDark ? #selector(goDark) : nil, keyEquivalent: "")
            dark.toolTip = controller.hasLidAngle
                ? L10n.string("Keyboard and screen off until you type, touch the trackpad or move the lid.")
                : L10n.string("Without a readable lid sensor, Go dark wakes when you type or use the trackpad or mouse.")

            if !controller.paused {
                menu.addItem(withTitle: L10n.string("Pause for 15 minutes"), action: #selector(pause15), keyEquivalent: "")
                menu.addItem(withTitle: L10n.string("Pause for 1 hour"), action: #selector(pause60), keyEquivalent: "")
            }
            menu.addItem(withTitle: controller.paused ? L10n.string("Resume") : L10n.string("Pause"), action: #selector(togglePause), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L10n.string("Quit Dimmer"), action: #selector(quit), keyEquivalent: "q")
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
    @objc private func pause15() { controller.pause(for: .fifteenMinutes) }
    @objc private func pause60() { controller.pause(for: .oneHour) }
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
    @objc private func openWebsite() { NSWorkspace.shared.open(SupportDetails.websiteURL) }
    @objc private func checkForUpdates() { updates.checkForUpdates() }
    @objc private func uninstallDimmer() { UninstallGuide.show() }

    private func installAppMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: L10n.string("Dimmer"))
        let appItem = mainMenu.addItem(withTitle: L10n.string("Dimmer"), action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.string("About Dimmer"), action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: L10n.string("Check for updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.string("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: L10n.string("Uninstall Dimmer…"), action: #selector(uninstallDimmer), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.string("Quit Dimmer"), action: #selector(quit), keyEquivalent: "q")
        appMenu.items.forEach { $0.target = self }

        let editMenu = NSMenu(title: L10n.string("Edit"))
        mainMenu.addItem(withTitle: L10n.string("Edit"), action: nil, keyEquivalent: "").submenu = editMenu
        for (title, selector, key) in [
            (L10n.string("Undo"), NSSelectorFromString("undo:"), "z"),
            (L10n.string("Redo"), NSSelectorFromString("redo:"), "Z"),
            (L10n.string("Cut"), #selector(NSText.cut(_:)), "x"),
            (L10n.string("Copy"), #selector(NSText.copy(_:)), "c"),
            (L10n.string("Paste"), #selector(NSText.paste(_:)), "v"),
            (L10n.string("Select All"), #selector(NSText.selectAll(_:)), "a"),
        ] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }

        let windowMenu = NSMenu(title: L10n.string("Window"))
        mainMenu.addItem(withTitle: L10n.string("Window"), action: nil, keyEquivalent: "").submenu = windowMenu
        windowMenu.addItem(withTitle: L10n.string("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    private func presentSettings() {
        restartShortcuts()
        if popover.isShown { popover.performClose(nil) }
        if !shell.hasSeenWelcome {
            shell.showWelcome = true
            shell.hasSeenWelcome = true
        }
        settingsWindow.show()
    }

    private func updateStatusItem(paused: Bool) {
        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel(paused ? L10n.string("Dimmer paused") : L10n.string("Dimmer active"))
        button.image = StatusGlyph.image(paused: paused, increaseContrast: DisplayAccessibility.shared.preferences.increaseContrast)
        statusItem.isVisible = shell.showMenuBarIcon
    }

    private func menuView() -> some View {
        DimmerMenu(controller: controller, features: features, updates: updates,
                   showSettings: { [weak self] in self?.presentSettings() },
                   showAbout: { [weak self] in self?.showAbout() },
                   reportBug: { [weak self] in self?.reportBug() })
    }

}
