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
    private let raisedColour = Color(hex: 0x1C1C20)
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

            Section("Snap to blur") {
                Toggle(isOn: $features.privacyEnabled) {
                    settingLabel("Blur when the lid is snapped into the zone",
                                 detail: "Snap the lid down into the zone and every screen frosts at once. Typing, touching the trackpad or mouse, or pushing the lid back up clears it.")
                }
                .toggleStyle(.switch)
                .padding(.vertical, 2)

                KeyboardShortcuts.Recorder(for: .privacyBlur, onChange: { shortcut in
                    hasPrivacyShortcut = shortcut != nil
                    NotificationCenter.default.post(name: .dimmerPrivacyShortcutDidChange, object: nil)
                }) {
                    settingLabel("Privacy shortcut", detail: "Optional. Blur every screen from any app on release. Type, move the pointer or lift the lid to clear. Works with snap off.")
                }
                .shortcutValidation { shortcut in
                    let blocked: [NSEvent.ModifierFlags] = [
                        [.command], [.command, .shift], [.control, .option, .command],
                        [.command, .shift, .option], [.control, .option, .shift, .command]
                    ]
                    if shortcut.key == .p && blocked.contains(shortcut.modifiers) {
                        return .disallow(reason: "This shortcut is used by printing, applications or accessibility. Choose another combination.")
                    }
                    return .allow
                }
                .padding(.vertical, 4)

                settingRow("Snap of at least", detail: "How far the lid must drop into the zone.",
                           value: snapBinding(\.snapDegrees), range: 1...40, unit: "°")
                settingRow("Snap speed", detail: "Slower closes pass through without blurring.",
                           value: snapBinding(\.minimumSpeed), range: 10...300, unit: "°/s", step: 5)
                settingRow("Clear speed", detail: "How soon the screen returns as the lid lifts.",
                           value: Binding(get: { features.snap.clearSeconds * 1000 },
                                          set: { setSnap(\.clearSeconds, $0 / 1000) }),
                           range: 0...600, unit: "ms", step: 10, sliderEnds: ("Instant", "Slow"))
                settingRow("Blur strength", detail: strengthNote,
                           value: Binding(get: { features.snap.blurStrength * 100 },
                                          set: { setSnap(\.blurStrength, $0 / 100) }),
                           range: 0...100, unit: "%", available: features.privacyEnabled || hasPrivacyShortcut)
                settingRow("Tint", detail: smokeNote,
                           value: Binding(get: { features.snap.smoke * 100 },
                                          set: { setSnap(\.smoke, $0 / 100) }),
                           range: 0...100, unit: "%", sliderEnds: ("Frost", "Smoke"), available: features.privacyEnabled || hasPrivacyShortcut)

                previewRow
            }

            Section("Keep awake") {
                HStack(spacing: 10) {
                    settingLabel("Keep the Mac awake", detail: awakeStatus)
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Picker("Keep the Mac awake", selection: Binding(
                            get: { features.awakeDuration },
                            set: { features.setAwakeDuration($0) }
                        )) {
                            ForEach(AwakeDuration.allCases) { duration in
                                Text(duration == .untilTime ? "Until a time" : duration.title).tag(duration)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        if features.awakeDuration == .untilTime {
                            DatePicker("Until", selection: $features.awakeUntilTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .fixedSize()
                        }
                    }
                }
                .frame(minHeight: 42)

                HStack {
                    Text("Keep the display awake too").font(.system(size: 13))
                    Spacer()
                    Toggle("Keep the display awake too", isOn: $features.keepsDisplayAwake)
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
                    settingLabel("Show in menu bar", detail: "Open Dimmer from Applications or Spotlight to return to Settings.")
                }
                .toggleStyle(.switch)
                .frame(minHeight: 42)
                HStack {
                    Text("Launch at Login").font(.system(size: 13))
                    Spacer()
                    Toggle("Launch at Login", isOn: Binding(
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
                    Button("Open Login Items…") { login.openLoginItems() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(bodyColour)
        .tint(Color(hex: 0x6F84AD))
        .padding(.horizontal, 4)
        .frame(width: 680)
        .sheet(isPresented: $shell.showWelcome) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Welcome to Dimmer").font(.title2.weight(.semibold))
                Text("Dimmer follows your MacBook’s lid angle to dim the keyboard and screen as it closes.")
                Text("The Dimmer icon lives in the menu bar. Choose Settings there to adjust the ranges. Opening Dimmer from Applications or Spotlight brings Settings back, even if the icon is hidden.")
                Text("Pause and Quit hand brightness back to you. Keep awake prevents idle sleep for the time you choose; it does not keep a closed MacBook awake.")
                Toggle("Launch at Login", isOn: Binding(
                    get: { login.isOn },
                    set: { login.setEnabled($0) }
                ))
                Text(login.message)
                    .font(.callout).foregroundStyle(.secondary)
                if login.status == .requiresApproval {
                    Button("Open Login Items…") { login.openLoginItems() }
                }
                HStack {
                    Spacer()
                    Button("Start using Dimmer") { shell.showWelcome = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(width: 460)
        }
        .alert("Hide Dimmer from the menu bar?", isPresented: $confirmHideMenuBarIcon) {
            Button("Hide icon") { shell.showMenuBarIcon = false }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Dimming keeps running. Open Dimmer from Applications or Spotlight to bring Settings back, where Show in menu bar puts the icon back.")
        }
    }

    private var statusLine: some View {
        HStack(spacing: 9) {
            Image(nsImage: StatusGlyph.image(paused: controller.paused))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0xE2E5EA), Color(hex: 0xB9C8E6)],
                                                startPoint: .top, endPoint: .bottom))
                .accessibilityHidden(true)
            Text(statusTitle)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: 0xE2E5EA))
            Text(statusDescription)
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        if controller.paused { return "Paused" }
        return controller.errorMessage == "Active" ? "Active" : controller.errorMessage
    }

    private var statusDescription: String {
        if controller.paused { return "Dimming is paused. Resume from the menu bar." }
        if controller.errorMessage != "Active" {
            return controller.angle == nil ? "Waiting for the lid sensor." : "Dimmer has stopped controlling brightness."
        }
        return switch (controller.dimsKeyboard, controller.dimsScreen) {
        case (true, true): "Dimming the keyboard and the screen as the lid closes."
        case (true, false): "Dimming the keyboard as the lid closes."
        case (false, true): "Dimming the screen as the lid closes."
        case (false, false): "Dimming is off."
        }
    }

    private func settingRow(_ title: String, detail: String, value: Binding<Double>, range: ClosedRange<Double>,
                            unit: String, step: Double = 1, sliderEnds: (String, String)? = nil, available: Bool? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .leading)
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
                .accessibilityLabel(title)
                .accessibilityValue(AccessibilityReadout.value(value.wrappedValue, unit: unit))
                .accessibilityHint(AccessibilityReadout.range(range, unit: unit))
                numberField(title: title, value: value, range: range, step: step, unit: unit)
                Text(unit)
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
                Text("Preview").font(.system(size: 13))
                Text("A page, as the veil leaves it.")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
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
        if strength == 0 { return "None: the zone does nothing visible." }
        if strength < 50 { return "Light: large text is still readable." }
        if strength < 90 { return "Medium: shapes show, words do not." }
        return "Full: nothing on screen is readable."
    }

    private var smokeNote: String {
        switch features.snap.smoke {
        case ..<0.05: "Frost: a light veil."
        case ..<0.5: "Light smoke: darker, the room sees less glow."
        case ..<0.95: "Smoke: dark glass over the screen."
        default: "Deep smoke: shapes only, nearly dark."
        }
    }

    private var awakeStatus: String {
        if let error = features.awakeError { return error }
        switch features.awakeDuration {
        case .off: return "The Mac sleeps as usual."
        case .indefinitely: return "Awake until you turn this off."
        case .untilTime:
            return "Until \(features.awakeUntilTime.formatted(date: .omitted, time: .shortened))."
        default:
            let deadline = features.awakeDeadline ?? Date()
            return "Until \(deadline.formatted(date: .omitted, time: .shortened))."
        }
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(secondaryText).lineLimit(2)
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
        TextField(title, text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .frame(width: 56, height: 22)
            .fixedSize()
            .focused($focused)
            .accessibilityLabel("\(title) exact value")
            .accessibilityValue(AccessibilityReadout.value(Double(draft) ?? value, unit: unit))
            .accessibilityHint(AccessibilityReadout.range(range, unit: unit) + " Return applies. Escape cancels.")
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
        smoke < 0.05 ? "Frost" : "Smoke \(Int((smoke * 100).rounded()))%"
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
        .accessibilityLabel("Blur preview, \(Int((strength * 100).rounded())) percent, \(tintReadout)")
        .accessibilityValue(accessibility.preferences.reduceTransparency && strength > 0 ? "Opaque cover" : "Frosted veil")
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

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
