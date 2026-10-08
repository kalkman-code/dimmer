import AppKit
import Combine
import os
import ServiceManagement
import SwiftUI

@MainActor
final class DimmerAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DimmerController()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var loginObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var subscriptions = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "launch")

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            Task { @MainActor in
                self?.updateStatusItem(paused: paused)
            }
        }.store(in: &subscriptions)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: menuView())
        loginObserver = NotificationCenter.default.addObserver(forName: .dimmerLaunchAtLogin, object: nil, queue: .main) { [weak self] note in
            guard let enabled = note.object as? Bool else { return }
            Task { @MainActor in
                do { try LoginItem.setEnabled(enabled) } catch { NSSound.beep() }
                self?.refreshMenu()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.controller.prepareForSleep() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.controller.resumeAfterWake() }
        }
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        loginObserver.map(NotificationCenter.default.removeObserver)
        [sleepObserver, wakeObserver].compactMap { $0 }.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let eventType = event.map { Int($0.type.rawValue) } ?? -1
        logger.info("status item action received; eventType=\(eventType, privacy: .public)")
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
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
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func updateStatusItem(paused: Bool) {
        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel(paused ? "Dimmer paused" : "Dimmer active")
        button.image = StatusGlyph.image(paused: paused)
        statusItem.isVisible = true
    }

    private func menuView() -> some View {
        DimmerMenu(controller: controller, launchAtLogin: LoginItem.enabled)
    }

    private func refreshMenu() {
        popover.contentViewController = NSHostingController(rootView: menuView())
    }
}
