import AppKit
import Combine
import IOKit.pwr_mgt
import os

@MainActor
protocol PrivacyBlurOverlay: AnyObject {
    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool)
    #if DEBUG
    func describe() -> String
    #endif
    func stop()
}

@MainActor
final class DimmerFeatures: ObservableObject {
    @Published private(set) var awakeDuration: AwakeDuration = .off
    @Published var awakeUntilTime = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: .now) ?? .now {
        didSet { if awakeDuration == .untilTime { applyAwakeAssertion() } }
    }
    @Published var keepsDisplayAwake = false {
        didSet { if awakeDuration != .off { applyAwakeAssertion(preservingDeadline: true) } }
    }
    @Published private(set) var awakeError: String?
    @Published private(set) var awakeDeadline: Date?

    @Published var privacyEnabled: Bool {
        didSet {
            defaults.set(privacyEnabled, forKey: "privacyBlurEnabled")
            if !privacyEnabled && manualLift == nil { clearPrivacyBlur(fade: 0) }
            updateOverlay()
        }
    }
    @Published var snap: SnapSettings {
        didSet {
            Self.persist(snap, key: "snapSettings", defaults: defaults)
            updateOverlay()
        }
    }
    @Published private(set) var privacyBlurActive = false

    private var assertionID: IOPMAssertionID?
    private var expiryTask: Task<Void, Never>?
    private var awakeScheduleID = UUID()
    private var snapDetector = SnapDetector()
    private var blurredAt: TimeInterval?
    private var manualLift: ManualPrivacyLift?
    private var inputGrace = SnapDetector.inputGrace
    private var inputTimer: Timer?
    private var veilLevel = 0.0
    private var veilTarget = 0.0
    private var veilTimer: Timer?
    private var veilFallingDuration: TimeInterval = 0.35
    private var veilClearStartedAt: TimeInterval?
    private let overlay: any PrivacyBlurOverlay
    private let lastInput: () -> (seconds: Double, kind: String)
    private let uptime: () -> TimeInterval
    private var accessibilityPreferences = DisplayAccessibility.shared.preferences
    private var accessibilityChanges: AnyCancellable?
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "uk.co.kalkmancode.Dimmer", category: "privacy")

    init(defaults: UserDefaults = .standard, overlay: (any PrivacyBlurOverlay)? = nil,
         lastInput: @escaping () -> (seconds: Double, kind: String) = InputActivity.lastInput,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.overlay = overlay ?? DimmerBlurOverlayManager()
        self.lastInput = lastInput
        self.uptime = uptime
        privacyEnabled = defaults.object(forKey: "privacyBlurEnabled") as? Bool ?? false
        snap = Self.loadSnapSettings(defaults: defaults)
        accessibilityChanges = DisplayAccessibility.shared.$preferences.dropFirst().sink { [weak self] preferences in
            guard let self else { return }
            self.accessibilityPreferences = preferences
            if preferences.reduceMotion {
                self.setVeilTarget(self.veilTarget, fallingDuration: self.veilFallingDuration)
            }
            self.updateOverlay()
        }
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
            lockPrivacyBlur(at: sample.time, inputGrace: SnapDetector.inputGrace)
        case .partial(let level):
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
        snapDetector.reset()
        manualLift = ManualPrivacyLift(angle: angle)
        lockPrivacyBlur(at: time, inputGrace: 0)
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
        #if DEBUG
        logger.info("veil overlay \(self.overlay.describe(), privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.logger.info("veil overlay +0.5s \(self.overlay.describe(), privacy: .public)")
        }
        #endif
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

    func setAwakeDuration(_ duration: AwakeDuration) {
        awakeDuration = duration
        applyAwakeAssertion()
    }

    func stop() {
        setAwakeDuration(.off)
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
            clearPrivacyBlur(fade: 0)
        }
    }

    private static func loadSnapSettings(defaults: UserDefaults) -> SnapSettings {
        guard let data = defaults.data(forKey: "snapSettings"),
              let settings = try? JSONDecoder().decode(SnapSettings.self, from: data) else {
            return SnapSettings()
        }
        return settings.clamped(maximum: LidAxis.maximum)
    }

    private static func persist(_ settings: SnapSettings, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    private func updateOverlay() {
        overlay.update(privacyBlur: VeilAppearance.shouldShow(level: veilLevel, locked: privacyBlurActive,
                                                            reduceTransparency: accessibilityPreferences.reduceTransparency),
                       strength: snap.blurStrength * veilLevel, smoke: snap.smoke,
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

    #if DEBUG
    // For the log: what is really on screen, so a snap that shows nothing can be told apart from a
    // detector that never fired.
    func describe() -> String {
        windows.values.map { window in
            let server = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber))
                as? [[String: Any]])?.first
            return "visible=\(window.isVisible) onScreen=\(window.isOnActiveSpace) alpha=\(window.blurView.alphaValue)"
                + " windowAlpha=\(window.alphaValue) occluded=\(!window.occlusionState.contains(.visible))"
                + " frame=\(NSStringFromRect(window.frame)) blurState=\(window.blurView.state.rawValue)"
                + " tint=\(window.blurView.tintAlpha) server[onscreen=\(server?[kCGWindowIsOnscreen as String] ?? "nil")"
                + " alpha=\(server?[kCGWindowAlpha as String] ?? "nil") layer=\(server?[kCGWindowLayer as String] ?? "nil")"
                + " bounds=\(server?[kCGWindowBounds as String].map { "\($0)" } ?? "nil")]"
        }
        .joined(separator: "; ").ifEmpty("no windows")
    }
    #endif

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

    #if DEBUG
    var tintAlpha: CGFloat { tint.alphaValue }
    #endif

    func update(smoke: Double, reduceTransparency: Bool) {
        tint.layer?.backgroundColor = reduceTransparency ? VeilAppearance.opaqueColour(smoke: smoke).cgColor : NSColor.black.cgColor
        tint.alphaValue = reduceTransparency ? 1 : min(max(smoke, 0), 1) * SnapSettings.maximumSmoke
    }
}

#if DEBUG
private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
#endif

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
