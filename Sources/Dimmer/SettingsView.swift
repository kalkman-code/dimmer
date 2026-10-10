import AppKit
import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject var controller: DimmerController
    @ObservedObject var features: DimmerFeatures
    @ObservedObject var shell: ShellPreferences
    @ObservedObject var login: LoginItem
    @State private var confirmHideMenuBarIcon = false
    @State private var hasPrivacyShortcut = KeyboardShortcuts.getShortcut(for: .privacyBlur) != nil

    private let bodyColour = Color(hex: 0x141416)
    private let secondaryText = Color(hex: 0x9A9EA7)
    private let controlWidth: CGFloat = 300

    init(controller: DimmerController, features: DimmerFeatures, shell: ShellPreferences, login: LoginItem) {
        self.controller = controller
        self.features = features
        self.shell = shell
        self.login = login
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    statusLine
                    LidAxisView(controller: controller, features: features)
                }
                // The Form's own section is the card; a second background here drew a card inside a card.
                .padding(.vertical, 4)
            }

            Section(L10n.string("Snap to blur")) {
                Toggle(isOn: $features.privacyEnabled) {
                    settingLabel(L10n.string("Blur when the lid is snapped into the zone"),
                                 detail: L10n.string("Snap the lid down into the zone and every screen frosts at once. Typing, touching the trackpad or mouse, or pushing the lid back up clears it."))
                }
                .toggleStyle(.switch)
                .accessibilityLabel(L10n.string("Blur when the lid is snapped into the zone"))
                .padding(.vertical, 2)

                HStack(spacing: 12) {
                    settingLabel(L10n.string("Privacy shortcut"), detail: L10n.string("Blurs every screen from any app, even with snap off; any input clears it. Click it to record your own."))
                    Spacer(minLength: 8)
                    // The recorder's own field is a borderless grey placeholder that read as disabled text;
                    // in testing it was not found. The outline makes it read as a control.
                    KeyboardShortcuts.Recorder(for: .privacyBlur, onChange: { shortcut in
                        hasPrivacyShortcut = shortcut != nil
                        NotificationCenter.default.post(name: .dimmerPrivacyShortcutDidChange, object: nil)
                    })
                    .shortcutValidation { shortcut in
                        let blocked: [NSEvent.ModifierFlags] = [
                            [.command], [.command, .shift], [.control, .option, .command],
                            [.command, .shift, .option], [.control, .option, .shift, .command]
                        ]
                        if shortcut.key == .p && blocked.contains(shortcut.modifiers) {
                            return .disallow(reason: L10n.string("This shortcut is used by printing, applications or accessibility. Choose another combination."))
                        }
                        return .allow
                    }
                    .accessibilityLabel(L10n.string("Privacy shortcut"))
                    .frame(minWidth: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0x8EA2C9), lineWidth: 1))
                }
                .padding(.vertical, 4)

                settingRow(L10n.string("Snap of at least"), detail: L10n.string("How far the lid must drop into the zone."),
                           value: snapBinding(\.snapDegrees), range: 1...40, unit: "°")
                settingRow(L10n.string("Snap speed"), detail: L10n.string("Slower closes pass through without blurring."),
                           value: snapBinding(\.minimumSpeed), range: 10...300, unit: "°/s", step: 5)
                settingRow(L10n.string("Clear speed"), detail: L10n.string("How long the veil takes to fade once it clears."),
                           value: Binding(get: { features.snap.clearSeconds * 1000 },
                                          set: { setSnap(\.clearSeconds, $0 / 1000) }),
                           range: 0...600, unit: "ms", step: 10, sliderEnds: (L10n.string("Instant"), L10n.string("Slow")), available: features.privacyEnabled || hasPrivacyShortcut)
                settingRow(L10n.string("Blur strength"), detail: strengthNote,
                           value: Binding(get: { features.snap.blurStrength * 100 },
                                          set: { setSnap(\.blurStrength, $0 / 100) }),
                           range: 0...100, unit: "%", available: features.privacyEnabled || hasPrivacyShortcut)
                settingRow(L10n.string("Tint"), detail: smokeNote,
                           value: Binding(get: { features.snap.smoke * 100 },
                                          set: { setSnap(\.smoke, $0 / 100) }),
                           range: 0...100, unit: "%", sliderEnds: (L10n.string("Frost"), L10n.string("Smoke")), available: features.privacyEnabled || hasPrivacyShortcut)

                previewRow
            }

            Section(L10n.string("Keep awake")) {
                HStack(spacing: 10) {
                    settingLabel(L10n.string("Keep the Mac awake"), detail: awakeStatus)
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Picker(L10n.string("Keep the Mac awake"), selection: Binding(
                            get: { features.awakeDuration },
                            set: { features.setAwakeDuration($0) }
                        )) {
                            ForEach(AwakeDuration.allCases) { duration in
                                Text(duration == .untilTime ? L10n.string("Until a time") : duration.title).tag(duration)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        if features.awakeDuration == .untilTime {
                            DatePicker(L10n.string("Until"), selection: $features.awakeUntilTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .fixedSize()
                        }
                    }
                }
                .frame(minHeight: 42)

                HStack {
                    Text(L10n.string("Keep the display awake too")).font(.system(size: 13))
                    Spacer()
                    Toggle(L10n.string("Keep the display awake too"), isOn: $features.keepsDisplayAwake)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(features.awakeDuration == .off)
                }
                .frame(minHeight: 36)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { shell.showMenuBarIcon },
                    set: { visible in
                        if visible { shell.showMenuBarIcon = true }
                        else { confirmHideMenuBarIcon = true }
                    }
                )) {
                    settingLabel(L10n.string("Show in menu bar"), detail: L10n.string("Open Dimmer from Applications or Spotlight to return to Settings."))
                }
                .toggleStyle(.switch)
                .accessibilityLabel(L10n.string("Show in menu bar"))
                .frame(minHeight: 42)
                HStack {
                    Text(L10n.string("Launch at Login")).font(.system(size: 13))
                    Spacer()
                    Toggle(L10n.string("Launch at Login"), isOn: Binding(
                        get: { login.isOn },
                        set: { login.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .frame(minHeight: 36)
                Text(login.message)
                    .font(.system(size: 11))
                    .foregroundStyle(login.errorMessage == nil ? secondaryText : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                if login.status == .requiresApproval {
                    Button(L10n.string("Open Login Items…")) { login.openLoginItems() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(bodyColour)
        .tint(Color(hex: 0x6F84AD))
        .padding(.horizontal, 4)
        .frame(minWidth: 680, idealWidth: 760, maxWidth: .infinity)
        .sheet(isPresented: $shell.showWelcome) {
            ViewThatFits(in: .vertical) {
                welcomeContent
                ScrollView { welcomeContent }
            }
            .frame(width: 520)
            .frame(maxHeight: welcomeMaxHeight)
        }
        .alert(L10n.string("Hide Dimmer from the menu bar?"), isPresented: $confirmHideMenuBarIcon) {
            Button(L10n.string("Hide icon")) { shell.showMenuBarIcon = false }
            Button(L10n.string("Cancel"), role: .cancel) { }
        } message: {
            Text(L10n.string("Dimming keeps running. Open Dimmer from Applications or Spotlight to bring Settings back, where Show in menu bar puts the icon back."))
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("Welcome to Dimmer")).font(.title2.weight(.semibold))
            Text(L10n.string("Dimmer follows your MacBook’s lid angle to dim the keyboard and screen as it closes."))
            Text(L10n.string("The Dimmer icon lives in the menu bar. Choose Settings there to adjust the ranges. Opening Dimmer from Applications or Spotlight brings Settings back, even if the icon is hidden."))
            Text(L10n.string("Pause and Quit hand brightness back to you. Wake an idle-dimmed keyboard before quitting to restore it immediately. Keep awake prevents idle sleep for the time you choose; it does not keep a closed MacBook awake."))
            Toggle(L10n.string("Launch at Login"), isOn: Binding(
                get: { login.isOn },
                set: { login.setEnabled($0) }
            ))
            Text(login.message)
                .font(.callout).foregroundStyle(.secondary)
            if login.status == .requiresApproval {
                Button(L10n.string("Open Login Items…")) { login.openLoginItems() }
            }
            HStack {
                Spacer()
                Button(L10n.string("Start using Dimmer")) { shell.showWelcome = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
    }

    private var welcomeMaxHeight: CGFloat {
        max(1, (NSScreen.main?.visibleFrame.height ?? 800) - 100)
    }

    private var statusLine: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(nsImage: StatusGlyph.image(paused: controller.paused))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0xE2E5EA), Color(hex: 0xB9C8E6)],
                                                startPoint: .top, endPoint: .bottom))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: 0xE2E5EA))
                Text(statusDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        if controller.paused { return L10n.string("Paused") }
        return controller.errorMessage
    }

    private var statusDescription: String {
        if controller.paused { return L10n.string("Dimming is paused. Resume from the menu bar.") }
        if controller.errorMessage != L10n.string("Active") {
            return controller.angle == nil ? L10n.string("Waiting for the lid sensor.") : L10n.string("Screen and privacy control continue. Pause and resume to reconnect the keyboard.")
        }
        return switch (controller.dimsKeyboard, controller.dimsScreen) {
        case (true, true): L10n.string("Dimming the keyboard and the screen as the lid closes.")
        case (true, false): L10n.string("Dimming the keyboard as the lid closes.")
        case (false, true): L10n.string("Dimming the screen as the lid closes.")
        case (false, false): L10n.string("Dimming is off.")
        }
    }

    private func settingRow(_ title: String, detail: String, value: Binding<Double>, range: ClosedRange<Double>,
                            unit: String, step: Double = 1, sliderEnds: (String, String)? = nil, available: Bool? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { value.wrappedValue },
                    set: { raw in
                        let rounded = (raw / step).rounded() * step
                        value.wrappedValue = min(max(rounded, range.lowerBound), range.upperBound)
                    }
                ), in: range, step: step) { Text(title) }
                // In a grouped Form a Slider keeps an empty label column unless hidden, which pushed the
                // track 88 pt right and left it 108 pt long.
                .labelsHidden()
                .frame(width: 196)
                .tint(Color(hex: 0x8EA2C9))
                .accessibilityValue(AccessibilityReadout.value(value.wrappedValue, unit: unit))
                .accessibilityHint(AccessibilityReadout.range(range, unit: unit))
                numberField(title: title, value: value, range: range, step: step, unit: unit)
                Text(L10n.displayUnit(unit))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(secondaryText)
                    .frame(width: 24, alignment: .leading)
            }
            .frame(width: controlWidth, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                if let sliderEnds {
                    HStack {
                        Text(sliderEnds.0)
                        Spacer()
                        Text(sliderEnds.1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .frame(width: 196)
                    .offset(y: 13)
                }
            }
        }
        .frame(minHeight: sliderEnds == nil ? 36 : 48)
        .disabled(!(available ?? features.privacyEnabled))
        .opacity((available ?? features.privacyEnabled) ? 1 : 0.38)
    }

    private func numberField(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        PrivacyNumberField(title: title, value: value, range: range, step: step, unit: unit)
    }

    private var previewRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Preview")).font(.system(size: 13))
                Text(L10n.string("A page, as the veil leaves it."))
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            BlurPreview(strength: features.snap.blurStrength, smoke: features.snap.smoke)
                .frame(width: controlWidth, alignment: .leading)
        }
        .frame(minHeight: 68)
        .disabled(!features.privacyEnabled && !hasPrivacyShortcut)
        .opacity(features.privacyEnabled || hasPrivacyShortcut ? 1 : 0.38)
    }

    private var strengthNote: String {
        let strength = features.snap.blurStrength * 100
        if strength == 0 { return L10n.string("None: the zone does nothing visible.") }
        if strength < 50 { return L10n.string("Light: large text is still readable.") }
        if strength < 90 { return L10n.string("Medium: shapes show, words do not.") }
        return L10n.string("Full: nothing on screen is readable.")
    }

    private var smokeNote: String {
        switch features.snap.smoke {
        case ..<0.05: L10n.string("Frost: a light veil.")
        case ..<0.5: L10n.string("Light smoke: darker, the room sees less glow.")
        case ..<0.95: L10n.string("Smoke: dark glass over the screen.")
        default: L10n.string("Deep smoke: shapes only, nearly dark.")
        }
    }

    private var awakeStatus: String {
        if let error = features.awakeError { return error }
        switch features.awakeDuration {
        case .off: return L10n.string("The Mac sleeps as usual.")
        case .indefinitely: return L10n.string("Awake until you turn this off.")
        case .untilTime:
            return L10n.string("Until \(features.awakeUntilTime.formatted(date: .omitted, time: .shortened)).")
        default:
            let deadline = features.awakeDeadline ?? Date()
            return L10n.string("Until \(deadline.formatted(date: .omitted, time: .shortened)).")
        }
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(secondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func snapBinding(_ keyPath: WritableKeyPath<SnapSettings, Double>) -> Binding<Double> {
        Binding(get: { features.snap[keyPath: keyPath] }, set: { setSnap(keyPath, $0) })
    }

    private func setSnap(_ keyPath: WritableKeyPath<SnapSettings, Double>, _ value: Double) {
        var settings = features.snap
        settings[keyPath: keyPath] = value
        features.snap = settings.clamped(maximum: LidAxis.maximum)
    }
}

private struct PrivacyNumberField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(String(), text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .frame(width: 56, height: 22)
            .fixedSize()
            .focused($focused)
            .accessibilityLabel(L10n.string("\(title) exact value"))
            .accessibilityValue(AccessibilityReadout.value(Double(draft) ?? value, unit: unit))
            .accessibilityHint(AccessibilityReadout.rangeForNumberEntry(range, unit: unit))
            .onAppear(perform: resetDraft)
            .onSubmit { commit() }
            .onExitCommand {
                resetDraft()
                focused = false
            }
            .onChange(of: focused) { _, isFocused in
                if isFocused { resetDraft() } else { commit() }
            }
            .onChange(of: value) { _, _ in if !focused { resetDraft() } }
    }

    private func resetDraft() { draft = "\(Int(value.rounded()))" }

    private func commit() {
        if let typed = Double(draft), typed.isFinite {
            value = min(max((typed / step).rounded() * step, range.lowerBound), range.upperBound)
        }
        resetDraft()
    }
}

private struct BlurPreview: View {
    let strength: Double
    let smoke: Double
    @ObservedObject private var accessibility = DisplayAccessibility.shared

    private var tintReadout: String {
        smoke < 0.05 ? L10n.string("Frost") : L10n.string("Smoke \(Int((smoke * 100).rounded()))%")
    }

    var body: some View {
        // A neutral page: a heading and text lines as bars, so the preview shows what the veil does
        // without inventing names or figures that read as someone's data.
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color(hex: 0x2A2C33)).frame(width: 120, height: 7)
                ForEach([248, 214, 232], id: \.self) { width in
                    Capsule().fill(Color(hex: 0x8B9099)).frame(width: CGFloat(width), height: 4)
                }
            }
            .padding(.leading, 14)
            PreviewFrost(strength: strength, smoke: smoke,
                         reduceTransparency: accessibility.preferences.reduceTransparency)
        }
        .frame(width: 300, height: 64)
        .background(Color(hex: 0xF3F4F6))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Blur preview, \(Int((strength * 100).rounded())) percent, \(tintReadout)"))
        .accessibilityValue(accessibility.preferences.reduceTransparency && strength > 0 ? L10n.string("Opaque cover") : L10n.string("Frosted veil"))
    }
}

private struct PreviewFrost: NSViewRepresentable {
    let strength: Double
    let smoke: Double
    let reduceTransparency: Bool

    func makeNSView(context: Context) -> DimmerBlurView {
        let view = DimmerBlurView(frame: .zero)
        view.blendingMode = .withinWindow
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: DimmerBlurView, context: Context) {
        nsView.alphaValue = VeilAppearance.opacity(strength: strength, reduceTransparency: reduceTransparency)
        nsView.update(smoke: smoke, reduceTransparency: reduceTransparency)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
