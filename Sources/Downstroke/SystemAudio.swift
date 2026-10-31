import CoreAudio
import Foundation

/// Default-device facts from the Core Audio HAL. Never opens the microphone.
@MainActor
enum SystemAudio {
    private static var handlers: [() -> Void] = []
    private static var installed = false
    private static var watchedInput = AudioObjectID(kAudioObjectUnknown)
    private static var watchedProcesses: Set<AudioObjectID> = []
    private static let listener: AudioObjectPropertyListenerBlock = { _, _ in
        MainActor.assumeIsolated { changed() }
    }

    static var outputIsBluetooth: Bool {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
              let transport = value(device, kAudioDevicePropertyTransportType) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Another process is running audio input on any device.
    static var micInUse: Bool {
        if let processes = processObjects() {
            let me = getpid()
            return processes.contains { process in
                guard value(process, kAudioProcessPropertyIsRunningInput) ?? 0 != 0 else { return false }
                return value(process, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) } != me
            }
        }
        // Device-wide flag: our own output would set it when input and output share a device.
        guard let input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
              input != defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
              let running = value(input, kAudioDevicePropertyDeviceIsRunningSomewhere) else { return false }
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
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyProcessObjectList] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main, listener)
        }
        watchInput()
        watchProcesses()
    }

    private static func changed() {
        watchInput()
        watchProcesses()
        for handler in handlers { handler() }
    }

    // A running-input listener on every audio client process; the list listener keeps the set current.
    private static func watchProcesses() {
        let current = Set(processObjects() ?? [])
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        for gone in watchedProcesses.subtracting(current) {
            AudioObjectRemovePropertyListenerBlock(gone, &address, .main, listener)
        }
        for new in current.subtracting(watchedProcesses) {
            AudioObjectAddPropertyListenerBlock(new, &address, .main, listener)
        }
        watchedProcesses = current
    }

    #if DEBUG
    /// PIDs of audio client processes and whether each is running input, for the mic self-test.
    static var processInputStates: [(pid: pid_t, input: Bool)]? {
        processObjects()?.map { process in
            (value(process, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) } ?? -1,
             value(process, kAudioProcessPropertyIsRunningInput) ?? 0 != 0)
        }
    }
    #endif

    /// The HAL's audio client process objects, or nil when the list is unavailable.
    private static func processObjects() -> [AudioObjectID]? {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
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
