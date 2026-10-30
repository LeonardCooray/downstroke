// Adapted from Switchcraft's HIDAccelerometer (MIT), after olvvier/apple-silicon-accelerometer (MIT).
import DownstrokeCore
import Foundation
import IOKit
import IOKit.hid
import Synchronization

enum MotionSensorError: Error, CustomStringConvertible {
    case notFound
    case openFailed(IOReturn)
    case noDevice

    var description: String {
        switch self {
        case .notFound: "no accelerometer (AppleSPUHIDDevice, usage page 0xFF00 usage 3) in IORegistry"
        case .openFailed(let code): "IOHIDManagerOpen failed (IOReturn \(MotionSensor.hex(code)))"
        case .noDevice: "IOHIDManager opened but returned no accelerometer device"
        }
    }
}

/// Streams the SPU accelerometer on its own thread into a SampleRing as filtered impacts.
final class MotionSensor: @unchecked Sendable {
    static let usagePage = 0xFF00
    static let usage = 3
    static let reportLength = 22
    static let dataOffset = 6
    static let scale: Float = 65536
    static let bufferSize = 4096
    static let restartGap = 0.1

    // CF handles are thread-safe; the mutex guards the references.
    private struct State: @unchecked Sendable {
        var handler: (@Sendable (Double) -> Void)?
        var runLoop: CFRunLoop?
        var finished: DispatchSemaphore?
        var running = false
        var startError: MotionSensorError?
        var wakeResult: IOReturn = kIOReturnSuccess
    }

    private let ring: SampleRing
    private let state = Mutex(State())
    private let stopRequested = Atomic<Bool>(false)
    private let filterResetRequested = Atomic<Bool>(false)
    private let lastSampleBits = Atomic<UInt64>(0)
    // Sensor-thread confined.
    private var filter = ImpactFilter()
    private var lastSampleTime = 0.0
    private var devices: [IOHIDDevice] = []

    init(ring: SampleRing) {
        self.ring = ring
    }

    /// Called on the sensor thread with each sample's time, after it is in the ring.
    var onSample: (@Sendable (Double) -> Void)? {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }

    var isRunning: Bool { state.withLock { $0.running } }

    var isStreaming: Bool {
        let last = Double(bitPattern: lastSampleBits.load(ordering: .relaxed))
        return isRunning && last > 0 && MonotonicClock.now() - last < 0.5
    }

    /// Result of the latest wake: the first failing IORegistryEntrySetCFProperty, or success.
    var lastWakeResult: IOReturn { state.withLock { $0.wakeResult } }

    func start() throws {
        guard !isRunning else { return }
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        stopRequested.store(false, ordering: .relaxed)
        state.withLock {
            $0.finished = done
            $0.startError = nil
        }
        let thread = Thread { [self] in
            run(ready: ready)
            done.signal()
        }
        thread.name = "com.leonardcooray.downstroke.motion"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if let error = state.withLock({ $0.startError }) {
            done.wait()
            state.withLock { $0.finished = nil }
            throw error
        }
    }

    /// Stops streaming and waits up to 1 s for the sensor thread to finish.
    func stop() {
        guard let done = state.withLock({ $0.finished }) else { return }
        stopRequested.store(true, ordering: .releasing)
        if let loop = state.withLock({ $0.runLoop }) { CFRunLoopStop(loop) }
        _ = done.wait(timeout: .now() + 1)
        state.withLock { $0.finished = nil }
    }

    /// Rewrites the wake properties (after sleep, say) and re-primes the filter.
    func rewake() {
        let result = Self.wake()
        state.withLock { $0.wakeResult = result }
        filterResetRequested.store(true, ordering: .releasing)
    }

    static var isPresent: Bool {
        var found = false
        forEachAccelerometer("AppleSPUHIDDevice") { _ in found = true }
        return found
    }

    /// Writing these to the driver service (not the HID device) is what makes the sensor stream after a restart.
    @discardableResult
    static func wake() -> IOReturn {
        var result: IOReturn = kIOReturnNotFound
        forEachAccelerometer("AppleSPUHIDDriver") { service in
            if result == kIOReturnNotFound { result = kIOReturnSuccess }
            for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 1000)] {
                let r = IORegistryEntrySetCFProperty(service, key as CFString, value as CFNumber)
                if r != KERN_SUCCESS && result == kIOReturnSuccess { result = r }
            }
        }
        return result
    }

    static func hex(_ code: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: code)) }

    private static func forEachAccelerometer(_ className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let page = IORegistryEntryCreateCFProperty(service, kIOHIDPrimaryUsagePageKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            let usage = IORegistryEntryCreateCFProperty(service, kIOHIDPrimaryUsageKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            if page == usagePage && usage == Self.usage { body(service) }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func fail(_ error: MotionSensorError, _ ready: DispatchSemaphore) {
        state.withLock { $0.startError = error }
        ready.signal()
    }

    private func run(ready: DispatchSemaphore) {
        guard Self.isPresent else { return fail(.notFound, ready) }
        let wakeResult = Self.wake()
        state.withLock { $0.wakeResult = wakeResult }

        let none = IOOptionBits(kIOHIDOptionsTypeNone)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, none)
        let matching: [String: Any] = [kIOHIDPrimaryUsagePageKey: Self.usagePage, kIOHIDPrimaryUsageKey: Self.usage,
                                       kIOHIDTransportKey: "SPU"]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let openResult = IOHIDManagerOpen(manager, none)
        guard openResult == kIOReturnSuccess else { return fail(.openFailed(openResult), ready) }
        defer { IOHIDManagerClose(manager, none) }
        // Held for the whole run: a released IOHIDDevice silently stops its callbacks.
        devices = Array((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [])
        guard !devices.isEmpty else { return fail(.noDevice, ready) }

        let loop = CFRunLoopGetCurrent()!
        let buffers = devices.map { _ in UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize) }
        defer { buffers.forEach { $0.deallocate() } }
        filter = ImpactFilter()
        lastSampleTime = 0
        filterResetRequested.store(false, ordering: .relaxed)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for (device, buffer) in zip(devices, buffers) {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, Self.bufferSize, motionReportCallback, context)
            IOHIDDeviceScheduleWithRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
        }
        state.withLock {
            $0.runLoop = loop
            $0.running = true
        }
        ready.signal()

        while !stopRequested.load(ordering: .acquiring) {
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
        }

        for (device, buffer) in zip(devices, buffers) {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, Self.bufferSize, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
        }
        devices = []
        lastSampleBits.store(0, ordering: .relaxed)
        state.withLock {
            $0.runLoop = nil
            $0.running = false
        }
    }

    fileprivate func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: Int, timestamp: UInt64) {
        guard length == Self.reportLength else { return }
        let raw = UnsafeRawPointer(report)
        func axis(_ i: Int) -> Float {
            Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: Self.dataOffset + 4 * i, as: Int32.self))) / Self.scale
        }
        // HID report timestamps are mach ticks.
        let time = timestamp != 0 ? MonotonicClock.seconds(fromMachTicks: timestamp) : MonotonicClock.now()
        if filterResetRequested.exchange(false, ordering: .acquiring) || time - lastSampleTime > Self.restartGap {
            filter = ImpactFilter()
        }
        lastSampleTime = time
        ring.append(time: time, impact: filter.process(AccelSample(time: time, x: axis(0), y: axis(1), z: axis(2))))
        lastSampleBits.store(time.bitPattern, ordering: .relaxed)
        state.withLock { $0.handler }?(time)
    }
}

private func motionReportCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
                                  type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                                  reportLength: CFIndex, timeStamp: UInt64) {
    guard let context, result == kIOReturnSuccess else { return }
    Unmanaged<MotionSensor>.fromOpaque(context).takeUnretainedValue()
        .handleReport(report, length: reportLength, timestamp: timeStamp)
}
