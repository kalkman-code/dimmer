import SwiftUI

struct DimmerMenu: View {
    @ObservedObject var controller: DimmerController
    @ObservedObject var features: DimmerFeatures
    let showSettings: () -> Void
    var showAbout: () -> Void = {}
    var reportBug: () -> Void = {}

    private var quickDurations: [AwakeDuration] {
        var durations: [AwakeDuration] = [.off, .oneHour, .indefinitely]
        if !durations.contains(features.awakeDuration) { durations.append(features.awakeDuration) }
        return durations
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
            Text(controller.paused ? L10n.string("Paused") : controller.errorMessage)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                readout(L10n.string("Lid"), value: controller.angle.map { L10n.string("\(Int($0.rounded()))") + L10n.displayUnit("°") } ?? L10n.string("Unavailable readout"))
                readout(L10n.string("Keyboard"), value: controller.keyboardBrightness.map { L10n.string("\(Int(($0 * 100).rounded()))") + L10n.displayUnit("%") } ?? L10n.string("Unavailable readout"))
                let screen = controller.angle.map { $0 >= controller.screenRange.highAngle } == true
                    ? L10n.string("Yours")
                    : controller.displayBrightness.map { L10n.string("\(Int(($0 * 100).rounded()))") + L10n.displayUnit("%") } ?? L10n.string("Unavailable readout")
                readout(L10n.string("Screen"), value: screen)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("Keep awake")).font(.system(size: 10)).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    durationPicker
                        .pickerStyle(.segmented)
                        .fixedSize(horizontal: true, vertical: false)
                    durationPicker.pickerStyle(.menu)
                }
                if let status = features.awakeStatus {
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            Button(L10n.string("Go dark")) { controller.goDark() }
                .disabled(!controller.canGoDark)
                .help(L10n.string("Fades the keyboard and screen to off. Input or moving the lid brings them back."))
                .buttonStyle(.plain)
            Button(L10n.string("Settings…"), action: showSettings)
                .keyboardShortcut(",", modifiers: .command)
                .buttonStyle(.plain)
            Button(controller.paused ? L10n.string("Resume") : L10n.string("Pause")) { controller.togglePaused() }
                .buttonStyle(.plain)
            Menu(L10n.string("More")) {
                Button(L10n.string("About Dimmer"), action: showAbout)
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

    private var durationPicker: some View {
        Picker(L10n.string("Keep awake"), selection: Binding(
            get: { features.awakeDuration },
            set: { features.setAwakeDuration($0) }
        )) {
            ForEach(quickDurations) { duration in Text(duration.title).tag(duration) }
        }
        .labelsHidden()
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
