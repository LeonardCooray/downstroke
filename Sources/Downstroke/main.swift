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
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bench and self-tests build their own rigs: no tap, no real preferences domain.
        if BenchMode.isRequested {
            Task { @MainActor in exit(await BenchMode.run()) }
            return
        }
        menuBar = MenuBarController()
        #if DEBUG
        if DebugSelfTest.isRequested { return DebugSelfTest.runIfRequested() }
        #endif
        let controller = AppController()
        controller.start()
        self.controller = controller
    }
}
