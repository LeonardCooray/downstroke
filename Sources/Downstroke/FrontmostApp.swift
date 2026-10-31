import AppKit

/// The frontmost app's bundle ID, kept current from NSWorkspace activations.
@MainActor
final class FrontmostApp {
    private(set) var bundleID: String?
    var onChange: ((String?) -> Void)?
    private var observer: (any NSObjectProtocol)?

    init() {
        bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, id != self.bundleID else { return }
                self.bundleID = id
                self.onChange?(id)
            }
        }
    }
}
