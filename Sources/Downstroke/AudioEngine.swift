import AudioToolbox
import AVFoundation
import DownstrokeCore
import Foundation
import Synchronization

/// Counters the render thread writes with atomics only.
final class RenderStats: Sendable {
    let renders = Atomic<Int>(0)
    let overruns = Atomic<Int>(0)
    // Output host time minus the time the render started, from the latest render.
    let leadBits = Atomic<UInt64>(0)
    let worstBits = Atomic<UInt64>(0)
    let minLeadBits = Atomic<UInt64>(Double.infinity.bitPattern)

    var lead: Double { Double(bitPattern: leadBits.load(ordering: .relaxed)) }
    var worstRender: Double { Double(bitPattern: worstBits.load(ordering: .relaxed)) }
    /// Smallest lead seen; subtracting it from an output-time latency bounds the render-time latency from above.
    var minLead: Double { Double(bitPattern: minLeadBits.load(ordering: .relaxed)) }
}

/// Hosts the VoiceMixer in one AVAudioSourceNode at the output device's rate.
@MainActor
final class AudioEngine {
    static let requestedBufferFrames: UInt32 = 128

    /// How `pause()` idles the engine; the bench measures both.
    enum IdleMode {
        case pause, stop

        var name: String { self == .pause ? "pause()" : "stop() + prepare()" }
    }

    private enum Want { case off, paused, running }

    let stats = RenderStats()
    private let mixer: VoiceMixer
    private var engine = AVAudioEngine()
    private var observer: (any NSObjectProtocol)?
    private var want = Want.off

    private(set) var sampleRate: Double = 48000
    private(set) var ioBufferFrames = Int(requestedBufferFrames)
    private(set) var lastError: (any Error)?
    /// Main thread, after every rebuild (output device or format change).
    var onReconfigure: (() -> Void)?
    var idleMode = IdleMode.stop

    init(mixer: VoiceMixer) {
        self.mixer = mixer
        // Primes the clock's timebase off the render thread.
        _ = MonotonicClock.now()
        build()
    }

    var isRunning: Bool { engine.isRunning }

    /// Paused for idleness: not rendering, and `start()` resumes it.
    var isPaused: Bool { want == .paused && !engine.isRunning }

    func start() throws {
        let resuming = want == .paused
        want = .running
        guard !engine.isRunning else { return }
        #if DEBUG
        if let simulatedStartFailure {
            lastError = simulatedStartFailure
            throw simulatedStartFailure
        }
        if simulatedStartDelay > 0 { Thread.sleep(forTimeInterval: simulatedStartDelay) }
        #endif
        // A device change can go unannounced while paused; resume on a matching engine.
        if resuming, outputRateChanged {
            reconfigure()
            if !engine.isRunning, let lastError { throw lastError }
            return
        }
        do {
            try run()
            lastError = nil
        } catch {
            lastError = error
            throw error
        }
    }

    /// Idles a running engine (or one whose start failed) until the next `start()`.
    func pause() {
        guard want == .running else { return }
        want = .paused
        switch idleMode {
        case .pause: engine.pause()
        case .stop:
            engine.stop()
            engine.prepare()
        }
    }

    func stop() {
        want = .off
        engine.stop()
    }

    private var outputRateChanged: Bool {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return rate > 0 && rate != sampleRate
    }

    private func run() throws {
        engine.prepare()
        engine.outputNode.withAudioUnit { unit in
            guard let unit = copy unit else { return }
            var frames = Self.requestedBufferFrames
            AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                 &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        try engine.start()
        let granted: UInt32 = engine.outputNode.withAudioUnit { unit in
            guard let unit = copy unit else { return 0 }
            var frames: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, &size)
            return status == noErr ? frames : 0
        }
        if granted > 0 { ioBufferFrames = Int(granted) }
    }

    // A fresh engine per device: the source node's format is fixed at creation.
    private func build() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine = AVAudioEngine()
        let deviceRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = deviceRate > 0 ? deviceRate : 48000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format, renderBlock: Self.renderBlock(mixer: mixer, stats: stats, sampleRate: sampleRate))
        engine.attach(node)
        do { try engine.connectNode(node, to: engine.mainMixerNode, format: format) } catch { lastError = error }
        mixer.setSampleRate(sampleRate)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconfigure() }
        }
    }

    private func reconfigure() {
        engine.stop()
        build()
        // A paused engine stays paused; the next start() runs the fresh one.
        if want == .running {
            do {
                try run()
                lastError = nil
            } catch {
                lastError = error
            }
        }
        onReconfigure?()
    }

    private nonisolated static func renderBlock(mixer: VoiceMixer, stats: RenderStats,
                                                sampleRate: Double) -> AVAudioSourceNodeRenderBlock {
        { [unowned(unsafe) mixer, unowned(unsafe) stats] _, timestamp, frameCount, data in
            let start = mach_absolute_time()
            let now = MonotonicClock.seconds(fromMachTicks: start)
            let ts = timestamp.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? MonotonicClock.seconds(fromMachTicks: ts.mHostTime) : now
            let buffers = UnsafeMutableAudioBufferListPointer(data)
            guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let frames = Int(frameCount)
            mixer.render(frames: frames, hostTime: host, left: left, right: right)
            let elapsed = MonotonicClock.seconds(fromMachTicks: mach_absolute_time() &- start)
            if elapsed > Double(frames) / sampleRate / 2 { stats.overruns.add(1, ordering: .relaxed) }
            if elapsed > stats.worstRender { stats.worstBits.store(elapsed.bitPattern, ordering: .relaxed) }
            let lead = host - now
            stats.leadBits.store(lead.bitPattern, ordering: .relaxed)
            if lead < stats.minLead { stats.minLeadBits.store(lead.bitPattern, ordering: .relaxed) }
            stats.renders.add(1, ordering: .relaxed)
            return noErr
        }
    }

    #if DEBUG
    /// Posts a configuration change for the current engine, as macOS would on a device switch.
    func simulateConfigurationChange() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    var engineIdentity: ObjectIdentifier { ObjectIdentifier(engine) }

    /// Makes every start() throw this until cleared.
    var simulatedStartFailure: (any Error)?
    /// Seconds each start() blocks first, like a slow device.
    var simulatedStartDelay = 0.0
    #endif
}
