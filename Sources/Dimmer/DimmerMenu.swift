import SwiftUI

struct DimmerMenu: View {
    @ObservedObject var controller: DimmerController
    let launchAtLogin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dimmer").font(.system(size: 17, weight: .semibold))
                    Text(controller.paused ? "Paused" : controller.errorMessage)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: controller.paused ? "pause.circle" : "circle.lefthalf.filled")
                    .font(.system(size: 20)).foregroundStyle(controller.paused ? .secondary : .primary)
            }
            Divider()
            HStack {
                Label("Lid angle", systemImage: "laptopcomputer")
                Spacer()
                Text(controller.angle.map { "\(Int($0.rounded()))°" } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 12))
            HStack {
                Label("Keyboard", systemImage: "keyboard")
                Spacer()
                Text(controller.keyboardBrightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 12))
            HStack {
                Label("Screen", systemImage: "sun.max")
                Spacer()
                Text(controller.displayBrightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 12))
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text("Off when lid is at"); Spacer(); Text("\(Int(controller.offAt))°") }
                Slider(value: $controller.offAt, in: 5...80, step: 1)
            }.font(.system(size: 12))
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text("Full brightness at"); Spacer(); Text("\(Int(controller.fullAt))°") }
                Slider(value: $controller.fullAt, in: 35...140, step: 1)
            }.font(.system(size: 12))
            Toggle("Dim screen too", isOn: $controller.dimsScreen)
                .font(.system(size: 12))
            Text("Dims below full-open and restores on reopening.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(controller.displayStatus)
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { NotificationCenter.default.post(name: .dimmerLaunchAtLogin, object: $0) }
            )).font(.system(size: 12))
            HStack {
                Button(controller.paused ? "Resume" : "Pause") {
                    controller.togglePaused()
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }.buttonStyle(.bordered)
        }
        .padding(16)
        .frame(width: 280)
    }
}

extension Notification.Name {
    static let dimmerLaunchAtLogin = Notification.Name("dimmerLaunchAtLogin")
}
