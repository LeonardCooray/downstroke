import CoreAudio
import Foundation

/// Default-device facts from the Core Audio HAL. Never opens the microphone.
@MainActor
enum SystemAudio {
    private static var handlers: [() -> Void] = []
    private static var installed = false
    private static var watchedInput = AudioObjectID(kAudioObjectUnknown)
    private static let listener: AudioObjectPropertyListenerBlock = { _, _ in
        MainActor.assumeIsolated { changed() }
    }

    static var outputIsBluetooth: Bool {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
              let transport = value(device, kAudioDevicePropertyTransportType) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Some process is running the default input device.
    static var micInUse: Bool {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
              let running = value(device, kAudioDevicePropertyDeviceIsRunningSomewhere) else { return false }
        return running != 0
    }

    /// Default output's safety offset plus device latency, in frames.
    static var outputHardwareLatencyFrames: (safety: Int, latency: Int)? {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        let safety = value(device, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput)
        let latency = value(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput)
        guard let safety, let latency else { return nil }
        return (Int(safety), Int(latency))
    }

    /// Calls `change` on the main thread when the default devices or the input's running state change.
    static func observe(_ change: @escaping () -> Void) {
        handlers.append(change)
        guard !installed else { return }
        installed = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main, listener)
        }
        watchInput()
    }

    private static func changed() {
        watchInput()
        for handler in handlers { handler() }
    }

    // The running-state listener follows the default input device.
    private static func watchInput() {
        let device = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) ?? AudioObjectID(kAudioObjectUnknown)
        guard device != watchedInput else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if watchedInput != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(watchedInput, &address, .main, listener)
        }
        if device != kAudioObjectUnknown {
            AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        }
        watchedInput = device
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        guard let id = value(AudioObjectID(kAudioObjectSystemObject), selector), id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }
}
