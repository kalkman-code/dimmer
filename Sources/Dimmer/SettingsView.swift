import AppKit
import Observation
import SwiftUI
import KeyboardShortcuts

#if DEBUG
// Body evaluations by view, for SettingsFrameBudgetTests. Never read by the app.
@MainActor
enum BodyCount {
    static var counts: [String: Int] = [:]
    static func hit(_ name: String) { counts[name, default: 0] += 1 }
    static func reset() { counts.removeAll() }
}
#endif

struct SettingsView: View {
    let controller: DimmerController
    @Bindable var features: DimmerFeatures
    @ObservedObject var shell: ShellPreferences
    @ObservedObject var login: LoginItem
    @ObservedObject var history: SettingsHistory
    @ObservedObject var updates: UpdateController
    @State private var confirmHideMenuBarIcon = false
    @State private var hasPrivacyShortcut = KeyboardShortcuts.getShortcut(for: .privacyBlur) != nil

    var privacyShortcutAvailable: Bool { features.privacyVeilEnabled && hasPrivacyShortcut }

    private let bodyColour = Color(hex: 0x141416)
    private let secondaryText = Color(hex: 0x9A9EA7)
    private let controlWidth: CGFloat = 300

    init(controller: DimmerController, features: DimmerFeatures, shell: ShellPreferences, login: LoginItem, history: SettingsHistory, updates: UpdateController) {
        self.controller = controller
        self.features = features
        self.shell = shell
        self.login = login
        self.history = history
        self.updates = updates
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCount.hit("SettingsView")
        #endif
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    statusLine
                    if controller.hasLidAngle { axisHelp }
                }
                .padding(.vertical, 4)
            }

            if controller.hasLidAngle {
                Section {
                    LaneBox(lane: .keyboard, controller: controller, features: features, history: history) { EmptyView() }
                }

                Section {
                    LaneBox(lane: .screen, controller: controller, features: features, history: history) {
                        OverlapNote(controller: controller, features: features, history: history)
                    }
                }

                snapBox

                Section {
                    LaneBox(lane: .blur, controller: controller, features: features, history: history) {
                        TintSettingRow(title: L10n.string("Tint"), accessibilityTitle: L10n.string("Blur tint"),
                                       detail: L10n.string("Sets the darkness of the angle blur, scaled with its blur strength."),
                                       tint: features.angleBlurTint, history: history,
                                       actionName: "Blur tint", set: history.setAngleBlurSmoke)
                        VeilLookPicker(target: .angle, features: features, history: history)
                        BlurPreviewRow(source: .angle, features: features)
                    }
                }
            } else if controller.lidSensorState == .unavailable {
                Section {
                    Text(L10n.string("Angle controls are unavailable because this Mac has no readable lid sensor."))
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Isolated {
                    PrivacyVeilHeader(features: features, history: history)
                    if features.privacyVeilEnabled {
                        HStack(spacing: 12) {
                            settingLabel(L10n.string("Privacy shortcut"), detail: L10n.string("Works only while Privacy veil is on. Blurs every screen from any app, even with snap off; any input clears it. Click it to record your own."))
                            Spacer(minLength: 8)
                            // The recorder's own field is a borderless grey placeholder that read as disabled text;
                            // in testing it was not found. The outline makes it read as a control.
                            KeyboardShortcuts.Recorder(for: .privacyBlur, onChange: { shortcut in
                                hasPrivacyShortcut = shortcut != nil
                                NotificationCenter.default.post(name: .dimmerShortcutDidChange, object: nil)
                            })
                            .shortcutValidation { shortcut in
                                if let conflict = ShortcutConflict.reason(for: shortcut, other: KeyboardShortcuts.getShortcut(for: .goDark), otherName: L10n.string("Go dark")) {
                                    return .disallow(reason: conflict)
                                }
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

                        settingRow(L10n.string("Clear speed"), detail: L10n.string("How long the veil takes to fade once it clears."),
                                   value: Binding(get: { features.snapClearSeconds * 1000 },
                                                  set: { setSnap(\.clearSeconds, $0 / 1000) }),
                                   range: 0...600, unit: "ms", step: 10, sliderEnds: (L10n.string("Instant"), L10n.string("Slow (600 ms)")), available: features.privacyEnabled || hasPrivacyShortcut)
                        settingRow(L10n.string("Blur strength"), detail: blurStrengthNote(for: features.privacyVeilBlurStrength, source: .privacy),
                                   value: Binding(get: { features.privacyVeilBlurStrength * 100 },
                                                  set: { history.setPrivacyVeilBlurStrength($0 / 100) }),
                                   range: 0...100, unit: "%", available: privacyShortcutAvailable,
                                   undoName: "Privacy veil blur strength",
                                   accessibilityTitle: L10n.string("Privacy veil blur strength"))
                        TintSettingRow(title: L10n.string("Tint"), accessibilityTitle: L10n.string("Privacy veil tint"),
                                       detail: L10n.string("Sets the darkness of the shortcut veil"),
                                       tint: features.privacyVeilTint, history: history, actionName: "Privacy veil tint",
                                       available: privacyShortcutAvailable, set: history.setPrivacyVeilSmoke)
                        VeilLookPicker(target: .privacy, features: features, history: history)
                        BlurPreviewRow(source: .privacy, features: features, available: privacyShortcutAvailable)
                    }
                }
            }

            Section(L10n.string("Go dark")) {
                HStack(spacing: 12) {
                    settingLabel(L10n.string("Go dark shortcut"), detail: L10n.string(controller.lidSensorState == .unavailable
                        ? "Fades the keyboard and screen to off from any app. Unassigned until you record one. Typing or using the trackpad brings them back."
                        : "Fades the keyboard and screen to off from any app. Unassigned until you record one. Typing, the trackpad or moving the lid brings them back."))
                    Spacer(minLength: 8)
                    KeyboardShortcuts.Recorder(for: .goDark, onChange: { _ in
                        NotificationCenter.default.post(name: .dimmerShortcutDidChange, object: nil)
                    })
                    .shortcutValidation { shortcut in
                        if let conflict = ShortcutConflict.reason(for: shortcut, other: KeyboardShortcuts.getShortcut(for: .privacyBlur), otherName: L10n.string("Privacy blur")) {
                            return .disallow(reason: conflict)
                        }
                        return .allow
                    }
                    .accessibilityLabel(L10n.string("Go dark shortcut"))
                    .frame(minWidth: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0x8EA2C9), lineWidth: 1))
                }
                .padding(.vertical, 4)
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

            Section(L10n.string("Updates")) {
                Toggle(isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.automaticallyChecksForUpdates = $0 }
                )) {
                    settingLabel(L10n.string("Check for updates automatically"), detail: L10n.string("Once a day, Dimmer asks kalkmancode.co.uk whether a newer version exists. The request carries only your IP address, the Dimmer and Sparkle versions and your preferred language."))
                }
                .toggleStyle(.switch)
                .frame(minHeight: 42)

                Toggle(isOn: Binding(
                    get: { updates.automaticallyDownloadsUpdates },
                    set: { updates.automaticallyDownloadsUpdates = $0 }
                )) {
                    settingLabel(L10n.string("Install updates automatically"), detail: L10n.string("Downloads and installs signed updates without asking first. Dimmer restores your keyboard and screen brightness before it quits to update."))
                }
                .toggleStyle(.switch)
                .disabled(!updates.automaticallyChecksForUpdates)
                .opacity(updates.automaticallyChecksForUpdates ? 1 : 0.38)
                .frame(minHeight: 42)

                HStack {
                    settingLabel(updates.updateAvailable ? L10n.string("An update is ready to install") : L10n.string("Check for updates now"),
                                 detail: updateCheckDetail)
                    Spacer(minLength: 16)
                    Button(updates.updateAvailable ? L10n.string("Show update…") : L10n.string("Check now")) { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates && !updates.updateAvailable)
                }
                .frame(minHeight: 42)
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
            } footer: {
                Link(L10n.string("Buy me a coffee"), destination: SupportDetails.coffeeURL)
                    .font(.system(size: 11))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(bodyColour)
        .tint(Color(hex: 0x6F84AD))
        .padding(.horizontal, 4)
        .frame(minWidth: SettingsWindow.minimumContentSize.width, idealWidth: 760, maxWidth: .infinity,
               minHeight: SettingsWindow.minimumContentSize.height, alignment: .topLeading)
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

    private var axisHelp: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.string("Drag an end sideways for its angle, up or down for its brightness. Tab selects a value; Return edits it and Escape cancels."))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.string("← → 1° · ↑ ↓ 5%"))
                .font(.system(size: 11).monospacedDigit())
                .fixedSize()
        }
        .font(.system(size: 11))
        .foregroundStyle(secondaryText)
    }

    var snapBox: some View {
        Section {
            LaneBox(lane: .privacy, controller: controller, features: features, history: history) {
                settingRow(L10n.string("Snap of at least"), detail: L10n.string("How far the lid must drop into the zone."),
                           value: Binding(get: { features.snapDegrees }, set: { setSnap(\.snapDegrees, $0) }),
                           range: 1...40, unit: "°")
                settingRow(L10n.string("Snap speed"), detail: L10n.string("Slower closes pass through without blurring."),
                           value: Binding(get: { features.snapMinimumSpeed }, set: { setSnap(\.minimumSpeed, $0) }),
                           range: 10...300, unit: "°/s", step: 5)
                settingRow(L10n.string("Blur strength"), detail: blurStrengthNote(for: features.snapBlurStrength, source: .snap),
                           value: Binding(get: { features.snapBlurStrength * 100 },
                                          set: { setSnap(\.blurStrength, $0 / 100) }),
                           range: 0...100, unit: "%", available: features.privacyEnabled,
                           undoName: "Snap blur strength",
                           accessibilityTitle: L10n.string("Snap blur strength"))
                SnapTintContent(features: features, tint: features.snapTint, history: history)
                VeilLookPicker(target: .snap, features: features, history: history)
                BlurPreviewRow(source: .snap, features: features)
            }
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("Welcome to Dimmer")).font(.title2.weight(.semibold))
            Text(L10n.string("Dimmer follows your MacBook’s lid angle to dim the keyboard and screen as it closes."))
            Text(L10n.string("The Dimmer icon lives in the menu bar. Choose Settings there to adjust the ranges. Opening Dimmer from Applications or Spotlight brings Settings back, even if the icon is hidden."))
            Text(L10n.string("Pause and Quit hand brightness back to you. Quitting restores the keyboard even while macOS has dimmed it. Keep awake prevents idle sleep for the time you choose; it does not keep a closed MacBook awake."))
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
                if !statusDescription.isEmpty {
                    Text(statusDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        if controller.paused {
            if let resumeAt = controller.resumeAt {
                return L10n.string("Paused until \(resumeAt.formatted(date: .omitted, time: .shortened))")
            } else {
                return L10n.string("Paused")
            }
        }
        return controller.errorMessage
    }

    private var statusDescription: String {
        var description: String = ""
        if controller.paused {
            description = L10n.string("Dimming is paused. Resume from the menu bar.")
        } else if controller.errorMessage != L10n.string("Active") {
            if controller.lidSensorState == .unavailable {
                description = ""
            } else if !controller.hasLidAngle {
                description = L10n.string("Waiting for the lid sensor.")
            } else {
                description = controller.keyboardYielded
                    ? L10n.string("Screen and privacy control continue. Choose Resume keyboard dimming in the menu bar panel to reconnect the keyboard.")
                    : L10n.string("Screen and privacy control continue. Pause and resume to reconnect the keyboard.")
            }
        } else {
            switch (controller.dimsKeyboard, controller.dimsScreen) {
            case (true, true): description = L10n.string("Dimming the keyboard and the screen as the lid closes.")
            case (true, false): description = L10n.string("Dimming the keyboard as the lid closes.")
            case (false, true): description = L10n.string("Dimming the screen as the lid closes.")
            case (false, false): description = L10n.string("Dimming is off.")
            }
        }

        if !controller.paused, let screenExplanation = controller.screenStatus.explanation {
            description += "\n" + screenExplanation
        }
        return description
    }

    private func settingRow(_ title: String, detail: String, value: Binding<Double>, range: ClosedRange<Double>,
                            unit: String, step: Double = 1, sliderEnds: (String, String)? = nil,
                            available: Bool? = nil, undoName: String.LocalizationValue = "Privacy settings",
                            accessibilityTitle: String? = nil) -> some View {
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
                ), in: range, step: step, onEditingChanged: { editing in
                    if editing { history.beginGesture(undoName) } else { history.endGesture() }
                }) { Text(accessibilityTitle ?? title) }
                // In a grouped Form a Slider keeps an empty label column unless hidden, which pushed the
                // track 88 pt right and left it 108 pt long.
                .labelsHidden()
                .frame(width: 196)
                .tint(Color(hex: 0x8EA2C9))
                .accessibilityValue(AccessibilityReadout.value(value.wrappedValue, unit: unit))
                .accessibilityHint(AccessibilityReadout.range(range, unit: unit))
                numberField(title: accessibilityTitle ?? title, value: value, range: range, step: step, unit: unit)
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

}

private struct VeilLookPicker: View {
    let target: VeilLookTarget
    @Bindable var features: DimmerFeatures
    @ObservedObject var history: SettingsHistory

    private var selectedLook: VeilLook? {
        let strength: Double
        let tint: Double
        switch target {
        case .snap:
            strength = features.snapBlurStrength
            tint = features.snapTint.value
        case .angle:
            strength = 1
            tint = features.angleBlurTint.value
        case .privacy:
            strength = features.privacyVeilBlurStrength
            tint = features.privacyVeilTint.value
        }
        return VeilLook.matching(strength: strength, tint: tint, target: target)
    }

    private var localeKey: String {
        #if DEBUG
        L10n.testLanguage ?? Locale.current.identifier
        #else
        Locale.current.identifier
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.string("Look")).font(.system(size: 13))
            Spacer(minLength: 8)
            VeilLookMenu(target: target, selection: selectedLook, localeKey: localeKey) { history.apply($0, to: target) }
                .equatable()
        }
        .frame(minHeight: 36)
    }
}

private struct VeilLookMenu: View, Equatable {
    let target: VeilLookTarget
    let selection: VeilLook?
    let localeKey: String
    let apply: (VeilLook) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target && lhs.selection == rhs.selection && lhs.localeKey == rhs.localeKey
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCount.hit("VeilLookMenu.\(target)")
        #endif
        Picker(L10n.string(target.accessibilityLabel), selection: Binding(
            get: { selection },
            set: { if let look = $0 { apply(look) } }
        )) {
            Text(L10n.string("Custom")).tag(nil as VeilLook?)
            ForEach(VeilLook.allCases) { look in
                Text(look.title).tag(look as VeilLook?)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel(L10n.string(target.accessibilityLabel))
    }
}

enum BlurPreviewSource: Equatable {
    case snap
    case angle
    case privacy

    func accessibilityLabel(strength: Double, tintReadout: String) -> String {
        switch self {
        case .snap: L10n.string("Snap to blur preview, \(Int((strength * 100).rounded())) percent, \(tintReadout)")
        case .angle: L10n.string("Blur by angle preview, \(Int((strength * 100).rounded())) percent, \(tintReadout)")
        case .privacy: L10n.string("Privacy veil preview, \(Int((strength * 100).rounded())) percent, \(tintReadout)")
        }
    }

    var counterName: String {
        switch self {
        case .snap: "BlurPreview.Snap"
        case .angle: "BlurPreview.Angle"
        case .privacy: "BlurPreview.Privacy"
        }
    }
}

struct BlurPreviewRow: View {
    let source: BlurPreviewSource
    @Bindable var features: DimmerFeatures
    var available = true
    private let controlWidth: CGFloat = 300
    private let secondaryText = Color(hex: 0x9A9EA7)

    var isAvailable: Bool { source != .privacy || available }

    private var strength: Double {
        switch source {
        case .snap: features.snapBlurStrength
        case .angle: 1
        case .privacy: features.privacyVeilBlurStrength
        }
    }

    private var tint: VeilTintSettings {
        switch source {
        case .snap: features.snapTint
        case .angle: features.angleBlurTint
        case .privacy: features.privacyVeilTint
        }
    }

    var accessibilityLabel: String {
        source.accessibilityLabel(strength: strength, tintReadout: tintReadout)
    }

    private var tintReadout: String {
        tint.value < 0.05 ? L10n.string("Frost") : L10n.string("Smoke \(Int((tint.value * 100).rounded()))%")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Preview")).font(.system(size: 13))
                Text(L10n.string("A page, as the veil leaves it."))
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            BlurPreview(strength: strength, tint: tint, accessibilityLabel: accessibilityLabel,
                        counterName: source.counterName)
                .frame(width: controlWidth, alignment: .leading)
        }
        .frame(minHeight: 68)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.38)
    }
}

func blurStrengthNote(for value: Double, source: BlurPreviewSource) -> String {
    if value == 0 {
        return L10n.string(source == .privacy ? "None: the shortcut does nothing visible." : "None: the zone does nothing visible.")
    }
    let strength = value * 100
    if strength < 50 { return L10n.string("Light: large text is still readable.") }
    if strength < 90 { return L10n.string("Medium: shapes show, words do not.") }
    return L10n.string("Full: nothing on screen is readable.")
}

private extension SettingsView {
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

    private var updateCheckDetail: String {
        guard let last = updates.lastUpdateCheckDate else { return L10n.string("Not checked yet.") }
        return L10n.string("Last checked \(last.formatted(.relative(presentation: .named))).")
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

    private func setSnap(_ keyPath: WritableKeyPath<SnapSettings, Double>, _ value: Double) {
        history.setSnap(keyPath, value)
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

private struct SnapTintContent: View {
    @Bindable var features: DimmerFeatures
    let tint: VeilTintSettings
    @ObservedObject var history: SettingsHistory

    private var defaults: SnapSettings { features.snap.restoringSnapDefaults() }

    var body: some View {
        #if DEBUG
        let _ = BodyCount.hit("SnapTintContent")
        #endif
        TintSettingRow(title: L10n.string("Tint"), accessibilityTitle: L10n.string("Snap tint"),
                       detail: L10n.string("Sets the darkness of the snap veil"),
                       tint: tint, history: history, actionName: "Snap tint") { value in
            history.setSnap(\.smoke, value)
        }

        HStack {
            Spacer()
            Button { history.restoreSnapSettings() } label: {
                RestoreLinkLabel(title: L10n.string("Restore snap defaults"), enabled: features.snap != defaults)
            }
            .buttonStyle(.plain)
            .disabled(features.snap == defaults)
            .help(L10n.string("Restores the zone, snap distance, speed, blur strength and tint. It does not turn snap on or off. Undo with Cmd+Z."))
            .accessibilityLabel(L10n.string("Restore snap defaults"))
        }
    }
}

struct PrivacyVeilHeader: View {
    @Bindable var features: DimmerFeatures
    @ObservedObject var history: SettingsHistory

    private let secondary = Color(hex: 0x9A9EA7)

    private var isOn: Binding<Bool> {
        Binding(get: { features.privacyVeilEnabled }, set: history.setPrivacyVeilEnabled)
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCount.hit("PrivacyVeilHeader")
        #endif
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.string("Privacy veil"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AxisLane.privacy.colour)
                if !features.privacyVeilEnabled {
                    Text(L10n.string("off"))
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 8)
            if features.privacyVeilEnabled {
                PrivacyVeilRestoreLink(features: features, tint: features.privacyVeilTint, history: history)
            }
            Toggle(L10n.string("Privacy veil"), isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(L10n.string("Privacy veil"))
        }
        .frame(minHeight: 34)
        .accessibilityElement(children: .contain)
    }
}

private struct PrivacyVeilRestoreLink: View {
    @Bindable var features: DimmerFeatures
    let tint: VeilTintSettings
    @ObservedObject var history: SettingsHistory

    private var isDefault: Bool {
        features.snapConfiguration == features.snapConfiguration.restoringPrivacyVeilDefaults()
            && features.privacyVeilBlurStrength == 1 && tint.value == VeilTintSettings.defaultValue
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCount.hit("PrivacyVeilRestoreLink")
        #endif
        Button { history.restorePrivacyVeilSettings() } label: {
            RestoreLinkLabel(title: L10n.string("Restore privacy veil defaults"), enabled: !isDefault)
        }
        .buttonStyle(.plain)
        .disabled(isDefault)
        .help(L10n.string("Restores blur strength, clear speed and tint. It does not change the shortcut. Undo with Cmd+Z."))
        .accessibilityLabel(L10n.string("Restore privacy veil defaults"))
    }
}

struct TintSettingRow: View {
    let title: String
    let accessibilityTitle: String
    let detail: String
    let tint: VeilTintSettings
    @ObservedObject var history: SettingsHistory
    let actionName: String.LocalizationValue
    var available = true
    let set: (Double) -> Void

    private let controlWidth: CGFloat = 300
    private let secondaryText = Color(hex: 0x9A9EA7)

    private var value: Binding<Double> {
        Binding(get: { tint.value * 100 }, set: { set(min(max($0, 0), 100) / 100) })
    }

    private var smokeNote: String {
        switch tint.value {
        case ..<0.05: L10n.string("Frost: a light veil.")
        case ..<0.5: L10n.string("Light smoke: darker, the room sees less glow.")
        case ..<0.95: L10n.string("Smoke: dark glass over the screen.")
        default: L10n.string("Deep smoke: shapes only, nearly dark.")
        }
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCount.hit("TintSettingRow.\(accessibilityTitle)")
        #endif
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
                Slider(value: value, in: 0...100, step: 1, onEditingChanged: { editing in
                    if editing { history.beginGesture(actionName) } else { history.endGesture() }
                }) { Text(title) }
                .labelsHidden()
                .frame(width: 196)
                .tint(Color(hex: 0x8EA2C9))
                .accessibilityLabel(accessibilityTitle)
                .accessibilityValue(AccessibilityReadout.value(value.wrappedValue, unit: "%"))
                .accessibilityHint(AccessibilityReadout.range(0...100, unit: "%"))
                PrivacyNumberField(title: accessibilityTitle, value: value, range: 0...100, step: 1, unit: "%")
                Text("%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(secondaryText)
                    .frame(width: 24, alignment: .leading)
            }
            .frame(width: controlWidth, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                HStack {
                    Text(L10n.string("Frost"))
                    Spacer()
                    Text(L10n.string("Smoke"))
                }
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .frame(width: 196)
                .offset(y: 13)
            }
        }
        .frame(minHeight: 48)
        .disabled(!available)
        .opacity(available ? 1 : 0.38)
        .accessibilityElement(children: .contain)
        .accessibilityHint(smokeNote)
    }
}

private struct BlurPreview: View {
    let strength: Double
    let tint: VeilTintSettings
    let accessibilityLabel: String
    let counterName: String
    @ObservedObject private var accessibility = DisplayAccessibility.shared

    var body: some View {
        #if DEBUG
        let _ = BodyCount.hit(counterName)
        #endif
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
            PreviewFrost(strength: strength, smoke: tint.value,
                         reduceTransparency: accessibility.preferences.reduceTransparency)
        }
        .frame(width: 300, height: 64)
        .background(Color(hex: 0xF3F4F6))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
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

// Runs its content in its own body, so what the content reads invalidates this view, not the one that built it.
private struct Isolated<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if DEBUG
        let _ = BodyCount.hit("Isolated")
        #endif
        content()
    }
}

private struct OverlapNote: View {
    let controller: DimmerController
    let features: DimmerFeatures
    @ObservedObject var history: SettingsHistory
    private let secondaryText = Color(hex: 0x9A9EA7)

    var body: some View {
        #if DEBUG
        let _ = BodyCount.hit("OverlapNote")
        #endif
        if features.privacyEnabled && controller.dimsScreen && features.snapConfiguration.zoneLow < controller.screenRange.highAngle {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("The screen already dims inside the snap zone."))
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                Button {
                    history.change("Brightness range") {
                        controller.screenRange = controller.screenRange.movedBelow(features.snapConfiguration.zoneLow)
                    }
                } label: {
                    Text(L10n.string("Move screen range below the zone"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0xB9C8E6))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
