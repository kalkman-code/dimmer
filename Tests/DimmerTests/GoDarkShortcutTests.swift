import KeyboardShortcuts
import XCTest
@testable import Dimmer

@MainActor
final class GoDarkShortcutTests: XCTestCase {
    func testGoDarkShortcutIsUnassignedByDefault() {
        XCTAssertNil(KeyboardShortcuts.Name.goDark.initialShortcut)
        let raw = "goDarkTest" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defer { UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_\(raw)") }
        let name = KeyboardShortcuts.Name(raw)
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: name))
    }

    func testShortcutConflictReasonDetectsEqualShortcuts() {
        let shortcut = KeyboardShortcuts.Shortcut(.a, modifiers: [.command])
        let different = KeyboardShortcuts.Shortcut(.b, modifiers: [.command])

        XCTAssertNil(ShortcutConflict.reason(for: shortcut, other: nil, otherName: "Other"))
        XCTAssertNil(ShortcutConflict.reason(for: shortcut, other: different, otherName: "Other"))

        let reason = ShortcutConflict.reason(for: shortcut, other: shortcut, otherName: "Privacy blur")
        XCTAssertEqual(reason, L10n.string("This shortcut is already used by Privacy blur. Choose another combination."))
    }

    func testListenerActivatesOnCompletedReleaseOnly() async {
        var continuation: AsyncStream<KeyboardShortcuts.EventType>.Continuation!
        let stream = AsyncStream<KeyboardShortcuts.EventType> { cont in continuation = cont }

        var triggers = 0
        let listener = ShortcutListener(name: .goDark, events: { stream }, isAllowed: { true }, onTrigger: { triggers += 1 })
        listener.restart()

        continuation.yield(.keyDown)
        await Task.yield()
        XCTAssertEqual(triggers, 0)

        continuation.yield(.keyUp)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(triggers, 1)

        continuation.yield(.keyUp)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(triggers, 1)

        listener.stop()
    }

    func testListenerCancelsHeldObsoletePresses() async {
        var continuation: AsyncStream<KeyboardShortcuts.EventType>.Continuation!
        var stream = AsyncStream<KeyboardShortcuts.EventType> { cont in continuation = cont }

        var triggers = 0
        var allowed = true
        let listener = ShortcutListener(name: .goDark, events: { stream }, isAllowed: { allowed }, onTrigger: { triggers += 1 })
        listener.restart()

        // keyDown then restart then keyUp
        continuation.yield(.keyDown)
        await Task.yield()

        let oldContinuation = continuation
        stream = AsyncStream<KeyboardShortcuts.EventType> { cont in continuation = cont }
        listener.restart()

        oldContinuation?.yield(.keyUp)
        continuation.yield(.keyUp)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(triggers, 0)

        // keyDown then isAllowed false then keyUp
        continuation.yield(.keyDown)
        await Task.yield()
        allowed = false
        continuation.yield(.keyUp)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(triggers, 0)

        // later press with isAllowed true works
        allowed = true
        continuation.yield(.keyDown)
        continuation.yield(.keyUp)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(triggers, 1)

        listener.stop()
    }

    func testListenerDoesNotFireWhenNotAllowed() async {
        var continuation: AsyncStream<KeyboardShortcuts.EventType>.Continuation!
        let stream = AsyncStream<KeyboardShortcuts.EventType> { cont in continuation = cont }

        var triggers = 0
        var allowed = false
        let listener = ShortcutListener(name: .goDark, events: { stream }, isAllowed: { allowed }, onTrigger: { triggers += 1 })
        listener.restart()

        continuation.yield(.keyDown)
        continuation.yield(.keyUp)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(triggers, 0)

        allowed = true
        continuation.yield(.keyDown)
        continuation.yield(.keyUp)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(triggers, 1)

        listener.stop()
    }
}
