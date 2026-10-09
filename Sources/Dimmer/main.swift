import AppKit

@main
enum DimmerMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = DimmerAppDelegate()
        app.delegate = delegate
        // A plain SIGTERM (kill, pkill, some uninstallers) would otherwise end the process without
        // applicationWillTerminate, leaving the backlight at Dimmer's level until the next launch.
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler { AppShell.quit() }
        terminate.resume()
        app.run()
        _ = terminate
    }
}
