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
        defer { lock.unlock() }
        guard generation == value else { return false }
        try action()
        return true
    }
}

private final class HardwareWorker: @unchecked Sendable {
    private var sensor: LidAngleSensor?
    private var backlight: KeyboardBacklight?
    private var journal: RecoveryJournal?
    private var display: DisplayBrightness?
    private var displayJournal: DisplayRecoveryJournal?
    private var smoothedAngle: Double?
    private var yieldedControl = false
    private var displayYielded = false
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
        let displaySample = updateDisplay(angle: angle, offAt: offAt, fullAt: fullAt, enabled: dimsScreen)
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

    private func updateDisplay(angle: Double, offAt: Double, fullAt: Double, enabled: Bool) -> (brightness: Double?, status: String) {
        guard enabled else {
            restoreDisplay()
            return (nil, "Screen dimming is off.")
        }
        if angle >= fullAt {
            restoreDisplay()
            displayYielded = false
            return (try? display?.read(), "Screen ready.")
        }
        guard !displayYielded else {
            return (try? display?.read(), "Screen dimming paused after a brightness change.")
        }
        guard Date() >= displayRetryAfter else { return (nil, "Screen dimming will retry shortly.") }

        do {
            if display == nil {
                display = try DisplayBrightness()
                try recoverStaleDisplayState()
            }
            guard let display else { throw DisplayBrightnessError.controlsUnavailable }

            if displayJournal == nil {
                let original = try display.read()
                let captured = DisplayRecoveryJournal(originalBrightness: original, lastWritten: original)
                try captured.save()
                displayJournal = captured
                logger.info("display captured original=\(original, privacy: .public); automatic brightness unchanged; displayID=\(display.displayID, privacy: .public)")
            }

            guard var active = displayJournal else { throw DisplayBrightnessError.controlsUnavailable }
            let current = try display.read()
            if !active.owns(current) {
                yieldDisplay(current: current, reason: "display brightness changed outside Dimmer")
                return (current, "Screen dimming paused after a brightness change.")
            }

            let factor = BrightnessCurve.output(angle: angle, offAt: offAt, fullAt: fullAt)
            let target = DisplayBrightnessTarget.value(captured: active.originalBrightness, factor: factor)
            if abs(target - current) > 0.008 {
                active.pendingBrightness = target
                try active.save()
                displayJournal = active
                let actual = try display.write(target)
                active.lastWritten = actual
                active.pendingBrightness = nil
                try active.save()
                displayJournal = active
                logger.info("display angle=\(angle, privacy: .public)° target=\(target, privacy: .public) readback=\(actual, privacy: .public)")
                return (actual, "Screen dimming is active in yield mode.")
            }
            return (current, "Screen dimming is active in yield mode.")
        } catch {
            displayRetryAfter = Date().addingTimeInterval(2)
            logger.error("display dimming unavailable: \(error.localizedDescription, privacy: .public)")
            return (nil, error.localizedDescription)
        }
    }

    private func yieldDisplay(current: Double, reason: String) {
        DisplayRecoveryJournal.clear()
        displayJournal = nil
        displayYielded = true
        logger.info("display control yielded; brightness=\(current, privacy: .public); reason=\(reason, privacy: .public)")
    }

    private func restoreDisplay() {
        guard let display else { return }
        guard let active = displayJournal ?? DisplayRecoveryJournal.load() else {
            self.display = nil
            return
        }
        var resolved = false
        if let current = try? display.read() {
            if active.owns(current), !displayYielded {
                if let restored = try? display.write(active.originalBrightness) {
                    resolved = abs(restored - active.originalBrightness) <= 0.035
                    if resolved { logger.info("display restored brightness=\(restored, privacy: .public)") }
                }
            } else {
                resolved = true
            }
        }
        if resolved { DisplayRecoveryJournal.clear() }
        if resolved, let brightness = try? display.read() {
            logger.info("display restore verified brightness=\(brightness, privacy: .public); automatic brightness unchanged")
        }
        displayJournal = nil
        self.display = nil
    }

    private func recoverStaleDisplayState() throws {
        guard let stale = DisplayRecoveryJournal.load(), let display else { return }
        let current = try display.read()
        var resolved = !stale.owns(current)
        if stale.owns(current),
           let restored = try? display.write(stale.originalBrightness),
           abs(restored - stale.originalBrightness) <= 0.035 {
            resolved = true
            logger.info("display recovered brightness=\(restored, privacy: .public)")
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
    private var controlFailureNeedsResume = false

    init() {
        offAt = UserDefaults.standard.object(forKey: "offAt") as? Double ?? 30
        fullAt = UserDefaults.standard.object(forKey: "fullAt") as? Double ?? 85
        dimsScreen = UserDefaults.standard.object(forKey: "dimsScreen") as? Bool ?? true
    }

    func start() {
        guard !paused else { return }
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
        work.async { [hardware] in hardware.restoreAndClose() }
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
        guard !pollInFlight, !controlFailureNeedsResume, Date() >= retryAfter else { return }
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
                    if error is PollCancelled { return }
                    if error is BacklightError || (error as NSError).domain == "Dimmer" {
                        self.controlFailureNeedsResume = true
                        self.timer?.invalidate()
                        self.timer = nil
                    } else {
                        self.retryAfter = Date().addingTimeInterval(2)
                    }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
