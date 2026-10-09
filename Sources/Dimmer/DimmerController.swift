import AppKit
import Combine
import Foundation
import os

private struct PollCancelled: Error {}

final class PollGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func performIfCurrent(_ generation: Int, action: () throws -> Void) throws -> Bool {
        lock.lock()
        let current = generation == value
        lock.unlock()
        guard current else { return false }
        try action()
        return true
    }

    func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == value
    }
}

protocol LidSensing: AnyObject {
    func open() throws
    func close()
    func readAngleDegrees() throws -> Double
}

protocol KeyboardBacklightControlling: AnyObject {
    var isIdleDimmed: Bool { get }
    func read() throws -> (brightness: Double, automatic: Bool)
    func write(_ value: Double) throws -> Double
    func setAutomatic(_ enabled: Bool)
}

protocol DisplayBrightnessControlling: AnyObject {
    var displayID: UInt32 { get }
    func read() throws -> Double
    func write(_ value: Double) throws -> Double
    func setGammaScale(_ factor: Double) throws
    func clearCapturedGamma()
    func restoreGamma()
}

extension LidAngleSensor: LidSensing {}
extension KeyboardBacklight: KeyboardBacklightControlling {}
extension DisplayBrightness: DisplayBrightnessControlling {
    func restoreGamma() { Self.restoreGamma() }
}

typealias HardwarePoll = (sample: LidSample, angle: Double, brightness: Double, written: Double?,
                          displayBrightness: Double?, displayStatus: String, keyboardStatus: String?)

final class HardwareWorker: @unchecked Sendable {
    private var sensor: (any LidSensing)?
    private var backlight: (any KeyboardBacklightControlling)?
    private var journal: RecoveryJournal?
    private var display: (any DisplayBrightnessControlling)?
    private var displayJournal: DisplayRecoveryJournal?
    private var displayLogic = DisplayDimmingLogic()
    private var smoothedAngle: Double?
    private var yieldedControl = false
    private var keyboardIdle = KeyboardIdleLogic()
    private var lastKeyboardIdleDimmed: Bool?
    private var darkKeyboardBaseline: Double?
    private var darkDisplayBaseline: Double?
    private var darkGammaBaseline: Double?
    private var gammaActive = false
    private var lastGammaFactor: Double?
    private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "display")
    private var displayRetryAfter = Date.distantPast
    private let makeSensor: () -> any LidSensing
    private let makeBacklight: () throws -> any KeyboardBacklightControlling
    private let makeDisplay: () throws -> any DisplayBrightnessControlling
    private let keyboardJournalURL: URL?
    private let displayJournalURL: URL?

    init(makeSensor: @escaping () -> any LidSensing = { LidAngleSensor() },
         makeBacklight: @escaping () throws -> any KeyboardBacklightControlling = { try KeyboardBacklight() },
         makeDisplay: @escaping () throws -> any DisplayBrightnessControlling = { try DisplayBrightness() },
         keyboardJournalURL: URL? = nil, displayJournalURL: URL? = nil) {
        self.makeSensor = makeSensor
        self.makeBacklight = makeBacklight
        self.makeDisplay = makeDisplay
        self.keyboardJournalURL = keyboardJournalURL
        self.displayJournalURL = displayJournalURL
    }

    func poll(keyboardRange: DimRange, screenRange: DimRange, dimsKeyboard: Bool, dimsScreen: Bool, darkness: Double, generation: Int, gate: PollGeneration) throws -> HardwarePoll {
        do {
            return try readAndApply(keyboardRange: keyboardRange, screenRange: screenRange, dimsKeyboard: dimsKeyboard, dimsScreen: dimsScreen, darkness: darkness, generation: generation, gate: gate)
        } catch {
            if !(error is PollCancelled) {
                restoreAndClose(resetKeyboardYield: !yieldedControl)
            }
            throw error
        }
    }

    private func readAndApply(keyboardRange: DimRange, screenRange: DimRange, dimsKeyboard: Bool, dimsScreen: Bool, darkness: Double, generation: Int, gate: PollGeneration) throws -> HardwarePoll {
        if sensor == nil {
            let device = makeSensor()
            try device.open()
            sensor = device
        }
        if backlight == nil {
            let control = try makeBacklight()
            backlight = control
        }
        let raw = try sensor!.readAngleDegrees()
        let sample = LidSample(angle: raw, time: ProcessInfo.processInfo.systemUptime)
        let angle = smoothedAngle.map { $0 * 0.65 + raw * 0.35 } ?? raw
        smoothedAngle = angle
        var written: Double?
        guard try gate.performIfCurrent(generation, action: { written = try apply(angle, range: keyboardRange, enabled: dimsKeyboard, darkness: darkness) }) else {
            throw PollCancelled()
        }
        let displaySample = try updateDisplay(angle: angle, range: screenRange, enabled: dimsScreen, darkness: darkness,
                                              generation: generation, gate: gate)
        let keyboardStatus = yieldedControl
            ? L10n.string("Keyboard brightness changed outside Dimmer; control paused to respect it.") : nil
        return (sample, angle, try backlight!.read().brightness, written, displaySample.brightness,
                displaySample.status, keyboardStatus)
    }

    func restoreAndClose(resetKeyboardYield: Bool = true) {
        restoreDisplay()
        if let backlight, let journal {
            var resolved = false
            if let current = try? backlight.read() {
                let settled = keyboardIdle.update(idleDimmed: backlight.isIdleDimmed,
                                                  current: current.brightness, automatic: current.automatic,
                                                  lastWritten: journal.lastWritten,
                                                  pendingBrightness: journal.pendingBrightness,
                                                  now: ProcessInfo.processInfo.systemUptime)
                let restoration = settled == .wait ? .wait : KeyboardIdleLogic.restoration(
                    idleDimmed: backlight.isIdleDimmed, ownsBrightness: journal.owns(current.brightness))
                switch restoration {
                case .wait:
                    // Keep the journal: idle attenuation is not an ownership change, and writing
                    // here would light the keyboard during the user's chosen inactivity timeout.
                    resolved = false
                case .apply:
                    if let restored = try? backlight.write(journal.originalBrightness),
                       abs(restored - journal.originalBrightness) <= 0.035, !backlight.isIdleDimmed {
                        resolved = true
                    }
                case .yield:
                    resolved = true
                }
                if journal.originalAutomatic && !current.automatic {
                    if restoration == .yield {
                        do {
                            try enableAutomaticPreservingBrightness(current.brightness, on: backlight)
                        } catch {
                            resolved = false
                        }
                    } else {
                        backlight.setAutomatic(true)
                        if (try? backlight.read().automatic) != true { resolved = false }
                    }
                }
            }
            if resolved { RecoveryJournal.clear(at: keyboardJournalURL) }
        } else if let backlight, !yieldedControl, RecoveryJournal.load(from: keyboardJournalURL) != nil {
            _ = try? recoverStaleState(with: backlight)
        }
        journal = nil
        sensor?.close()
        sensor = nil
        backlight = nil
        smoothedAngle = nil
        if resetKeyboardYield { yieldedControl = false }
        keyboardIdle = KeyboardIdleLogic()
        lastKeyboardIdleDimmed = nil
        darkKeyboardBaseline = nil
        darkDisplayBaseline = nil
        darkGammaBaseline = nil
    }

    private func apply(_ angle: Double, range: DimRange, enabled: Bool, darkness: Double) throws -> Double? {
        guard !yieldedControl || darkness > 0 || darkKeyboardBaseline != nil else { return nil }
        guard let backlight else { return nil }
        var current = try backlight.read()
        let ownership = journal ?? RecoveryJournal.load(from: keyboardJournalURL)
        let idleDimmed = backlight.isIdleDimmed
        if lastKeyboardIdleDimmed != idleDimmed {
            logger.info("keyboard idle dimmed=\(idleDimmed, privacy: .public); native idle policy unchanged")
            lastKeyboardIdleDimmed = idleDimmed
        }
        let decision = keyboardIdle.update(idleDimmed: idleDimmed, current: current.brightness,
                                           automatic: current.automatic,
                                           lastWritten: ownership?.lastWritten,
                                           pendingBrightness: ownership?.pendingBrightness,
                                           now: ProcessInfo.processInfo.systemUptime)
        if decision == .wait { return nil }
        if journal == nil {
            guard try recoverStaleState(with: backlight) else { return nil }
            current = try backlight.read()
        }
        if enabled, let journal, decision == .yield, darkKeyboardBaseline == nil {
            var automaticResolved = true
            if journal.originalAutomatic && !current.automatic {
                do {
                    try enableAutomaticPreservingBrightness(current.brightness, on: backlight)
                } catch {
                    automaticResolved = false
                }
            }
            if automaticResolved { RecoveryJournal.clear(at: keyboardJournalURL) }
            self.journal = nil
            yieldedControl = true
            if darkness <= 0 { return nil }
            current = try backlight.read()
        }
        if darkness > 0, darkKeyboardBaseline == nil { darkKeyboardBaseline = current.brightness }
        if darkness <= 0 { darkKeyboardBaseline = nil }
        if (!enabled || yieldedControl) && darkness <= 0 {
            if let journal {
                let restoration = KeyboardIdleLogic.restoration(idleDimmed: backlight.isIdleDimmed,
                                                               ownsBrightness: journal.owns(current.brightness))
                guard restoration != .wait else { return nil }
                if restoration == .apply {
                    let restored = try backlight.write(journal.originalBrightness)
                    guard !backlight.isIdleDimmed else { return nil }
                    guard abs(restored - journal.originalBrightness) <= 0.035 else { throw BacklightError.writeMismatch }
                }
                if journal.originalAutomatic && !current.automatic {
                    if restoration == .yield {
                        try enableAutomaticPreservingBrightness(current.brightness, on: backlight)
                    } else {
                        backlight.setAutomatic(true)
                        guard try backlight.read().automatic else { throw BacklightError.automaticModeMismatch }
                    }
                }
                RecoveryJournal.clear(at: keyboardJournalURL)
                self.journal = nil
            }
            return nil
        }
        if journal == nil {
            journal = RecoveryJournal(originalBrightness: current.brightness,
                                      originalAutomatic: current.automatic,
                                      lastWritten: current.brightness)
            do { try journal?.save(to: keyboardJournalURL) } catch {
                journal = nil
                throw error
            }
        }
        if current.automatic {
            backlight.setAutomatic(false)
            guard try !backlight.read().automatic else { throw BacklightError.automaticModeMismatch }
        }
        let output = GoDark.level(darkKeyboardBaseline ?? range.level(at: angle), darkness: darkness)
        let skipWrite = abs(output - current.brightness) <= 0.008
            && abs(current.brightness - journal!.lastWritten) <= RecoveryJournal.ownershipTolerance
        if !skipWrite {
            var pending = journal!
            pending.pendingBrightness = output
            try pending.save(to: keyboardJournalURL)
            journal = pending
            let actual = try backlight.write(output)
            // Idle dimming can begin between the ownership check and the write. Leave the pending
            // target journalled; do not record the OS attenuation as our last brightness.
            if backlight.isIdleDimmed { return nil }
            pending.lastWritten = actual
            pending.pendingBrightness = nil
            journal = pending
            try pending.save(to: keyboardJournalURL)
            guard abs(actual - output) <= 0.035 else { throw BacklightError.writeMismatch }
            return actual
        }
        return nil
    }

    private func enableAutomaticPreservingBrightness(_ brightness: Double,
                                                       on backlight: any KeyboardBacklightControlling) throws {
        backlight.setAutomatic(true)
        guard try backlight.read().automatic else { throw BacklightError.automaticModeMismatch }
        guard !backlight.isIdleDimmed else { return }
        _ = try? backlight.write(brightness)
    }

    @discardableResult
    private func recoverStaleState(with client: any KeyboardBacklightControlling) throws -> Bool {
        guard let stale = RecoveryJournal.load(from: keyboardJournalURL) else { return true }
        let current = try client.read()
        let settled = keyboardIdle.update(idleDimmed: client.isIdleDimmed, current: current.brightness,
                                          automatic: current.automatic, lastWritten: stale.lastWritten,
                                          pendingBrightness: stale.pendingBrightness,
                                          now: ProcessInfo.processInfo.systemUptime)
        guard settled != .wait else { return false }
        let restoration = KeyboardIdleLogic.restoration(idleDimmed: client.isIdleDimmed,
                                                       ownsBrightness: stale.owns(current.brightness))
        guard restoration != .wait else { return false }
        var brightnessResolved = restoration == .yield
        if !brightnessResolved {
            guard let restored = try? client.write(stale.originalBrightness),
                  abs(restored - stale.originalBrightness) <= 0.035 else {
                brightnessResolved = false
                if stale.originalAutomatic && !current.automatic {
                    client.setAutomatic(true)
                    guard try client.read().automatic else { throw BacklightError.automaticModeMismatch }
                }
                throw BacklightError.writeMismatch
            }
            guard !client.isIdleDimmed else { return false }
            brightnessResolved = true
        }
        var automaticResolved = true
        if stale.originalAutomatic && !current.automatic {
            if restoration == .yield {
                do {
                    try enableAutomaticPreservingBrightness(current.brightness, on: client)
                } catch {
                    automaticResolved = false
                }
            } else {
                client.setAutomatic(true)
                automaticResolved = try client.read().automatic
            }
        }
        guard brightnessResolved && automaticResolved else { throw BacklightError.automaticModeMismatch }
        RecoveryJournal.clear(at: keyboardJournalURL)
        return true
    }

    func retryKeyboardRecovery() throws -> Bool {
        guard RecoveryJournal.load(from: keyboardJournalURL) != nil else { return true }
        if backlight == nil { backlight = try makeBacklight() }
        let resolved = try recoverStaleState(with: backlight!)
        if resolved {
            backlight = nil
            keyboardIdle = KeyboardIdleLogic()
        }
        return resolved
    }

    private func updateDisplay(angle: Double, range: DimRange, enabled: Bool, darkness: Double,
                               generation: Int, gate: PollGeneration) throws -> (brightness: Double?, status: String) {
        guard enabled || darkness > 0 else {
            darkDisplayBaseline = nil
            darkGammaBaseline = nil
            let hasRecovery = displayLogic.baseline != nil || displayJournal != nil || DisplayRecoveryJournal.load(from: displayJournalURL) != nil || gammaActive
            if hasRecovery {
                restoreDisplay()
                displayLogic.reset()
            }
            return (nil, L10n.string("Screen dimming is off."))
        }

        if darkness <= 0 {
            darkDisplayBaseline = nil
            darkGammaBaseline = nil
        }

        if display == nil {
            do {
                display = try makeDisplay()
                try recoverStaleDisplayState()
            } catch {
                displayRetryAfter = Date().addingTimeInterval(2)
                logger.error("display dimming unavailable: \(error.localizedDescription, privacy: .public)")
                return (nil, error.localizedDescription)
            }
        }

        if angle >= range.highAngle && darkness <= 0 {
            var didRestore = false
            let journalBaseline = displayJournal?.originalBrightness ?? DisplayRecoveryJournal.load(from: displayJournalURL)?.originalBrightness
            if let baseline = displayLogic.isDimming ? displayLogic.prepareRestore() : journalBaseline {
                didRestore = true
                guard restoreDisplay(to: baseline) else {
                    return (try? display?.read(), L10n.string("Display brightness restoration is retrying."))
                }
            } else if gammaActive {
                restoreGamma(display: display)
            }
            do {
                let current = try display?.read()
                if let current {
                    if didRestore { return (current, L10n.string("Screen ready.")) }
                    let previousBaseline = displayLogic.baseline
                    let decision = displayLogic.update(angle: angle, current: current, range: range)
                    if case .capture(let value) = decision {
                        if previousBaseline == nil || abs(previousBaseline! - value) > 0.035 {
                            logger.info("display captured original=\(value, privacy: .public); automatic brightness unchanged; displayID=\(self.display!.displayID, privacy: .public)")
                        }
                    }
                    return (current, L10n.string("Screen ready."))
                }
                return (nil, L10n.string("Screen dimming is unavailable."))
            } catch {
                return (nil, error.localizedDescription)
            }
        }
        guard Date() >= displayRetryAfter else { return (nil, L10n.string("Screen dimming will retry shortly.")) }

        do {
            guard let display else { throw DisplayBrightnessError.controlsUnavailable }
            let current = try display.read()
            if darkness > 0, darkDisplayBaseline == nil {
                darkDisplayBaseline = current
                darkGammaBaseline = lastGammaFactor ?? 1
            }
            switch displayLogic.update(angle: darkness > 0 ? range.highAngle : angle, current: current, range: range, darkness: darkness) {
            case .capture:
                return (current, L10n.string("Screen ready."))
            case .waitForOpen:
                return (current, L10n.string("Screen dimming waits for the lid to open fully once."))
            case .restore(let baseline):
                _ = restoreDisplay(to: baseline)
                return (try? display.read(), L10n.string("Screen ready."))
            case .dim(let lidTarget, let override):
                let target = darkDisplayBaseline.map { GoDark.level($0, darkness: darkness) } ?? lidTarget
                if displayJournal == nil {
                    guard let baseline = displayLogic.baseline else { throw DisplayBrightnessError.controlsUnavailable }
                    let captured = DisplayRecoveryJournal(originalBrightness: baseline, lastWritten: baseline)
                    try captured.save(to: displayJournalURL)
                    displayJournal = captured
                }
                guard var active = displayJournal else { throw DisplayBrightnessError.controlsUnavailable }
                if override {
                    logger.info("display override; automatic brightness changed during close; target will be enforced until reopen")
                }
                active.pendingBrightness = target
                try active.save(to: displayJournalURL)
                displayJournal = active
                let gammaFactor = darkGammaBaseline.map {
                    $0 * DisplayGammaFade.factor(angle: range.highAngle, range: range, darkness: darkness)
                } ?? DisplayGammaFade.factor(angle: angle, range: range)
                let ramp = try rampDisplay(brightness: target, gammaFactor: gammaFactor, display: display,
                                           generation: generation, gate: gate)
                guard ramp.completed else { throw PollCancelled() }
                let actual: Double
                if let value = ramp.brightness { actual = value }
                else { actual = try display.read() }
                active = displayJournal ?? active
                active.lastWritten = actual
                active.pendingBrightness = nil
                try active.save(to: displayJournalURL)
                displayJournal = active
                displayLogic.markWritten(actual)
                logger.info("display angle=\(angle, privacy: .public)° target=\(target, privacy: .public) readback=\(actual, privacy: .public)")
                return (actual, L10n.string("Screen dimming is active."))
            case .idle:
                return (current, L10n.string("Screen ready."))
            }
        } catch {
            if error is PollCancelled { throw error }
            displayRetryAfter = Date().addingTimeInterval(2)
            logger.error("display dimming unavailable: \(error.localizedDescription, privacy: .public)")
            return (nil, error.localizedDescription)
        }
    }

    private func rampDisplay(brightness targetBrightness: Double?, gammaFactor targetGamma: Double?,
                             display: any DisplayBrightnessControlling, generation: Int?, gate: PollGeneration?,
                             restoreColorSyncWhenComplete: Bool = true) throws
        -> (brightness: Double?, completed: Bool) {
        let startingBrightness = try display.read()
        let startingGamma = lastGammaFactor ?? 1
        let brightnessValues = targetBrightness.map {
            DisplayRampPlanner.values(from: startingBrightness, to: $0, maximumStep: 0.04)
        } ?? []
        let gammaValues = targetGamma.map {
            DisplayRampPlanner.values(from: startingGamma, to: $0, maximumStep: 0.08)
        } ?? []
        let started = Date()
        var brightness = startingBrightness
        var gamma = startingGamma
        var brightnessSteps = 0
        var gammaSteps = 0
        var brightnessMaxStep = 0.0
        var gammaMaxStep = 0.0
        let count = max(brightnessValues.count, gammaValues.count)
        for index in 0..<count {
            if let generation, let gate, !gate.isCurrent(generation) {
                logRamp(kind: "brightness", from: startingBrightness, to: brightness, steps: brightnessSteps,
                        maxStep: brightnessMaxStep, started: started, enabled: !brightnessValues.isEmpty)
                logRamp(kind: "gamma", from: startingGamma, to: gamma, steps: gammaSteps,
                        maxStep: gammaMaxStep, started: started, enabled: !gammaValues.isEmpty)
                return (brightness, false)
            }
            Thread.sleep(forTimeInterval: 0.016)
            if index < brightnessValues.count {
                let next = brightnessValues[index]
                if var journal = displayJournal {
                    journal.pendingBrightness = next
                    try journal.save(to: displayJournalURL)
                    displayJournal = journal
                }
                brightness = try display.write(next)
                if var journal = displayJournal {
                    journal.lastWritten = brightness
                    journal.pendingBrightness = nil
                    try journal.save(to: displayJournalURL)
                    displayJournal = journal
                }
                displayLogic.markWritten(brightness)
                brightnessMaxStep = max(brightnessMaxStep, abs(brightness - (index == 0 ? startingBrightness : brightnessValues[index - 1])))
                brightnessSteps += 1
            }
            if index < gammaValues.count {
                let next = gammaValues[index]
                if next < 0.999, !gammaActive {
                    logger.info("display gamma on; black fade active")
                    gammaActive = true
                }
                if gammaActive || next < 0.999 { try display.setGammaScale(next) }
                gammaMaxStep = max(gammaMaxStep, abs(next - gamma))
                gamma = next
                lastGammaFactor = next
                gammaSteps += 1
            }
        }
        logRamp(kind: "brightness", from: startingBrightness, to: brightness, steps: brightnessSteps,
                maxStep: brightnessMaxStep, started: started, enabled: !brightnessValues.isEmpty)
        logRamp(kind: "gamma", from: startingGamma, to: gamma, steps: gammaSteps,
                maxStep: gammaMaxStep, started: started, enabled: !gammaValues.isEmpty)
        if restoreColorSyncWhenComplete, let targetGamma, targetGamma >= 0.999, gammaActive {
            restoreGamma(display: display)
        }
        return (brightness, true)
    }

    private func logRamp(kind: String, from: Double, to: Double, steps: Int, maxStep: Double,
                         started: Date, enabled: Bool) {
        guard enabled else { return }
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        logger.info("display ramp kind=\(kind, privacy: .public) from=\(from, privacy: .public) to=\(to, privacy: .public) steps=\(steps, privacy: .public) maxStep=\(maxStep, privacy: .public) ms=\(elapsed, privacy: .public)")
    }

    private func restoreDisplay() {
        // Only a close in progress (or a stale journal) has anything to hand back; restoring the open baseline
        // on every failed keyboard poll would fight the user's own screen brightness ten times a second.
        let baseline = (displayLogic.isDimming ? displayLogic.prepareRestore() : nil) ?? displayJournal?.originalBrightness ?? DisplayRecoveryJournal.load(from: displayJournalURL)?.originalBrightness
        if let baseline { _ = restoreDisplay(to: baseline) }
        else if gammaActive { restoreGamma(display: display) }
    }

    @discardableResult
    private func restoreDisplay(to baseline: Double) -> Bool {
        let device = display ?? (try? makeDisplay())
        display = device
        var resolved = false
        if let device {
            let ramp = try? rampDisplay(brightness: baseline, gammaFactor: gammaActive ? 1 : nil,
                                        display: device, generation: nil, gate: nil,
                                        restoreColorSyncWhenComplete: false)
            let restored = ramp?.completed == true ? ramp?.brightness : nil
            let readback = try? device.read()
            let verified = readback.map { abs($0 - baseline) <= 0.035 } ?? false
            logger.info("display restored brightness=\(restored ?? -1, privacy: .public); writeSucceeded=\(restored != nil, privacy: .public)")
            logger.info("display restore verified brightness=\(readback ?? -1, privacy: .public); withinTolerance=\(verified, privacy: .public)")
            resolved = restored.map { abs($0 - baseline) <= 0.035 } == true && verified
        }
        restoreGamma(display: device)
        if resolved {
            DisplayRecoveryJournal.clear(at: displayJournalURL)
            displayJournal = nil
        }
        return resolved
    }

    private func restoreGamma(display: (any DisplayBrightnessControlling)?) {
        if let display { display.restoreGamma() }
        else { DisplayBrightness.restoreGamma() }
        display?.clearCapturedGamma()
        logger.info("display gamma off; ColorSync settings restored")
        gammaActive = false
        lastGammaFactor = nil
    }

    private func recoverStaleDisplayState() throws {
        guard let stale = DisplayRecoveryJournal.load(from: displayJournalURL), let display else { return }
        _ = try display.read()
        let ramp = try rampDisplay(brightness: stale.originalBrightness, gammaFactor: nil,
                                   display: display, generation: nil, gate: nil)
        guard ramp.completed, let restored = ramp.brightness else { throw DisplayBrightnessError.controlsUnavailable }
        let resolved = abs(restored - stale.originalBrightness) <= 0.035
        if resolved {
            logger.info("display recovered brightness=\(restored, privacy: .public)")
            logger.info("display restore verified brightness=\(restored, privacy: .public); withinTolerance=true")
        }
        guard resolved else { throw DisplayBrightnessError.controlsUnavailable }
        DisplayRecoveryJournal.clear(at: displayJournalURL)
    }
}

@MainActor
final class DimmerController: ObservableObject {
    @Published private(set) var angle: Double?
    @Published private(set) var rawSample: LidSample?
    @Published private(set) var keyboardBrightness: Double?
    @Published private(set) var displayBrightness: Double?
    @Published private(set) var displayStatus = L10n.string("Dimmer leaves automatic brightness unchanged.")
    @Published private(set) var errorMessage = L10n.string("Starting…")
    @Published private(set) var paused = false
    // UI setters clamp ranges before assignment; assigning a published value in its own observer can recurse.
    @Published var keyboardRange: DimRange {
        didSet { Self.persist(keyboardRange, key: "keyboardRange", defaults: defaults) }
    }
    @Published var screenRange: DimRange {
        didSet { Self.persist(screenRange, key: "screenRange", defaults: defaults) }
    }
    @Published var dimsScreen: Bool {
        didSet { defaults.set(dimsScreen, forKey: "dimsScreen") }
    }
    @Published var dimsKeyboard: Bool {
        didSet { defaults.set(dimsKeyboard, forKey: "dimsKeyboard") }
    }
    @Published private(set) var isDark = false
    private var darkness = 0.0
    private var darkTimer: Timer?
    private var darkAt: TimeInterval = 0
    private var darkStartAngle: Double?

    private let work = DispatchQueue(label: "uk.co.kalkmancode.dimmer.hardware")
    private let hardware: HardwareWorker
    private let pollGeneration = PollGeneration()
    private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "hardware")
    private var timer: Timer?
    private var keyboardRecoveryTimer: Timer?
    private let keyboardRecoveryGate = PollGeneration()
    private var lastHardwareLog = Date.distantPast
    private var retryAfter = Date.distantPast
    private var pollInFlight = false
    private var pollPending = false
    private var controlFailureNeedsResume = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, hardware: HardwareWorker = HardwareWorker()) {
        self.defaults = defaults
        self.hardware = hardware
        let keyboardData = defaults.data(forKey: "keyboardRange")
        let screenData = defaults.data(forKey: "screenRange")
        let migrated = keyboardData == nil && screenData == nil ? DimRange.migrated(
            offAt: defaults.object(forKey: "offAt") as? Double,
            fullAt: defaults.object(forKey: "fullAt") as? Double
        ) : nil
        keyboardRange = keyboardData.flatMap { try? JSONDecoder().decode(DimRange.self, from: $0) }
            ?? migrated ?? .keyboardDefault
        screenRange = screenData.flatMap { try? JSONDecoder().decode(DimRange.self, from: $0) }
            ?? migrated ?? .screenDefault
        dimsScreen = defaults.object(forKey: "dimsScreen") as? Bool ?? true
        dimsKeyboard = defaults.object(forKey: "dimsKeyboard") as? Bool ?? true
        Self.persist(keyboardRange, key: "keyboardRange", defaults: defaults)
        Self.persist(screenRange, key: "screenRange", defaults: defaults)
    }

    private static func persist(_ range: DimRange, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(range) else { return }
        defaults.set(data, forKey: key)
    }

    func start() {
        guard !paused else { return }
        pollPending = false
        timer?.invalidate()
        retryAfter = .distantPast
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused else { return }
                self.poll()
            }
        }
        timer?.tolerance = 0.03
        poll()
    }

    var canGoDark: Bool { !paused && !isDark && rawSample != nil }

    func goDark() {
        guard canGoDark else { return }
        isDark = true
        if DisplayAccessibility.shared.preferences.reduceMotion { darkness = 1 }
        darkAt = ProcessInfo.processInfo.systemUptime
        darkStartAngle = rawSample?.angle
        logger.info("go dark at angle=\(self.rawSample?.angle ?? -1, privacy: .public)°")
        runDarkTimer()
    }

    private func wakeFromDark() {
        guard isDark else { return }
        isDark = false
        if DisplayAccessibility.shared.preferences.reduceMotion { darkness = 0 }
        runDarkTimer()
    }

    private func cancelDark() {
        darkTimer?.invalidate()
        darkTimer = nil
        isDark = false
        darkness = 0
    }

    // One timer drives the fade either way and, while dark, watches for the input or lid move that
    // ends it; the hardware poll reads `darkness` and does the ramping and gamma work as it does for the lid.
    private func runDarkTimer() {
        guard darkTimer == nil else { return }
        var last = ProcessInfo.processInfo.systemUptime
        darkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let step = now - last
                last = now
                self.darkness = GoDark.nextDarkness(self.darkness, isDark: self.isDark, elapsed: step,
                                                   reduceMotion: DisplayAccessibility.shared.preferences.reduceMotion)
                if self.isDark {
                    let input = InputActivity.lastInput()
                    if GoDark.shouldWake(idleSeconds: input.seconds, now: now,
                                         darkAt: self.darkAt, angle: self.rawSample?.angle,
                                         startAngle: self.darkStartAngle) {
                        self.logger.info("go dark woken; last input \(input.kind, privacy: .public) \(input.seconds, privacy: .public) s ago, angle=\(self.rawSample?.angle ?? -1, privacy: .public)° from \(self.darkStartAngle ?? -1, privacy: .public)°")
                        self.wakeFromDark()
                    }
                } else {
                    if self.darkness == 0 {
                        self.darkTimer?.invalidate()
                        self.darkTimer = nil
                    }
                }
            }
        }
        darkTimer?.tolerance = 0.005
    }

    #if DEBUG
    // Tests drive the views through lid angles the sensor would report.
    func simulateLid(angle: Double?) {
        self.angle = angle
        rawSample = angle.map { LidSample(angle: $0, time: ProcessInfo.processInfo.systemUptime) }
    }
    #endif

    func togglePaused() {
        paused.toggle()
        cancelKeyboardRecovery()
        if paused {
            cancelDark()
            timer?.invalidate()
            timer = nil
            pollPending = false
            pollGeneration.cancel()
            work.async { [hardware] in hardware.restoreAndClose() }
            retryPausedRecovery()
            errorMessage = L10n.string("Paused.")
        } else {
            controlFailureNeedsResume = false
            angle = nil
            errorMessage = L10n.string("Reconnecting to lid sensor…")
            start()
        }
    }

    func prepareForSleep() {
        cancelDark()
        cancelKeyboardRecovery()
        timer?.invalidate()
        timer = nil
        pollGeneration.cancel()
        // Synchronous: the Mac may suspend the process before an async restore runs, leaving the screen
        // dim and the gamma black through sleep.
        work.sync { hardware.restoreAndClose(resetKeyboardYield: false) }
    }

    func resumeAfterWake() {
        // Hardware failures still require Pause and Resume; a keyboard yield keeps lid polling alive.
        if paused { retryPausedRecovery() }
        guard !paused, !controlFailureNeedsResume else { return }
        errorMessage = L10n.string("Reconnecting after sleep…")
        start()
    }

    func stop() {
        cancelDark()
        cancelKeyboardRecovery()
        timer?.invalidate()
        timer = nil
        pollGeneration.cancel()
        work.sync { hardware.restoreAndClose() }
    }

    private func retryPausedRecovery() {
        cancelKeyboardRecovery()
        let gate = keyboardRecoveryGate
        let generation = gate.current
        keyboardRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.paused, gate.isCurrent(generation) else { return }
                self.work.async { [weak self, hardware = self.hardware] in
                    // A timer task may already be queued when Resume cancels it. The worker serialises
                    // recovery with all hardware polls; reject cancelled work before touching journals.
                    guard gate.isCurrent(generation) else { return }
                    let resolved = (try? hardware.retryKeyboardRecovery()) == true
                    Task { @MainActor in
                        if let self, resolved, gate.isCurrent(generation) {
                            self.cancelKeyboardRecovery()
                        }
                    }
                }
            }
        }
        keyboardRecoveryTimer?.tolerance = 0.1
    }

    private func cancelKeyboardRecovery() {
        keyboardRecoveryGate.cancel()
        keyboardRecoveryTimer?.invalidate()
        keyboardRecoveryTimer = nil
    }

    private func poll() {
        guard !controlFailureNeedsResume, Date() >= retryAfter else { return }
        if pollInFlight {
            pollPending = true
            pollGeneration.cancel()
            return
        }
        pollInFlight = true
        let keyboardRange = keyboardRange
        let screenRange = screenRange
        let screen = dimsScreen
        let keyboard = dimsKeyboard
        let darkness = darkness
        let generation = pollGeneration.current
        let gate = pollGeneration
        work.async { [weak self, hardware] in
            let result: Result<HardwarePoll, Error>
            do {
                result = .success(try hardware.poll(keyboardRange: keyboardRange, screenRange: screenRange, dimsKeyboard: keyboard, dimsScreen: screen, darkness: darkness, generation: generation, gate: gate))
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in
                guard let self else { return }
                self.pollInFlight = false
                guard !self.paused else { return }
                switch result {
                case .success(let sample):
                    self.angle = sample.angle
                    self.rawSample = sample.sample
                    self.keyboardBrightness = sample.brightness
                    self.displayBrightness = sample.displayBrightness
                    self.displayStatus = sample.displayStatus
                    self.errorMessage = sample.keyboardStatus ?? "Active"
                    self.errorMessage = sample.keyboardStatus ?? L10n.string("Active")
                    if let written = sample.written {
                        self.lastHardwareLog = Date()
                        let target = keyboardRange.level(at: sample.angle)
                        self.logger.info("angle=\(sample.angle, privacy: .public)° target=\(target, privacy: .public) written=\(written, privacy: .public) readback=\(sample.brightness, privacy: .public)")
                    } else if Date().timeIntervalSince(self.lastHardwareLog) >= 10 {
                        self.lastHardwareLog = Date()
                        let target = keyboardRange.level(at: sample.angle)
                        self.logger.info("angle=\(sample.angle, privacy: .public)° target=\(target, privacy: .public) readback=\(sample.brightness, privacy: .public)")
                    }
                case .failure(let error):
                    if !(error is PollCancelled) {
                        self.rawSample = nil
                        self.angle = nil
                    }
                    if !(error is PollCancelled), error is BacklightError || (error as NSError).domain == "Dimmer" {
                        self.controlFailureNeedsResume = true
                        self.timer?.invalidate()
                        self.timer = nil
                    } else if !(error is PollCancelled) {
                        self.retryAfter = Date().addingTimeInterval(2)
                    }
                    if !(error is PollCancelled) { self.errorMessage = error.localizedDescription }
                }
                if self.pollPending {
                    self.pollPending = false
                    self.poll()
                }
            }
        }
    }
}
