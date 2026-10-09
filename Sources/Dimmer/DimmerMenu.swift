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
                Text("Dimmer").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(controller.paused ? "Paused" : controller.errorMessage)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 7) {
                readout("Lid", value: controller.angle.map { "\(Int($0.rounded()))°" } ?? "—")
                readout("Keyboard", value: controller.keyboardBrightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                let screen = controller.angle.map { $0 >= controller.screenRange.highAngle } == true
                    ? "Yours"
                    : controller.displayBrightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
                readout("Screen", value: screen)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Keep awake").font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("Keep awake", selection: Binding(
                    get: { features.awakeDuration },
                    set: { features.setAwakeDuration($0) }
                )) {
                    ForEach(quickDurations) { duration in Text(duration.title).tag(duration) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Divider()
            Button("Settings…", action: showSettings)
                .keyboardShortcut(",", modifiers: .command)
                .buttonStyle(.plain)
            Button(controller.paused ? "Resume" : "Pause") { controller.togglePaused() }
                .buttonStyle(.plain)
            Menu("More") {
                Button("About Dimmer", action: showAbout)
                Button("Report a bug…", action: reportBug)
                Button("View latest release…") { NSWorkspace.shared.open(SupportDetails.releaseURL) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button("Quit Dimmer") { AppShell.quit() }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 260)
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
