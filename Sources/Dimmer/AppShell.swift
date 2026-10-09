import AppKit
import Combine

enum AppShell {
    // AppKit refuses to terminate while a window has a sheet attached (the welcome, the hide-icon
    // confirmation), so Quit, Cmd+Q and SIGTERM silently did nothing; found on Toby's Mac, 09-10-2026.
    @MainActor static func quit() {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }

    @MainActor static func returnToMenuBar(closing window: NSWindow?) {
        if !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@MainActor
final class ShellPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }
    @Published var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") }
    }
    @Published var showWelcome = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
    }
}

enum LaunchPresentation {
    case quiet, settings, welcome

    static func initial(isLogin: Bool, showMenuBarIcon: Bool, hasSeenWelcome: Bool) -> Self {
        if isLogin { return .quiet }
        if !hasSeenWelcome { return .welcome }
        return showMenuBarIcon ? .quiet : .settings
    }

    @MainActor static var isLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
