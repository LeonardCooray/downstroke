// Adapted from Switchcraft's KeyboardMonitor (MIT).
import CoreGraphics
import DownstrokeCore
import Foundation
import Synchronization

enum KeyTapError: Error, CustomStringConvertible {
    case permissionDenied
    case tapCreationFailed

    var description: String {
        switch self {
        case .permissionDenied: "Input Monitoring permission hasn't been granted"
        case .tapCreationFailed: "macOS refused to create the event tap (CGEvent.tapCreate returned nil)"
        }
    }
}

/// Listen-only keyboard tap on its own thread. Reads only the key code, autorepeat flag and timestamp.
final class KeyTap: @unchecked Sendable {
    // CF handles are thread-safe; the mutex guards the references.
    private struct State: @unchecked Sendable {
        var handler: (@Sendable (KeyEvent) -> Void)?
        var tap: CFMachPort?
        var runLoop: CFRunLoop?
        var finished: DispatchSemaphore?
        var running = false
    }

    private let state = Mutex(State())
    private let stopRequested = Atomic<Bool>(false)
    // Tap-thread confined.
    private var previousFlags: UInt64 = 0

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// True if access is already granted.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    var onEvent: (@Sendable (KeyEvent) -> Void)? {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }

    var isRunning: Bool { state.withLock { $0.running } }

    func start() throws {
        guard !isRunning else { return }
        guard Self.hasPermission else { throw KeyTapError.permissionDenied }
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        stopRequested.store(false, ordering: .relaxed)
        state.withLock { $0.finished = done }
        let thread = Thread { [self] in
            runTap(ready: ready)
            done.signal()
        }
        thread.name = "com.leonardcooray.downstroke.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        guard isRunning else {
            done.wait()
            state.withLock { $0.finished = nil }
            throw KeyTapError.tapCreationFailed
        }
    }

    /// Stops the tap and waits up to 1 s for its thread to finish.
    func stop() {
        guard let done = state.withLock({ $0.finished }) else { return }
        stopRequested.store(true, ordering: .releasing)
        if let loop = state.withLock({ $0.runLoop }) { CFRunLoopStop(loop) }
        _ = done.wait(timeout: .now() + 1)
        state.withLock { $0.finished = nil }
    }

    private func runTap(ready: DispatchSemaphore) {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: keyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            ready.signal()
            return
        }
        let loop = CFRunLoopGetCurrent()!
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(loop, source, .defaultMode)
        previousFlags = CGEventSource.flagsState(.combinedSessionState).rawValue
        CGEvent.tapEnable(tap: tap, enable: true)
        state.withLock {
            $0.tap = tap
            $0.runLoop = loop
            $0.running = true
        }
        ready.signal()

        // Sliced so a stop() that lands before the loop first runs is still seen.
        while !stopRequested.load(ordering: .acquiring) {
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(loop, source, .defaultMode)
        CFMachPortInvalidate(tap)
        state.withLock {
            $0.tap = nil
            $0.runLoop = nil
            $0.running = false
        }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = state.withLock({ $0.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            emit(event, isRelease: false, isModifier: false)
        case .keyUp:
            emit(event, isRelease: true, isModifier: false)
        case .flagsChanged:
            let flags = event.flags.rawValue
            defer { previousFlags = flags }
            guard let isPress = ModifierTransition.isPress(keyCode: Self.keyCode(event), flags: flags,
                                                           previousFlags: previousFlags) else { return }
            emit(event, isRelease: !isPress, isModifier: true)
        default:
            break
        }
    }

    private func emit(_ event: CGEvent, isRelease: Bool, isModifier: Bool) {
        // CGEvent timestamps are mach-clock nanoseconds; synthetic events may carry 0.
        let now = MonotonicClock.now()
        var time = event.timestamp == 0 ? now : MonotonicClock.seconds(fromNanoseconds: event.timestamp)
        // A unit surprise degrades to callback time instead of losing every hit window.
        if abs(now - time) > 0.25 { time = now }
        let keyEvent = KeyEvent(time: time, keyCode: Self.keyCode(event), isRelease: isRelease, isModifier: isModifier)
        state.withLock { $0.handler }?(keyEvent)
    }

    private static func keyCode(_ event: CGEvent) -> UInt16 {
        UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    }

    #if DEBUG
    var isTapEnabled: Bool {
        guard let tap = state.withLock({ $0.tap }) else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Disables the tap as macOS would, then delivers `type` through the real callback on the tap thread.
    func simulateSystemDisable(_ type: CGEventType) -> (disabled: Bool, reenabled: Bool) {
        guard let (tap, loop) = state.withLock({ s in s.tap.flatMap { t in s.runLoop.map { (t, $0) } } }) else {
            return (false, false)
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        let disabled = !CGEvent.tapIsEnabled(tap: tap)
        let delivered = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            if let event = CGEvent(source: nil) {
                _ = keyTapCallback(proxy: OpaquePointer(bitPattern: 1)!, type: type, event: event,
                                   refcon: Unmanaged.passUnretained(self).toOpaque())
            }
            delivered.signal()
        }
        CFRunLoopWakeUp(loop)
        guard delivered.wait(timeout: .now() + 1) == .success else { return (disabled, false) }
        return (disabled, CGEvent.tapIsEnabled(tap: tap))
    }
    #endif
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon { Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
    return Unmanaged.passUnretained(event)
}
