import AppKit
import Combine
import Foundation
import os

private struct PollCancelled: Error {}

private final class PollGeneration: @unchecked Sendable {
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

private final class HardwareWorker: @unchecked Sendable {
    private var sensor: LidAngleSensor?
    private var backlight: KeyboardBacklight?
    private var journal: RecoveryJournal?
    private var display: DisplayBrightness?
    private var displayJournal: DisplayRecoveryJournal?
    private var displayLogic = DisplayDimmingLogic()
    private var smoothedAngle: Double?
    private var yieldedControl = false
    private var gammaActive = false
    private var lastGammaFactor: Double?
    private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "display")
    private var displayRetryAfter = Date.distantPast

    func poll(offAt: Double, fullAt: Double, dimsScreen: Bool, generation: Int, gate: PollGeneration) throws -> (angle: Double, brightness: Double, written: Double?, displayBrightness: Double?, displayStatus: String) {
        do {
            return try readAndApply(offAt: offAt, fullAt: fullAt, dimsScreen: dimsScreen, generation: generation, gate: gate)
        } catch {
            if !(error is PollCancelled) {
                if yieldedControl { restoreDisplay() }
                else { restoreAndClose() }
            }
            throw error
        }
    }

    private func readAndApply(offAt: Double, fullAt: Double, dimsScreen: Bool, generation: Int, gate: PollGeneration) throws -> (angle: Double, brightness: Double, written: Double?, displayBrightness: Double?, displayStatus: String) {
        guard !yieldedControl else {
            throw NSError(domain: "Dimmer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Keyboard brightness changed outside Dimmer; pause and resume to reconnect."])
        }
        if sensor == nil {
            let device = LidAngleSensor()
            try device.open()
            sensor = device
        }
        if backlight == nil {
            let control = try KeyboardBacklight()
            try recoverStaleState(with: control)
            backlight = control
        }
        let raw = try sensor!.readAngleDegrees()
        let angle = smoothedAngle.map { $0 * 0.65 + raw * 0.35 } ?? raw
        smoothedAngle = angle
        var written: Double?
        guard try gate.performIfCurrent(generation, action: { written = try apply(angle, offAt: offAt, fullAt: fullAt) }) else {
            throw PollCancelled()
        }
        let displaySample = try updateDisplay(angle: angle, offAt: offAt, fullAt: fullAt, enabled: dimsScreen,
                                              generation: generation, gate: gate)
        return (angle, try backlight!.read().brightness, written, displaySample.brightness, displaySample.status)
    }

    func restoreAndClose() {
        restoreDisplay()
        if let backlight, let journal {
            var resolved = false
            if let current = try? backlight.read() {
                if journal.owns(current.brightness) {
                    if let restored = try? backlight.write(journal.originalBrightness),
                       abs(restored - journal.originalBrightness) <= 0.035 {
                        resolved = true
                    }
                } else {
                    resolved = true
                }
                if journal.originalAutomatic && !current.automatic {
                    backlight.setAutomatic(true)
                    if (try? backlight.read().automatic) != true { resolved = false }
                }
            }
            if resolved { RecoveryJournal.clear() }
        } else if let backlight, RecoveryJournal.load() != nil {
            try? recoverStaleState(with: backlight)
        }
        journal = nil
        sensor?.close()
        sensor = nil
        backlight = nil
        smoothedAngle = nil
        yieldedControl = false
    }

    private func apply(_ angle: Double, offAt: Double, fullAt: Double) throws -> Double? {
        guard let backlight else { return nil }
        let current = try backlight.read()
        if journal == nil {
            journal = RecoveryJournal(originalBrightness: current.brightness,
                                      originalAutomatic: current.automatic,
                                      lastWritten: current.brightness)
            do { try journal?.save() } catch {
                journal = nil
                throw error
            }
        } else if let journal, abs(current.brightness - journal.lastWritten) > 0.035 || current.automatic {
            var automaticResolved = true
            if journal.originalAutomatic && !current.automatic {
                backlight.setAutomatic(true)
                automaticResolved = (try? backlight.read().automatic) == true
            }
            if automaticResolved { RecoveryJournal.clear() }
            self.journal = nil
            yieldedControl = true
            throw NSError(domain: "Dimmer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Keyboard brightness changed outside Dimmer; control paused to respect it."])
        }
        if current.automatic {
            backlight.setAutomatic(false)
            guard try !backlight.read().automatic else { throw BacklightError.automaticModeMismatch }
        }
        let output = BrightnessCurve.output(angle: angle, offAt: offAt, fullAt: fullAt)
        if abs(output - current.brightness) > 0.008 {
            var pending = journal!
            pending.pendingBrightness = output
            try pending.save()
            journal = pending
            let actual = try backlight.write(output)
            pending.lastWritten = actual
            pending.pendingBrightness = nil
            journal = pending
            try pending.save()
            guard abs(actual - output) <= 0.035 else { throw BacklightError.writeMismatch }
            return actual
        }
        return nil
    }

    private func recoverStaleState(with client: KeyboardBacklight) throws {
        guard let stale = RecoveryJournal.load() else { return }
        let current = try client.read()
        var brightnessResolved = !stale.owns(current.brightness)
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
            brightnessResolved = true
        }
        var automaticResolved = true
        if stale.originalAutomatic && !current.automatic {
            client.setAutomatic(true)
            automaticResolved = try client.read().automatic
        }
        guard brightnessResolved && automaticResolved else { throw BacklightError.automaticModeMismatch }
        RecoveryJournal.clear()
    }

    private func updateDisplay(angle: Double, offAt: Double, fullAt: Double, enabled: Bool,
                               generation: Int, gate: PollGeneration) throws -> (brightness: Double?, status: String) {
        guard enabled else {
            let hasRecovery = displayLogic.baseline != nil || displayJournal != nil || DisplayRecoveryJournal.load() != nil || gammaActive
            if hasRecovery {
                restoreDisplay()
                displayLogic.reset()
            }
            return (nil, "Screen dimming is off.")
        }

        if display == nil {
            do {
                display = try DisplayBrightness()
                try recoverStaleDisplayState()
            } catch {
                displayRetryAfter = Date().addingTimeInterval(2)
                logger.error("display dimming unavailable: \(error.localizedDescription, privacy: .public)")
                return (nil, error.localizedDescription)
            }
        }

        if angle >= fullAt {
            var didRestore = false
            let journalBaseline = displayJournal?.originalBrightness ?? DisplayRecoveryJournal.load()?.originalBrightness
            if let baseline = displayLogic.isDimming ? displayLogic.prepareRestore() : journalBaseline {
                didRestore = true
                guard restoreDisplay(to: baseline) else {
                    return (try? display?.read(), "Display brightness restoration is retrying.")
                }
            } else if gammaActive {
                restoreGamma(display: display)
            }
            do {
                let current = try display?.read()
                if let current {
                    if didRestore { return (current, "Screen ready.") }
                    let previousBaseline = displayLogic.baseline
                    let decision = displayLogic.update(angle: angle, current: current, offAt: offAt, fullAt: fullAt)
                    if case .capture(let value) = decision {
                        if previousBaseline == nil || abs(previousBaseline! - value) > 0.035 {
                            logger.info("display captured original=\(value, privacy: .public); automatic brightness unchanged; displayID=\(self.display!.displayID, privacy: .public)")
                        }
                    }
                    return (current, "Screen ready.")
                }
                return (nil, "Screen dimming is unavailable.")
            } catch {
                return (nil, error.localizedDescription)
            }
        }
        guard Date() >= displayRetryAfter else { return (nil, "Screen dimming will retry shortly.") }

        do {
            guard let display else { throw DisplayBrightnessError.controlsUnavailable }
            let current = try display.read()
            switch displayLogic.update(angle: angle, current: current, offAt: offAt, fullAt: fullAt) {
            case .capture:
                return (current, "Screen ready.")
            case .waitForOpen:
                return (current, "Screen dimming waits for the lid to open fully once.")
            case .restore(let baseline):
                _ = restoreDisplay(to: baseline)
                return (try? display.read(), "Screen ready.")
            case .dim(let target, let override):
                if displayJournal == nil {
                    guard let baseline = displayLogic.baseline else { throw DisplayBrightnessError.controlsUnavailable }
                    let captured = DisplayRecoveryJournal(originalBrightness: baseline, lastWritten: baseline)
                    try captured.save()
                    displayJournal = captured
                }
                guard var active = displayJournal else { throw DisplayBrightnessError.controlsUnavailable }
                if override {
                    logger.info("display override; automatic brightness changed during close; target will be enforced until reopen")
                }
                active.pendingBrightness = target
                try active.save()
                displayJournal = active
                let gammaFactor = DisplayGammaFade.factor(angle: angle, offAt: offAt, fullAt: fullAt)
                let ramp = try rampDisplay(brightness: target, gammaFactor: gammaFactor, display: display,
                                           generation: generation, gate: gate)
                guard ramp.completed else { throw PollCancelled() }
                let actual: Double
                if let value = ramp.brightness { actual = value }
                else { actual = try display.read() }
                active = displayJournal ?? active
                active.lastWritten = actual
                active.pendingBrightness = nil
                try active.save()
                displayJournal = active
                displayLogic.markWritten(actual)
                logger.info("display angle=\(angle, privacy: .public)° target=\(target, privacy: .public) readback=\(actual, privacy: .public)")
                return (actual, "Screen dimming is active.")
            case .idle:
                return (current, "Screen ready.")
            }
        } catch {
            if error is PollCancelled { throw error }
            displayRetryAfter = Date().addingTimeInterval(2)
            logger.error("display dimming unavailable: \(error.localizedDescription, privacy: .public)")
            return (nil, error.localizedDescription)
        }
    }

    private func rampDisplay(brightness targetBrightness: Double?, gammaFactor targetGamma: Double?,
                             display: DisplayBrightness, generation: Int?, gate: PollGeneration?,
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
                    try journal.save()
                    displayJournal = journal
                }
                brightness = try display.write(next)
                if var journal = displayJournal {
                    journal.lastWritten = brightness
                    journal.pendingBrightness = nil
                    try journal.save()
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
        let baseline = (displayLogic.isDimming ? displayLogic.prepareRestore() : nil) ?? displayJournal?.originalBrightness ?? DisplayRecoveryJournal.load()?.originalBrightness
        if let baseline { _ = restoreDisplay(to: baseline) }
        else if gammaActive { restoreGamma(display: display) }
    }

    @discardableResult
    private func restoreDisplay(to baseline: Double) -> Bool {
        let device = display ?? (try? DisplayBrightness())
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
            DisplayRecoveryJournal.clear()
            displayJournal = nil
        }
        return resolved
    }

    private func restoreGamma(display: DisplayBrightness?) {
        DisplayBrightness.restoreGamma()
        display?.clearCapturedGamma()
        logger.info("display gamma off; ColorSync settings restored")
        gammaActive = false
        lastGammaFactor = nil
    }

    private func recoverStaleDisplayState() throws {
        guard let stale = DisplayRecoveryJournal.load(), let display else { return }
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
        DisplayRecoveryJournal.clear()
    }
}

@MainActor
final class DimmerController: ObservableObject {
    @Published private(set) var angle: Double?
    @Published private(set) var keyboardBrightness: Double?
    @Published private(set) var displayBrightness: Double?
    @Published private(set) var displayStatus = "Dimmer leaves automatic brightness unchanged."
    @Published private(set) var errorMessage = "Starting…"
    @Published private(set) var paused = false
    // Assigning a @Published property inside its own didSet re-enters didSet, so clamp only when the
    // value is out of range; an unconditional reassignment recursed until the stack overflowed (the crash
    // on moving either slider in a pre-release build).
    @Published var offAt: Double {
        didSet {
            let clamped = min(max(0, offAt), fullAt - 1)
            if clamped != offAt { offAt = clamped; return }
            UserDefaults.standard.set(offAt, forKey: "offAt")
        }
    }
    @Published var fullAt: Double {
        didSet {
            let clamped = max(offAt + 1, min(140, fullAt))
            if clamped != fullAt { fullAt = clamped; return }
            UserDefaults.standard.set(fullAt, forKey: "fullAt")
        }
    }
    @Published var dimsScreen: Bool {
        didSet { UserDefaults.standard.set(dimsScreen, forKey: "dimsScreen") }
    }

    private let work = DispatchQueue(label: "uk.co.kalkmancode.dimmer.hardware")
    private let hardware = HardwareWorker()
    private let pollGeneration = PollGeneration()
    private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "hardware")
    private var timer: Timer?
    private var lastHardwareLog = Date.distantPast
    private var retryAfter = Date.distantPast
    private var pollInFlight = false
    private var pollPending = false
    private var controlFailureNeedsResume = false

    init() {
        offAt = UserDefaults.standard.object(forKey: "offAt") as? Double ?? 30
        fullAt = UserDefaults.standard.object(forKey: "fullAt") as? Double ?? 85
        dimsScreen = UserDefaults.standard.object(forKey: "dimsScreen") as? Bool ?? true
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

    func togglePaused() {
        paused.toggle()
        if paused {
            timer?.invalidate()
            timer = nil
            pollPending = false
            pollGeneration.cancel()
            work.async { [hardware] in hardware.restoreAndClose() }
            errorMessage = "Paused; original brightness restored."
        } else {
            controlFailureNeedsResume = false
            angle = nil
            errorMessage = "Reconnecting to lid sensor…"
            start()
        }
    }

    func prepareForSleep() {
        timer?.invalidate()
        timer = nil
        pollGeneration.cancel()
        // Synchronous: the Mac may suspend the process before an async restore runs, leaving the screen
        // dim and the gamma black through sleep.
        work.sync { hardware.restoreAndClose() }
    }

    func resumeAfterWake() {
        // After the user has taken the backlight back (brightness keys), stay out of the way until they
        // Pause and Resume; the yield message already says so.
        guard !paused, !controlFailureNeedsResume else { return }
        errorMessage = "Reconnecting after sleep…"
        start()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pollGeneration.cancel()
        work.sync { hardware.restoreAndClose() }
    }

    private func poll() {
        guard !controlFailureNeedsResume, Date() >= retryAfter else { return }
        if pollInFlight {
            pollPending = true
            pollGeneration.cancel()
            return
        }
        pollInFlight = true
        let low = offAt
        let high = fullAt
        let screen = dimsScreen
        let generation = pollGeneration.current
        let gate = pollGeneration
        work.async { [weak self, hardware] in
            let result: Result<(angle: Double, brightness: Double, written: Double?, displayBrightness: Double?, displayStatus: String), Error>
            do {
                result = .success(try hardware.poll(offAt: low, fullAt: high, dimsScreen: screen, generation: generation, gate: gate))
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
                    self.keyboardBrightness = sample.brightness
                    self.displayBrightness = sample.displayBrightness
                    self.displayStatus = sample.displayStatus
                    self.errorMessage = "Active"
                    if let written = sample.written {
                        self.lastHardwareLog = Date()
                        let target = BrightnessCurve.output(angle: sample.angle, offAt: low, fullAt: high)
                        self.logger.info("angle=\(sample.angle, privacy: .public)° target=\(target, privacy: .public) written=\(written, privacy: .public) readback=\(sample.brightness, privacy: .public)")
                    } else if Date().timeIntervalSince(self.lastHardwareLog) >= 10 {
                        self.lastHardwareLog = Date()
                        let target = BrightnessCurve.output(angle: sample.angle, offAt: low, fullAt: high)
                        self.logger.info("angle=\(sample.angle, privacy: .public)° target=\(target, privacy: .public) readback=\(sample.brightness, privacy: .public)")
                    }
                case .failure(let error):
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
