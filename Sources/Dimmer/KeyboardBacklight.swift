import Foundation
import ObjectiveC

enum BacklightError: LocalizedError {
    case unavailable
    case invalidBrightness
    case writeMismatch
    case automaticModeMismatch
    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.string("Keyboard backlight controls are unavailable on this Mac.")
        case .invalidBrightness: L10n.string("The keyboard backlight returned an invalid brightness value.")
        case .writeMismatch: L10n.string("The keyboard backlight did not reach the requested brightness.")
        case .automaticModeMismatch: L10n.string("The keyboard backlight automatic mode could not be changed safely.")
        }
    }
}

final class KeyboardBacklight {
    private typealias GetFloat = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFloat = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias GetBool = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias SetBool = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    private let client: NSObject
    private let getBrightness: GetFloat
    private let setBrightness: SetFloat
    private let getAutomatic: GetBool
    private let setAutomatic: SetBool
    private let getIdleDimmed: GetBool
    // The runtime type encodings take the keyboard ID as an unsigned 64-bit integer (Q).
    private let keyboardID: UInt64 = 1

    init() throws {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework"),
              bundle.load(),
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { throw BacklightError.unavailable }
        let instance = type.init()
        let get = NSSelectorFromString("brightnessForKeyboard:")
        let set = NSSelectorFromString("setBrightness:forKeyboard:")
        let auto = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
        let setAuto = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        let idle = NSSelectorFromString("isBacklightDimmedOnKeyboard:")
        guard let getMethod = class_getInstanceMethod(type, get),
              let setMethod = class_getInstanceMethod(type, set),
              let autoMethod = class_getInstanceMethod(type, auto),
              let setAutoMethod = class_getInstanceMethod(type, setAuto),
              let idleMethod = class_getInstanceMethod(type, idle) else { throw BacklightError.unavailable }
        client = instance
        getBrightness = unsafeBitCast(method_getImplementation(getMethod), to: GetFloat.self)
        setBrightness = unsafeBitCast(method_getImplementation(setMethod), to: SetFloat.self)
        getAutomatic = unsafeBitCast(method_getImplementation(autoMethod), to: GetBool.self)
        setAutomatic = unsafeBitCast(method_getImplementation(setAutoMethod), to: SetBool.self)
        getIdleDimmed = unsafeBitCast(method_getImplementation(idleMethod), to: GetBool.self)
    }

    func read() throws -> (brightness: Double, automatic: Bool) {
        let brightness = Double(getBrightness(client, NSSelectorFromString("brightnessForKeyboard:"), keyboardID))
        guard brightness.isFinite, (0...1).contains(brightness) else { throw BacklightError.invalidBrightness }
        return (brightness, getAutomatic(client, NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:"), keyboardID))
    }

    func write(_ value: Double) throws -> Double {
        _ = setBrightness(client, NSSelectorFromString("setBrightness:forKeyboard:"), Float(value), keyboardID)
        return try read().brightness
    }

    func setAutomatic(_ enabled: Bool) {
        _ = setAutomatic(client, NSSelectorFromString("enableAutoBrightness:forKeyboard:"), enabled, keyboardID)
    }

    var isIdleDimmed: Bool {
        getIdleDimmed(client, NSSelectorFromString("isBacklightDimmedOnKeyboard:"), keyboardID)
    }
}
