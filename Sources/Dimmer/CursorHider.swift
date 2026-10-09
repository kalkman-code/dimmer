import CoreGraphics
import Foundation

// Hides the pointer while the snap blur is up. A background (accessory) app's CGDisplayHideCursor is
// ignored by the window server unless its connection carries the private "SetsCursorInBackground"
// property; that needs no permission and does not activate Dimmer, so the user's app keeps the keyboard.
// The symbols come from SkyLight (re-exported by CoreGraphics), looked up at runtime like DisplayServices.
@MainActor
enum CursorHider {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static var hidden = false
    private(set) static var backgroundAllowed = false
    static var isHidden: Bool { hidden }

    static func hide() {
        guard !hidden else { return }
        allowInBackground()
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }

    private static func allowInBackground() {
        guard !backgroundAllowed else { return }
        let handle = dlopen(nil, RTLD_NOW)
        func symbol<T>(_ names: [String], as type: T.Type) -> T? {
            for name in names { if let s = dlsym(handle, name) { return unsafeBitCast(s, to: type) } }
            return nil
        }
        guard let connection = symbol(["SLSMainConnectionID", "_CGSDefaultConnection"], as: MainConnection.self),
              let setProperty = symbol(["SLSSetConnectionProperty", "CGSSetConnectionProperty"], as: SetConnectionProperty.self)
        else { return }
        let id = connection()
        backgroundAllowed = setProperty(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }
}
