import AppKit
import Combine
import IOKit.pwr_mgt
import Observation
import os

@MainActor
protocol PrivacyBlurOverlay: AnyObject {
    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool)
    func describe() -> String
    func stop()
}

extension PrivacyBlurOverlay {
    func describe() -> String { "visibility unavailable" }
}

// The angle lanes' live levels as Settings shows them, in whole percent, nil without a lid angle. Each changes only
// when what is shown does, so a lid sample redraws only the readouts that move.
@Observable
@MainActor
final class AngleLaneReading {
    fileprivate(set) var blurPercent: Int?
}

@Observable
@MainActor
final class VeilTintSettings {
    nonisolated static let defaultValue = 0.0
    private var storedValue: Double
    @ObservationIgnored var onChange: (() -> Void)?

    init(_ value: Double = defaultValue) { storedValue = Self.clamped(value) }

    var value: Double {
        get { storedValue }
        set {
            let next = Self.clamped(newValue)
            guard next != storedValue else { return }
            storedValue = next
            onChange?()
        }
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : defaultValue
    }
}

@Observable
@MainActor
final class DimmerFeatures {
    private(set) var awakeDuration: AwakeDuration = .off
    var awakeUntilTime = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: .now) ?? .now {
        didSet { if awakeDuration == .untilTime { applyAwakeAssertion() } }
    }
    var keepsDisplayAwake = false {
        didSet { if awakeDuration != .off { applyAwakeAssertion(preservingDeadline: true) } }
    }
    private(set) var awakeError: String?
    private(set) var awakeDeadline: Date?

    var privacyEnabled: Bool {
        didSet {
            defaults.set(privacyEnabled, forKey: "privacyBlurEnabled")
            if !privacyEnabled && manualLift == nil { clearPrivacyBlur(fade: 0) }
            updateOverlay()
        }
    }
    var privacyVeilEnabled: Bool {
        willSet { privacyVeilEnabledSubject.send(newValue) }
        didSet {
            defaults.set(privacyVeilEnabled, forKey: "privacyVeilEnabled")
            if !privacyVeilEnabled && veilUsesShortcutTint
                && (privacyBlurActive || veilLevel > 0 || veilTarget > 0) {
                clearPrivacyBlur(fade: 0)
            }
        }
    }
    @ObservationIgnored private let privacyVeilEnabledSubject: CurrentValueSubject<Bool, Never>
    var privacyVeilEnabledPublisher: AnyPublisher<Bool, Never> { privacyVeilEnabledSubject.eraseToAnyPublisher() }
    private var storedPrivacyVeilBlurStrength: Double
    var privacyVeilBlurStrength: Double {
        get { storedPrivacyVeilBlurStrength }
        set {
            let value = Self.clampedBlurStrength(newValue)
            guard value != storedPrivacyVeilBlurStrength else { return }
            storedPrivacyVeilBlurStrength = value
            defaults.set(value, forKey: "privacyVeilBlurStrength")
            updateOverlay()
        }
    }

    @ObservationIgnored private let snapObservation = ObservationRegistrar()
    @ObservationIgnored private var snapValues: SnapSettings {
        didSet {
            Self.persist(snap, key: "snapSettings", defaults: defaults)
            updateOverlay()
        }
    }
    private var snapBlurStrengthValue: Double
    var snapBlurStrength: Double {
        get { snapBlurStrengthValue }
        set { setSnapBlurStrengthValue(newValue) }
    }
    let snapTint: VeilTintSettings
    let angleBlurTint: VeilTintSettings
    let privacyVeilTint: VeilTintSettings

    // Zone geometry, restore controls and lid markers do not observe strength or tint edits.
    var snapConfiguration: SnapSettings {
        snapObservation.access(self, keyPath: \.snapConfiguration)
        return snapValues
    }
    var snapDegrees: Double {
        snapObservation.access(self, keyPath: \.snapDegrees)
        return snapValues.snapDegrees
    }
    var snapMinimumSpeed: Double {
        snapObservation.access(self, keyPath: \.snapMinimumSpeed)
        return snapValues.minimumSpeed
    }
    var snapClearSeconds: Double {
        snapObservation.access(self, keyPath: \.snapClearSeconds)
        return snapValues.clearSeconds
    }

    var snap: SnapSettings {
        get {
            var value = snapConfiguration
            value.blurStrength = snapBlurStrengthValue
            value.smoke = snapTint.value
            return value
        }
        set {
            snapTint.value = newValue.smoke
            setSnapBlurStrengthValue(newValue.blurStrength)
            var values = newValue
            values.blurStrength = 1
            values.smoke = 0
            if snapValues != values {
                // A zone drag must not invalidate the distance, speed or shortcut-clear controls;
                // their layout otherwise makes the grouped Form measure every unchanged preview.
                var changedControls: [KeyPath<DimmerFeatures, Double>] = []
                if snapValues.snapDegrees != values.snapDegrees { changedControls.append(\.snapDegrees) }
                if snapValues.minimumSpeed != values.minimumSpeed { changedControls.append(\.snapMinimumSpeed) }
                if snapValues.clearSeconds != values.clearSeconds { changedControls.append(\.snapClearSeconds) }
                for keyPath in changedControls { snapObservation.willSet(self, keyPath: keyPath) }
                snapObservation.withMutation(of: self, keyPath: \.snapConfiguration) { snapValues = values }
                for keyPath in changedControls { snapObservation.didSet(self, keyPath: keyPath) }
            }
        }
    }
    var angleBlurSmoke: Double {
        get { angleBlurTint.value }
        set { angleBlurTint.value = newValue }
    }
    var privacyVeilSmoke: Double {
        get { privacyVeilTint.value }
        set { privacyVeilTint.value = newValue }
    }
    private(set) var privacyBlurActive = false
    // The fourth lane: a blur that follows the lid angle, drawn in the same veil window as the snap veil.
    var angleBlurEnabled: Bool {
        didSet {
            defaults.set(angleBlurEnabled, forKey: "angleBlurEnabled")
            updateOverlay()
        }
    }
    var angleBlurRange: DimRange {
        didSet {
            Self.persist(angleBlurRange, key: "angleBlurRange", defaults: defaults)
            updateOverlay()
        }
    }
    // Set with every lid sample, so not published: Settings reads the lanes' levels from `laneReading`.
    @ObservationIgnored private(set) var lidAngle: Double?
    @ObservationIgnored let laneReading = AngleLaneReading()

    @ObservationIgnored private var assertionID: IOPMAssertionID?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var awakeScheduleID = UUID()
    @ObservationIgnored private var snapDetector = SnapDetector()
    @ObservationIgnored private var blurredAt: TimeInterval?
    @ObservationIgnored private var manualLift: ManualPrivacyLift?
    @ObservationIgnored private var veilUsesShortcutTint = false
    @ObservationIgnored private var inputGrace = SnapDetector.inputGrace
    @ObservationIgnored private var inputTimer: Timer?
    @ObservationIgnored private var veilLevel = 0.0
    @ObservationIgnored private var veilTarget = 0.0
    @ObservationIgnored private var veilTimer: Timer?
    @ObservationIgnored private var veilFallingDuration: TimeInterval = 0.35
    @ObservationIgnored private var veilClearStartedAt: TimeInterval?
    @ObservationIgnored private var angleLaneHolds = Set<String>()
    @ObservationIgnored private let overlay: any PrivacyBlurOverlay
    @ObservationIgnored private let lastInput: () -> (seconds: Double, kind: String)
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private var accessibilityPreferences = DisplayAccessibility.shared.preferences
    @ObservationIgnored private var accessibilityChanges: AnyCancellable?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "privacy")

    init(defaults: UserDefaults = .standard, overlay: (any PrivacyBlurOverlay)? = nil,
         lastInput: @escaping () -> (seconds: Double, kind: String) = InputActivity.lastInput,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.overlay = overlay ?? DimmerBlurOverlayManager()
        self.lastInput = lastInput
        self.uptime = uptime
        privacyEnabled = defaults.object(forKey: "privacyBlurEnabled") as? Bool ?? false
        let savedPrivacyVeilEnabled = defaults.object(forKey: "privacyVeilEnabled") as? Bool ?? true
        privacyVeilEnabled = savedPrivacyVeilEnabled
        privacyVeilEnabledSubject = CurrentValueSubject(savedPrivacyVeilEnabled)
        let savedSnap = Self.loadSnapSettings(defaults: defaults)
        snapBlurStrengthValue = Self.clampedBlurStrength(savedSnap.blurStrength)
        let savedPrivacyVeilBlurStrength = Self.clampedBlurStrength(
            defaults.object(forKey: "privacyVeilBlurStrength") as? Double ?? savedSnap.blurStrength)
        storedPrivacyVeilBlurStrength = savedPrivacyVeilBlurStrength
        // The old shared value becomes Snap's value; save its copy for the shortcut before either is edited.
        defaults.set(savedPrivacyVeilBlurStrength, forKey: "privacyVeilBlurStrength")
        snapTint = VeilTintSettings(savedSnap.smoke)
        privacyVeilTint = VeilTintSettings(defaults.object(forKey: "privacyVeilSmoke") as? Double ?? savedSnap.smoke)
        // Persist the migration immediately: a later Snap tint edit must not become the shortcut's first value.
        defaults.set(privacyVeilTint.value, forKey: "privacyVeilSmoke")
        var snapBase = savedSnap
        snapBase.blurStrength = 1
        snapBase.smoke = 0
        snapValues = snapBase
        angleBlurTint = VeilTintSettings(defaults.object(forKey: "angleBlurSmoke") as? Double ?? VeilTintSettings.defaultValue)
        angleBlurEnabled = defaults.object(forKey: "angleBlurEnabled") as? Bool ?? false
        angleBlurRange = defaults.data(forKey: "angleBlurRange")
            .flatMap { try? JSONDecoder().decode(DimRange.self, from: $0) }?.clamped(maximum: LidAxis.maximum)
            ?? .blurDefault
        snapTint.onChange = { [weak self] in
            guard let self else { return }
            Self.persist(self.snap, key: "snapSettings", defaults: self.defaults)
            self.updateOverlay()
        }
        angleBlurTint.onChange = { [weak self] in
            guard let self else { return }
            self.defaults.set(self.angleBlurSmoke, forKey: "angleBlurSmoke")
            self.updateOverlay()
        }
        privacyVeilTint.onChange = { [weak self] in
            guard let self else { return }
            self.defaults.set(self.privacyVeilSmoke, forKey: "privacyVeilSmoke")
            self.updateOverlay()
        }
        accessibilityChanges = DisplayAccessibility.shared.$preferences.dropFirst().sink { [weak self] preferences in
            guard let self else { return }
            self.accessibilityPreferences = preferences
            if preferences.reduceMotion {
                self.setVeilTarget(self.veilTarget, fallingDuration: self.veilFallingDuration)
            }
            self.updateOverlay()
        }
    }

    func follow(_ controller: DimmerController) -> [AnyCancellable] {
        [
            controller.pausedPublisher.sink { [weak self] paused in
                Task { @MainActor in
                    if paused { self?.suspend(reason: "pause") }
                    self?.holdAngleLanes("pause", paused)
                }
            },
            controller.isDarkPublisher.sink { [weak self] dark in
                Task { @MainActor in self?.holdAngleLanes("dark", dark) }
            },
            controller.telemetry.$angle.sink { [weak self] angle in
                Task { @MainActor in
                    if angle == nil { self?.angleUnavailable() }
                    self?.setLidAngle(angle)
                }
            },
            controller.telemetry.$rawSample.compactMap { $0 }
                .sink { [weak self] sample in
                    Task { @MainActor in self?.update(sample: sample) }
                },
        ]
    }

    var awakeStatus: String? {
        if let awakeError { return awakeError }
        guard awakeDuration != .off else { return nil }
        if let awakeDeadline {
            let deadline = awakeDeadline
            return L10n.string("Keeps the Mac awake until \(deadline.formatted(date: .omitted, time: .shortened)).")
        }
        return L10n.string("Keeps the Mac awake indefinitely.")
    }

    func update(sample: LidSample) {
        if privacyBlurActive {
            let shouldClear = manualLift != nil
                ? manualLift?.shouldClear(at: sample.angle) == true
                : snapDetector.pushedBack(sample.angle, settings: snap)
            if shouldClear {
                let lowest = snapDetector.lowestAngle ?? sample.angle
                logger.info("snap blur cleared by lid push-back angle=\(sample.angle, privacy: .public)° lowest=\(lowest, privacy: .public)° fade=\(self.snap.clearSeconds * 1000, privacy: .public)ms")
                clearPrivacyBlur(fade: snap.clearSeconds)
            }
            return
        }
        guard privacyEnabled else { return }
        switch snapDetector.observe(sample, settings: snap) {
        case .snapped:
            logger.info("snap blur on angle=\(sample.angle, privacy: .public)° zone=\(self.snap.zoneLow, privacy: .public)–\(self.snap.zoneHigh, privacy: .public) speed≥\(self.snap.minimumSpeed, privacy: .public) strength=\(self.snap.blurStrength, privacy: .public) smoke=\(self.snap.smoke, privacy: .public)")
            manualLift = nil
            veilUsesShortcutTint = false
            lockPrivacyBlur(at: sample.time, inputGrace: SnapDetector.inputGrace)
        case .partial(let level):
            veilUsesShortcutTint = false
            if veilTarget == 0 { logger.info("snap veil starting angle=\(sample.angle, privacy: .public)° level=\(level, privacy: .public)") }
            if blurredAt == nil {
                blurredAt = sample.time
                inputGrace = 0
                startInputTimer()
            }
            setVeilTarget(level)
        case .none:
            // Only a partial veil fades here; otherwise a lid push-back's own clear fade would be slowed to 350 ms.
            guard veilTarget > 0 else { return }
            logger.info("snap veil faded, no snap, angle=\(sample.angle, privacy: .public)°")
            setVeilTarget(0)
        }
    }

    func activatePrivacyBlurFromShortcut(at time: TimeInterval, angle: Double?) {
        guard privacyVeilEnabled else { return }
        let shortcutStartedAt = ProcessInfo.processInfo.systemUptime
        snapDetector.reset()
        manualLift = ManualPrivacyLift(angle: angle)
        veilUsesShortcutTint = true
        lockPrivacyBlur(at: time, inputGrace: 0)
#if DEBUG
        logger.info("privacy shortcut to veil orderFront ms=\((ProcessInfo.processInfo.systemUptime - shortcutStartedAt) * 1000, privacy: .public)")
#endif
    }

    private func lockPrivacyBlur(at time: TimeInterval, inputGrace: TimeInterval) {
        privacyBlurActive = true
        blurredAt = time
        self.inputGrace = inputGrace
        startInputTimer()
        // A locked snap must show at full strength at once; fading in can leave a brief snap invisible.
        veilTimer?.invalidate()
        veilTimer = nil
        veilClearStartedAt = nil
        veilTarget = 1
        veilLevel = 1
        updateOverlay()
        logger.info("veil overlay \(self.overlay.describe(), privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.logger.info("veil overlay +0.5s \(self.overlay.describe(), privacy: .public)")
        }
    }

    // The veil eases in over 180 ms and out over the requested duration (350 ms for near misses).
    private func setVeilTarget(_ target: Double, fallingDuration: TimeInterval = 0.35) {
        veilTarget = target
        if target > 0 { veilClearStartedAt = nil }
        veilFallingDuration = fallingDuration
        if accessibilityPreferences.reduceMotion || fallingDuration == 0 {
            veilTimer?.invalidate()
            veilTimer = nil
            veilLevel = target
            updateOverlay()
            finishVeilClearIfNeeded()
            return
        }
        guard veilTimer == nil, abs(veilLevel - veilTarget) > 0.001 else { return }
        var last = ProcessInfo.processInfo.systemUptime
        veilTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                // A tick queued before the timer was replaced or stopped must not touch the new state.
                guard let self, self.veilTimer === timer else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let step = now - last
                last = now
                self.veilLevel = VeilTransition.level(from: self.veilLevel, to: self.veilTarget, elapsed: step,
                                                     fallingDuration: self.veilFallingDuration,
                                                     reduceMotion: self.accessibilityPreferences.reduceMotion)
                self.updateOverlay()
                if abs(self.veilLevel - self.veilTarget) < 0.001 {
                    // Land exactly on the target: a level left at 0.0005 would keep the veil window ordered in.
                    self.veilLevel = self.veilTarget
                    self.updateOverlay()
                    self.veilTimer?.invalidate()
                    self.veilTimer = nil
                    self.finishVeilClearIfNeeded()
                }
            }
        }
        veilTimer?.tolerance = 0.004
    }

    private func finishVeilClearIfNeeded() {
        if !privacyBlurActive && veilLevel == 0 && veilTarget == 0 {
            inputTimer?.invalidate()
            inputTimer = nil
            blurredAt = nil
        }
        guard let startedAt = veilClearStartedAt, veilLevel == 0 else { return }
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        logger.info("veil gone after \(elapsed, privacy: .public)ms")
        veilClearStartedAt = nil
    }

    func angleUnavailable() {
        if !privacyBlurActive { snapDetector.reset() }
    }

    // The smoothed lid angle, nil when the sensor is unavailable. The snap detector keeps the raw samples.
    func setLidAngle(_ angle: Double?) {
        // A sample queued before a hold was placed must not survive it: the blur returns with the next one.
        guard angleLaneHolds.isEmpty else { return }
        lidAngle = angle
        updateOverlay()
    }

    // Pause, sleep and Go dark drop the stale angle, so the veil returns only with the next sample
    // once the last hold is released.
    func holdAngleLanes(_ reason: String, _ held: Bool) {
        if held {
            angleLaneHolds.insert(reason)
            lidAngle = nil
        } else {
            angleLaneHolds.remove(reason)
        }
        updateOverlay()
    }

    var angleBlurStrength: Double {
        AngleLane.level(enabled: angleBlurEnabled, held: !angleLaneHolds.isEmpty,
                        reduceTransparency: accessibilityPreferences.reduceTransparency,
                        angle: lidAngle, range: angleBlurRange)
    }

    func setAwakeDuration(_ duration: AwakeDuration) {
        awakeDuration = duration
        applyAwakeAssertion()
    }

    func stop() {
        setAwakeDuration(.off)
        angleLaneHolds.insert("quit")
        clearPrivacyBlur(fade: 0)
        overlay.stop()
    }

    // Pause and sleep stop the lid samples that would lift the veil, so neither may leave the screen
    // blurred or the pointer hidden; the veil goes at once rather than fading.
    func suspend(reason: String) {
        guard privacyBlurActive || veilLevel > 0 else { return }
        logger.info("snap blur cleared by \(reason, privacy: .public)")
        clearPrivacyBlur(fade: 0)
        veilTimer?.invalidate()
        veilTimer = nil
        veilTarget = 0
        veilLevel = 0
        updateOverlay()
    }

    private func clearPrivacyBlur(fade: TimeInterval) {
        inputTimer?.invalidate()
        inputTimer = nil
        privacyBlurActive = false
        blurredAt = nil
        manualLift = nil
        inputGrace = SnapDetector.inputGrace
        snapDetector.reset()
        veilClearStartedAt = veilLevel > 0 || veilTarget > 0 ? ProcessInfo.processInfo.systemUptime : nil
        setVeilTarget(0, fallingDuration: fade)
        updateOverlay()
    }

    private func startInputTimer() {
        inputTimer?.invalidate()
        inputTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForInput() }
        }
        inputTimer?.tolerance = 0.02
    }

    private func checkForInput() {
        guard privacyBlurActive || veilTarget > 0 || veilLevel > 0, let blurredAt else { return }
        let input = lastInput()
        if SnapDetector.inputArrived(idleSeconds: input.seconds,
                                     now: uptime(),
                                     blurredAt: blurredAt, grace: inputGrace) {
            logger.info("snap blur cleared by input: \(input.kind, privacy: .public)")
            clearPrivacyBlur(fade: snap.clearSeconds)
        }
    }

    private static func loadSnapSettings(defaults: UserDefaults) -> SnapSettings {
        guard let data = defaults.data(forKey: "snapSettings"),
              let settings = try? JSONDecoder().decode(SnapSettings.self, from: data) else {
            return SnapSettings()
        }
        return settings.clamped(maximum: LidAxis.maximum)
    }

    private static func clampedBlurStrength(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 1
    }

    private func setSnapBlurStrengthValue(_ value: Double) {
        let value = Self.clampedBlurStrength(value)
        guard value != snapBlurStrengthValue else { return }
        snapBlurStrengthValue = value
        Self.persist(snap, key: "snapSettings", defaults: defaults)
        updateOverlay()
    }

    private static func persist<Value: Encodable>(_ settings: Value, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    private func updateOverlay() {
        let blur = lidAngle == nil ? nil : Int((angleBlurStrength * 100).rounded())
        if laneReading.blurPercent != blur { laneReading.blurPercent = blur }
        let snapShown = VeilAppearance.shouldShow(level: veilLevel, locked: privacyBlurActive,
                                                  reduceTransparency: accessibilityPreferences.reduceTransparency)
        let sourceStrength = veilUsesShortcutTint ? privacyVeilBlurStrength : snap.blurStrength
        let veil = VeilAppearance.combined(snap: snapShown ? sourceStrength * veilLevel : 0,
                                           smoke: veilUsesShortcutTint ? privacyVeilSmoke : snap.smoke,
                                           angle: angleBlurStrength, angleSmoke: angleBlurSmoke)
        overlay.update(privacyBlur: snapShown || angleBlurStrength > 0, strength: veil.strength, smoke: veil.smoke,
                       reduceTransparency: accessibilityPreferences.reduceTransparency)
        // The pointer is hidden only while the veil is up; a crash needs nothing here, because the window
        // server drops a connection's hidden cursor when the process exits.
        if privacyBlurActive {
            guard !CursorHider.isHidden else { return }
            CursorHider.hide()
            logger.info("pointer hidden=\(CursorHider.isHidden, privacy: .public) backgroundAllowed=\(CursorHider.backgroundAllowed, privacy: .public)")
        } else if CursorHider.isHidden {
            CursorHider.show()
            logger.info("pointer shown")
        }
    }

    private func applyAwakeAssertion(preservingDeadline: Bool = false) {
        let previousDeadline = preservingDeadline ? awakeDeadline : nil
        expiryTask?.cancel()
        expiryTask = nil
        awakeScheduleID = UUID()
        awakeDeadline = nil
        if let assertionID {
            IOPMAssertionRelease(assertionID)
            self.assertionID = nil
        }
        awakeError = nil
        guard awakeDuration != .off else { return }

        let type = keepsDisplayAwake
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
            : kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        var newAssertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(
            type,
            L10n.string("Dimmer keep awake") as CFString,
            L10n.string("Selected in the Dimmer menu bar panel") as CFString,
            L10n.string("Keep the Mac awake") as CFString,
            nil,
            0,
            nil,
            &newAssertion
        )
        guard result == kIOReturnSuccess else {
            awakeError = L10n.string("Could not create a keep-awake assertion (\(result)).")
            awakeDuration = .off
            return
        }
        assertionID = newAssertion

        let deadline = previousDeadline ?? AwakeSchedule.deadline(
            for: awakeDuration,
            startedAt: Date(),
            untilTime: awakeUntilTime
        )
        guard let deadline else { return }
        awakeDeadline = deadline
        let delay = deadline.timeIntervalSinceNow
        guard delay > 0 else {
            setAwakeDuration(.off)
            return
        }
        let expectedDuration = awakeDuration
        let expectedScheduleID = awakeScheduleID
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.awakeDuration == expectedDuration,
                  self.awakeScheduleID == expectedScheduleID else { return }
            self.setAwakeDuration(.off)
        }
    }
}

@MainActor
private final class DimmerBlurOverlayManager: PrivacyBlurOverlay {
    private var windows: [CGDirectDisplayID: DimmerBlurWindow] = [:]

    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {
        // Mirroring and some display adapters can report one display ID twice.
        let activeScreens = Dictionary(
            NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen) } },
            uniquingKeysWith: { first, _ in first }
        )
        for displayID in Array(windows.keys) where activeScreens[displayID] == nil {
            windows.removeValue(forKey: displayID)?.close()
        }
        guard privacyBlur else {
            dismiss()
            return
        }
        for (displayID, screen) in activeScreens {
            let window = windows[displayID] ?? makeWindow(screen: screen, displayID: displayID)
            window.setFrame(screen.frame, display: false)
            window.alphaValue = VeilAppearance.opacity(strength: strength, reduceTransparency: reduceTransparency)
            window.isOpaque = reduceTransparency
            window.backgroundColor = reduceTransparency ? VeilAppearance.opaqueColour(smoke: smoke) : .clear
            window.blurView.update(smoke: smoke, reduceTransparency: reduceTransparency)
            window.ignoresMouseEvents = true
            if !window.isVisible { window.orderFrontRegardless() }
        }
    }

    // For the log: what is really on screen, so a snap that shows nothing can be told apart from a
    // detector that never fired. The sampler reads this in Release too.
    func describe() -> String {
        windows.values.map { window in
            let server = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber))
                as? [[String: Any]])?.first
            func field(_ key: CFString) -> String { server?[key as String].map { "\($0)" } ?? "nil" }
            let local: String = "visible=\(window.isVisible) onScreen=\(window.isOnActiveSpace) alpha=\(window.blurView.alphaValue)"
                + " windowAlpha=\(window.alphaValue) occluded=\(!window.occlusionState.contains(.visible))"
            let state: String = " frame=\(NSStringFromRect(window.frame)) blurState=\(window.blurView.state.rawValue)"
                + " tint=\(window.blurView.tintAlpha)"
            let remote: String = " server[onscreen=\(field(kCGWindowIsOnscreen)) alpha=\(field(kCGWindowAlpha))"
                + " layer=\(field(kCGWindowLayer)) bounds=\(field(kCGWindowBounds))]"
            return local + state + remote
        }
        .joined(separator: "; ").ifEmpty("no windows")
    }

    func dismiss() {
        windows.values.forEach {
            $0.orderOut(nil)
            $0.alphaValue = 0
        }
    }

    func stop() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
    }

    private func makeWindow(screen: NSScreen, displayID: CGDirectDisplayID) -> DimmerBlurWindow {
        let blurView = DimmerBlurView(frame: screen.frame)
        let window = DimmerBlurWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = blurView
        window.blurView = blurView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        windows[displayID] = window
        return window
    }
}

@MainActor
private final class DimmerBlurWindow: NSWindow {
    var blurView: DimmerBlurView!

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DimmerBlurView: NSVisualEffectView {
    // Smoke: black laid over the same blur, so the veil darkens but still shows soft shapes beneath.
    private let tint = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.cgColor
        tint.alphaValue = 0
        tint.frame = bounds
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var tintAlpha: CGFloat { tint.alphaValue }

    func update(smoke: Double, reduceTransparency: Bool) {
        tint.layer?.backgroundColor = reduceTransparency ? VeilAppearance.opaqueColour(smoke: smoke).cgColor : NSColor.black.cgColor
        tint.alphaValue = reduceTransparency ? 1 : min(max(smoke, 0), 1) * SnapSettings.maximumSmoke
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
