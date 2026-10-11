import AppKit
import Combine
import Foundation
import Sparkle

struct UpdateReminder {
    private(set) var pending = false

    mutating func scheduledUpdateFound(userInitiated: Bool) {
        if !userInitiated { pending = true }
    }

    mutating func userAttended() {
        pending = false
    }

    mutating func sessionFinished() {
        pending = false
    }
}

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var updateAvailable = false

    private var updaterController: SPUStandardUpdaterController!
    private var canCheckObservation: NSKeyValueObservation?
    private var started = false
    private var reminder = UpdateReminder()

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { started ? updaterController.updater.automaticallyChecksForUpdates : false }
        set {
            guard started else { return }
            objectWillChange.send()
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { started ? updaterController.updater.automaticallyDownloadsUpdates : false }
        set {
            guard started else { return }
            objectWillChange.send()
            updaterController.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastUpdateCheckDate: Date? {
        started ? updaterController.updater.lastUpdateCheckDate : nil
    }

    static func isConfigured(_ info: [String: Any]?) -> Bool {
        guard let info,
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              let key = info["SUPublicEDKey"] as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    func start() {
        guard !started, Self.isConfigured(Bundle.main.infoDictionary) else { return }
        started = true
        updaterController.startUpdater()
        canCheckObservation = updaterController.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate { NSApp.setActivationPolicy(.regular) }
        reminder.scheduledUpdateFound(userInitiated: state.userInitiated)
        updateAvailable = reminder.pending
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        reminder.userAttended()
        updateAvailable = reminder.pending
    }

    func standardUserDriverWillFinishUpdateSession() {
        reminder.sessionFinished()
        updateAvailable = reminder.pending
        AppShell.returnToMenuBar(closing: nil)
    }
}
