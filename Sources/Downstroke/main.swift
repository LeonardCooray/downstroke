import AppKit

if ProbeMode.isRequested { ProbeMode.run() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
        #if DEBUG
        DebugSelfTest.runIfRequested()
        #endif
    }
}
