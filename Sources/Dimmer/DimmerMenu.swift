import SwiftUI

struct DimmerMenu: View {
    let controller: DimmerController
    let features: DimmerFeatures
    @ObservedObject var updates: UpdateController
    let showSettings: () -> Void
    var showAbout: () -> Void = {}
    var reportBug: () -> Void = {}

    static func panelDurations(selected: AwakeDuration) -> [AwakeDuration] {
        var durations: [AwakeDuration] = [.off, .fifteenMinutes, .oneHour, .twoHours, .fiveHours, .indefinitely]
        if selected == .untilTime {
            durations.append(.untilTime)
        }
        return durations
    }

    private var statusText: String {
        guard controller.paused else { return controller.errorMessage }
        guard let resumeAt = controller.resumeAt else { return L10n.string("Paused") }
        return L10n.string("Paused until \(resumeAt.formatted(date: .omitted, time: .shortened))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(nsImage: StatusGlyph.image(paused: controller.paused)).renderingMode(.template)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    .accessibilityHidden(true)
                Text(L10n.string("Dimmer")).font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(statusText)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.canResumeKeyboard {
                    Button(L10n.string("Resume keyboard dimming")) { controller.resumeKeyboard() }
                        .buttonStyle(.plain)
                        .help(L10n.string("Hands the keyboard backlight back to Dimmer. Screen dimming and privacy control are not interrupted."))
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                MenuReadouts(controller: controller, reading: controller.reading)
                if !controller.paused, let explanation = controller.screenStatus.explanation {
                    Text(explanation)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("Keep awake")).font(.system(size: 10)).foregroundStyle(.secondary)
                Picker(L10n.string("Keep awake"), selection: Binding(
                    get: { features.awakeDuration },
                    set: { features.setAwakeDuration($0) }
                )) {
                    ForEach(Self.panelDurations(selected: features.awakeDuration)) { duration in Text(duration.title).tag(duration) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                if let status = features.awakeStatus {
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            Button(L10n.string("Go dark")) { controller.goDark() }
                .disabled(!controller.canGoDark)
                .help(controller.hasLidAngle
                      ? L10n.string("Fades the keyboard and screen to off. Input or moving the lid brings them back.")
                      : L10n.string("Without a readable lid sensor, Go dark wakes when you type or use the trackpad or mouse."))
                .buttonStyle(.plain)
            if updates.updateAvailable {
                Button(L10n.string("Update available…")) { updates.checkForUpdates() }
                    .buttonStyle(.plain)
            }
            Button(L10n.string("Settings…"), action: showSettings)
                .keyboardShortcut(",", modifiers: .command)
                .buttonStyle(.plain)
            Button(controller.paused ? L10n.string("Resume") : L10n.string("Pause")) { controller.togglePaused() }
                .buttonStyle(.plain)
            if !controller.paused {
                Menu(L10n.string("Pause for…")) {
                    ForEach(PauseDuration.allCases, id: \.self) { duration in
                        Button(duration.title) { controller.pause(for: duration) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Menu(L10n.string("More")) {
                Button(L10n.string("About Dimmer"), action: showAbout)
                Button(L10n.string("Check for updates…")) { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                Button(L10n.string("Report a bug…"), action: reportBug)
                Button(L10n.string("View latest release…")) { NSWorkspace.shared.open(SupportDetails.releaseURL) }
                Button(L10n.string("Uninstall Dimmer…")) { UninstallGuide.show() }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(L10n.string("Quit Dimmer")) { AppShell.quit() }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 320)
    }

}

// The live lid, keyboard and screen readouts. Their own view, observing the readings, so a lid sample redraws
// these three rows rather than the panel.
private struct MenuReadouts: View {
    let controller: DimmerController
    let reading: LidReading

    var body: some View {
        readout(L10n.string("Lid"), value: reading.angle.map { L10n.string("\(Int($0.rounded()))") + L10n.displayUnit("°") } ?? L10n.string("Unavailable readout"))
        readout(L10n.string("Keyboard"), value: reading.keyboardPercent.map { L10n.string("\($0)") + L10n.displayUnit("%") } ?? L10n.string("Unavailable readout"))
        let screen = reading.angle.map { $0 >= controller.screenRange.highAngle } == true
            ? L10n.string("Yours")
            : reading.displayPercent.map { L10n.string("\($0)") + L10n.displayUnit("%") } ?? L10n.string("Unavailable readout")
        readout(L10n.string("Screen"), value: screen)
    }

    private func readout(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
    }
}
