import Foundation
import KeyboardShortcuts

@MainActor
final class ShortcutListener {
    private let name: KeyboardShortcuts.Name
    private let events: () -> AsyncStream<KeyboardShortcuts.EventType>
    private let isAllowed: () -> Bool
    private let onTrigger: () -> Void
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var trigger = ShortcutReleaseTrigger()

    init(
        name: KeyboardShortcuts.Name,
        events: (() -> AsyncStream<KeyboardShortcuts.EventType>)? = nil,
        isAllowed: @escaping () -> Bool,
        onTrigger: @escaping () -> Void
    ) {
        self.name = name
        self.events = events ?? { KeyboardShortcuts.events(for: name) }
        self.isAllowed = isAllowed
        self.onTrigger = onTrigger
    }

    func restart(enabled: Bool = true) {
        guard enabled else { return stop() }
        task?.cancel()
        trigger.cancel()
        let currentGeneration = UUID()
        generation = currentGeneration

        task = Task { [weak self] in
            guard let self else { return }
            for await event in self.events() {
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                if self.trigger.receive(isKeyDown: event == .keyDown, allowed: self.isAllowed()) {
                    self.onTrigger()
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        trigger.cancel()
    }
}
