import CoreGraphics
import Darwin
import Foundation

enum DisplayBrightnessError: LocalizedError {
    case builtInDisplayUnavailable
    case controlsUnavailable
    case brightnessReadFailed(Int32)
    case brightnessWriteFailed(Int32)
    case brightnessReadbackMismatch
    case invalidBrightness

    var errorDescription: String? {
        switch self {
        case .builtInDisplayUnavailable:
            "Built-in display brightness is unavailable."
        case .controlsUnavailable:
            "Display brightness controls are unavailable on this Mac."
        case .brightnessReadFailed(let status):
            "Display brightness could not be read (\(status))."
        case .brightnessWriteFailed(let status):
            "Display brightness could not be changed (\(status))."
        case .brightnessReadbackMismatch:
            "Display brightness did not match the requested value."
        case .invalidBrightness:
            "The display returned an invalid brightness value."
        }
    }
}

enum DisplayBrightnessTarget {
    static func value(captured: Double, factor: Double) -> Double {
        min(max(captured, 0), max(0, captured) * min(max(factor, 0), 1))
    }

    static func owns(current: Double, lastWritten: Double) -> Bool {
        abs(current - lastWritten) <= 0.035
    }
}

enum DisplayGammaFade {
    static func factor(angle: Double, offAt: Double, fullAt: Double) -> Double {
        guard fullAt > offAt else { return angle > offAt ? 1 : 0 }
        let fadeStart = offAt + (fullAt - offAt) * 0.2
        guard angle > offAt else { return 0 }
        guard angle < fadeStart else { return 1 }
        let progress = (angle - offAt) / (fadeStart - offAt)
        return progress * progress * (3 - 2 * progress)
    }
}

enum DisplayRampPlanner {
    static func values(from current: Double, to target: Double, maximumStep: Double) -> [Double] {
        guard current.isFinite, target.isFinite, maximumStep.isFinite, maximumStep > 0 else { return [] }
        let distance = target - current
        guard abs(distance) > 0 else { return [] }
        let steps = max(1, Int(ceil(abs(distance) / maximumStep)))
        return (1...steps).map { index in
            index == steps ? target : current + distance * Double(index) / Double(steps)
        }
    }
}

struct DisplayDimmingLogic {
    enum Decision: Equatable {
        case capture(Double)
        case waitForOpen
        case dim(target: Double, override: Bool)
        case restore(Double)
        case idle
    }

    private(set) var baseline: Double?
    private(set) var isDimming = false
    private var overrideLogged = false
    private var lastWritten: Double?

    mutating func update(angle: Double, current: Double, offAt: Double, fullAt: Double) -> Decision {
        if angle >= fullAt {
            guard !isDimming else { return .idle }
            baseline = current
            return .capture(current)
        }

        guard let baseline else { return .waitForOpen }
        let factor = BrightnessCurve.output(angle: angle, offAt: offAt, fullAt: fullAt)
        let target = DisplayBrightnessTarget.value(captured: baseline, factor: factor)
        let outsideChange = lastWritten.map { !DisplayBrightnessTarget.owns(current: current, lastWritten: $0) } ?? false
        let shouldLogOverride = outsideChange && !overrideLogged
        if shouldLogOverride { overrideLogged = true }
        isDimming = true
        lastWritten = target
        return .dim(target: target, override: shouldLogOverride)
    }

    mutating func markWritten(_ brightness: Double) {
        lastWritten = brightness
    }

    mutating func prepareRestore() -> Double? {
        isDimming = false
        overrideLogged = false
        lastWritten = nil
        return baseline
    }

    mutating func reset() {
        baseline = nil
        isDimming = false
        overrideLogged = false
        lastWritten = nil
    }
}

struct DisplayRecoveryJournal: Codable {
    let originalBrightness: Double
    var lastWritten: Double
    var pendingBrightness: Double? = nil

    func owns(_ brightness: Double) -> Bool {
        DisplayBrightnessTarget.owns(current: brightness, lastWritten: lastWritten) ||
            (pendingBrightness.map { DisplayBrightnessTarget.owns(current: brightness, lastWritten: $0) } ?? false)
    }

    private static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Dimmer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("display-recovery.json")
    }

    func save() throws {
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }

    static func load() -> DisplayRecoveryJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DisplayRecoveryJournal.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

final class DisplayBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    let displayID: CGDirectDisplayID
    private let framework: UnsafeMutableRawPointer
    private let getBrightness: GetBrightness
    private let setBrightness: SetBrightness
    private let canChangeBrightness: CanChangeBrightness?
    private struct GammaTable {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
    }
    private var capturedGamma: GammaTable?

    init() throws {
        displayID = try Self.builtInDisplayID()

        guard let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW | RTLD_LOCAL) else {
            throw DisplayBrightnessError.controlsUnavailable
        }
        guard let getSymbol = dlsym(framework, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(framework, "DisplayServicesSetBrightness") else {
            dlclose(framework)
            throw DisplayBrightnessError.controlsUnavailable
        }
        self.framework = framework
        getBrightness = unsafeBitCast(getSymbol, to: GetBrightness.self)
        setBrightness = unsafeBitCast(setSymbol, to: SetBrightness.self)
        canChangeBrightness = dlsym(framework, "DisplayServicesCanChangeBrightness").map {
            unsafeBitCast($0, to: CanChangeBrightness.self)
        }

        // Keep automatic brightness untouched because the private CoreBrightness client path is unsafe here.
    }

    deinit {
        dlclose(framework)
    }

    func read() throws -> Double {
        guard canChangeBrightness?(displayID) ?? true else { throw DisplayBrightnessError.controlsUnavailable }
        var value: Float = 0
        let status = getBrightness(displayID, &value)
        guard status == 0 else { throw DisplayBrightnessError.brightnessReadFailed(status) }
        let result = Double(value)
        guard result.isFinite, (0...1).contains(result) else { throw DisplayBrightnessError.invalidBrightness }
        return result
    }

    func write(_ value: Double) throws -> Double {
        let target = min(max(value, 0), 1)
        let status = setBrightness(displayID, Float(target))
        guard status == 0 else { throw DisplayBrightnessError.brightnessWriteFailed(status) }
        let actual = try read()
        guard abs(actual - target) <= 0.035 else { throw DisplayBrightnessError.brightnessReadbackMismatch }
        return actual
    }

    func setGammaScale(_ factor: Double) throws {
        if capturedGamma == nil { capturedGamma = try readGammaTable() }
        let scale = min(max(factor, 0), 1)
        guard let table = capturedGamma else { throw DisplayBrightnessError.controlsUnavailable }
        let red = table.red.map { CGGammaValue(Double($0) * scale) }
        let green = table.green.map { CGGammaValue(Double($0) * scale) }
        let blue = table.blue.map { CGGammaValue(Double($0) * scale) }
        let status = red.withUnsafeBufferPointer { redValues in
            green.withUnsafeBufferPointer { greenValues in
                blue.withUnsafeBufferPointer { blueValues in
                    CGSetDisplayTransferByTable(displayID, UInt32(red.count), redValues.baseAddress,
                                                greenValues.baseAddress, blueValues.baseAddress)
                }
            }
        }
        guard status == .success else { throw DisplayBrightnessError.brightnessWriteFailed(Int32(status.rawValue)) }
    }

    private func readGammaTable() throws -> GammaTable {
        let capacity = max(2, Int(CGDisplayGammaTableCapacity(displayID)))
        var red = Array(repeating: CGGammaValue(0), count: capacity)
        var green = red
        var blue = red
        var count: UInt32 = 0
        let status = red.withUnsafeMutableBufferPointer { redValues in
            green.withUnsafeMutableBufferPointer { greenValues in
                blue.withUnsafeMutableBufferPointer { blueValues in
                    CGGetDisplayTransferByTable(displayID, UInt32(capacity), redValues.baseAddress,
                                                greenValues.baseAddress, blueValues.baseAddress, &count)
                }
            }
        }
        guard status == .success, count >= 2, Int(count) <= capacity else {
            throw DisplayBrightnessError.brightnessWriteFailed(Int32(status.rawValue))
        }
        return GammaTable(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))),
                          blue: Array(blue.prefix(Int(count))))
    }

    func clearCapturedGamma() {
        capturedGamma = nil
    }

    static func restoreGamma() {
        CGDisplayRestoreColorSyncSettings()
    }

    private static func builtInDisplayID() throws -> CGDirectDisplayID {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            throw DisplayBrightnessError.builtInDisplayUnavailable
        }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success,
              let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            throw DisplayBrightnessError.builtInDisplayUnavailable
        }
        return display
    }

}
