import ServiceManagement
import Combine

@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    var message: String {
        if let errorMessage { return errorMessage }
        switch status {
        case .enabled: return L10n.string("Dimmer will run quietly when you log in.")
        case .notRegistered: return L10n.string("Dimmer starts only when you open it.")
        case .requiresApproval: return L10n.string("Approval needed. Allow Dimmer in System Settings → General → Login Items.")
        case .notFound: return L10n.string("macOS could not find Dimmer’s login item. Install Dimmer in Applications and try again.")
        @unknown default: return L10n.string("macOS could not determine the login status. Try again.")
        }
    }

    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status { errorMessage = nil }
        status = current
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            if enabled {
                errorMessage = L10n.string("Could not enable Launch at Login: \(error.localizedDescription)")
            } else {
                errorMessage = L10n.string("Could not disable Launch at Login: \(error.localizedDescription)")
            }
        }
        status = SMAppService.mainApp.status
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
