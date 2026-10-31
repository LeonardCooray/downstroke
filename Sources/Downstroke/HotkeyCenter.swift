// Adapted from Tracer's HotkeyCenter (MIT).
import Carbon.HIToolbox
import DownstrokeCore

/// One global hotkey through Carbon's RegisterEventHotKey.
@MainActor
final class HotkeyCenter {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    nonisolated private static let signature = OSType(0x4453_544B) // "DSTK"

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init() {
        id = Self.nextID
        Self.nextID += 1
        Self.installHandler()
    }

    var isRegistered: Bool { ref != nil }

    /// Replaces any previous registration; returns the Carbon status.
    @discardableResult
    func register(_ hotkey: Hotkey, handler: @escaping () -> Void) -> OSStatus {
        unregister()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return status == noErr ? OSStatus(eventInternalErr) : status }
        self.ref = ref
        Self.handlers[id] = handler
        return noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    #if DEBUG
    /// Runs the handler exactly as a Carbon hot-key event would.
    func simulatePress() { Self.dispatch(id) }
    #endif

    private static func dispatch(_ id: UInt32) { handlers[id]?() }

    // One application-wide handler, so several centers never double-fire.
    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { HotkeyCenter.dispatch(hotKeyID.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
