import AppKit
import SwiftUI

struct SupportDetails {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.string("Development")
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? L10n.string("Unbundled")
    let macOS = ProcessInfo.processInfo.operatingSystemVersionString
    let model: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return L10n.string("Unknown") }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return L10n.string("Unknown") }
        return String(cString: bytes)
    }()

    var text: String { L10n.string("Dimmer: \(version)\nBuild: \(build)\nmacOS: \(macOS)\nMac model: \(model)") }

    static let projectURL = URL(string: "https://github.com/kalkman-code/dimmer")!
    static let issueURL = URL(string: "https://github.com/kalkman-code/dimmer/issues/new?template=bug_report.yml")!
    static let releaseURL = URL(string: "https://github.com/kalkman-code/dimmer/releases/latest")!
}

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.string("About Dimmer")
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingController(rootView: AboutView())
            host.sizingOptions = []
            window.contentViewController = host
            window.setContentSize(NSSize(width: 440, height: 380))
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        AppShell.returnToMenuBar(closing: window)
    }
}

private struct AboutView: View {
    private let details = SupportDetails()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Dimmer")).font(.title2.weight(.semibold))
                    Text(L10n.string("Version \(details.version) · Build \(details.build)")).foregroundStyle(.secondary)
                    Text(L10n.string("GPL-3.0")).font(.callout).foregroundStyle(.secondary)
                }
            }
            Link(L10n.string("Project on GitHub"), destination: SupportDetails.projectURL)
            Divider()
            Text(details.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Button(copied ? L10n.string("Details copied") : L10n.string("Copy support details")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(details.text, forType: .string)
                copied = true
            }
            Text(L10n.string("Include these details in your report. Nothing is sent automatically."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.string("Report a bug…")) { NSWorkspace.shared.open(SupportDetails.issueURL) }
                Spacer()
                Button(L10n.string("View latest release…")) { NSWorkspace.shared.open(SupportDetails.releaseURL) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 20.0 / 255, green: 20.0 / 255, blue: 22.0 / 255))
    }
}
