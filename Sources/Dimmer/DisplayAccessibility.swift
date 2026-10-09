import AppKit
import Combine

struct DisplayAccessibilityPreferences: Equatable {
    var reduceMotion: Bool
    var reduceTransparency: Bool
    var increaseContrast: Bool

    @MainActor
    static var system: Self {
        let workspace = NSWorkspace.shared
        return Self(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                    reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                    increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    }
}

@MainActor
final class DisplayAccessibility: ObservableObject {
    static let shared = DisplayAccessibility()
    @Published private(set) var preferences = DisplayAccessibilityPreferences.system
    private var changes: AnyCancellable?

    private init() {
        changes = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let current = DisplayAccessibilityPreferences.system
                if current != self.preferences { self.preferences = current }
            }
    }
}
