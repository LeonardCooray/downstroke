import AppKit
import Combine
import DownstrokeCore
import Foundation

enum SensorStatus: Equatable {
    case off
    case starting
    case streaming
    case stalled
    case unavailable(String)
}

enum BundledPacks {
    /// Boards from the app bundle's SoundPacks folder, plus one message per skipped pack.
    static func load() -> ([Board], [String]) {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("SoundPacks") else { return ([], ["no resource folder"]) }
        do { return try PackLibrary.loadReporting(from: url) } catch { return ([], ["\(url.path): \(error.localizedDescription)"]) }
    }
}

/// 1 ms pipeline tick that runs only while a press waits for its hit window.
final class PendingTicker: @unchecked Sendable {
    private let pipeline: TypingPipeline
    private let queue = DispatchQueue(label: "com.leonardcooray.downstroke.tick", qos: .userInteractive)
    private let timer: DispatchSourceTimer
    // Queue confined.
    private var armed = false

    init(pipeline: TypingPipeline) {
        self.pipeline = pipeline
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [unowned self] in
            pipeline.tick(now: MonotonicClock.now())
            if !pipeline.hasPending { disarm() }
        }
        timer.schedule(deadline: .distantFuture)
        timer.activate()
    }

    deinit { timer.cancel() }

    /// Any thread, after each key event.
    func keyHandled() {
        guard pipeline.hasPending else { return }
        // Arming on the timer's queue keeps it ordered with the handler's disarm.
        queue.async { [self] in
            guard !armed, pipeline.hasPending else { return }
            armed = true
            timer.schedule(deadline: .now() + .milliseconds(1), repeating: .milliseconds(1), leeway: .microseconds(100))
        }
    }

    private func disarm() {
        armed = false
        timer.schedule(deadline: .distantFuture)
    }
}

/// Owns the tap, sensor, pipeline, mixer and engine, and publishes their state for the UI.
@MainActor
final class AppController: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var permissionMissing = false
    @Published private(set) var sensorStatus = SensorStatus.off
    @Published private(set) var latencyP50: Double?
    @Published private(set) var latencyP99: Double?
    @Published private(set) var latencyCount = 0
    @Published private(set) var lastVelocity: Float?
    @Published private(set) var outputIsBluetooth = false
    @Published private(set) var micInUse = false
    @Published private(set) var frontmostBundleID: String?
    @Published private(set) var boards: [Board] = []
    @Published private(set) var packErrors: [String] = []
    @Published private(set) var engineError: String?
    @Published private(set) var settings: DownstrokeSettings

    let queue = TriggerQueue()
    let ring = SampleRing()
    let mixer: VoiceMixer
    let engine: AudioEngine
    let pipeline: TypingPipeline
    private let store: SettingsStore
    private let tap = KeyTap()
    private let sensor: MotionSensor
    private let ticker: PendingTicker
    private let frontmost = FrontmostApp()

    // Every board's bank and the rate it was built at, so switching and auditioning never wait.
    private var banks: [String: (bank: SampleBank, rate: Double)] = [:]
    private var bankRate = 0.0
    private var bankGeneration = 0
    private var stats = LatencyStats()
    private var drained: [Double] = []
    private var statusTimer: Timer?
    private var wakeObserver: (any NSObjectProtocol)?
    private var auditionUntil = 0.0
    // Audition latencies never reach LatencyStats: the readout is from real key presses only.
    private var lastAudition = -Double.infinity
    private var auditionedSinceDrain = false
    private var sensorAvailable = false
    private var sensorStartedAt = 0.0

    init(defaults: UserDefaults = .standard) {
        store = SettingsStore(defaults: defaults)
        settings = store.settings
        mixer = VoiceMixer(queue: queue)
        engine = AudioEngine(mixer: mixer)
        pipeline = TypingPipeline(queue: queue, ring: ring)
        sensor = MotionSensor(ring: ring)
        ticker = PendingTicker(pipeline: pipeline)
    }

    func start() {
        let (loaded, errors) = BundledPacks.load()
        boards = loaded
        packErrors = errors
        if !boards.contains(where: { $0.id == settings.boardID }), let first = boards.first {
            settings.boardID = boards.first { $0.id == DownstrokeSettings().boardID }?.id ?? first.id
        }
        bankRate = engine.sampleRate
        _ = bank(for: settings.boardID)
        loadBanks(at: bankRate)

        tap.onEvent = { [pipeline, ticker] e in
            pipeline.keyEvent(e, now: MonotonicClock.now())
            ticker.keyHandled()
        }
        sensor.onSample = { [pipeline] _ in pipeline.tick(now: MonotonicClock.now()) }
        engine.onReconfigure = { [weak self] in self?.engineReconfigured() }
        frontmost.onChange = { [weak self] _ in self?.contextChanged() }
        SystemAudio.observe { [weak self] in self?.contextChanged() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        contextChanged()
        apply()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Actions for the UI

    func setEnabled(_ on: Bool) { update { $0.enabled = on } }

    func setVolume(_ volume: Float) { update { $0.volume = min(max(volume, 0), 1) } }

    func selectBoard(_ id: String) {
        guard boards.contains(where: { $0.id == id }) else { return }
        update { $0.boardID = id }
    }

    func update(_ change: (inout DownstrokeSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        apply()
    }

    /// Plays a press from `boardID`, even while off or muted.
    func audition(_ boardID: String) {
        guard let bank = bank(for: boardID) else { return }
        drainLatencies(keep: !auditionedSinceDrain)
        auditionUntil = MonotonicClock.now() + 2
        startEngine()
        pipeline.audition(boardBank: bank)
        // Stamped after a possibly slow cold engine start, when the trigger is actually queued.
        lastAudition = MonotonicClock.now()
        auditionedSinceDrain = true
    }

    func requestPermission() { KeyTap.requestPermission() }

    // MARK: Wiring

    private func apply() {
        store.settings = settings
        store.save()
        mixer.setMasterGain(settings.volume)
        if let bank = bank(for: settings.boardID) {
            pipeline.update(settings: settings, bank: bank, sensorAvailable: sensorAvailable)
        }
        if settings.enabled {
            startEngine()
            startTap()
        } else {
            if MonotonicClock.now() >= auditionUntil { engine.stop() }
            tap.stop()
            listening = false
        }
        if settings.enabled && settings.hitStrengthEnabled { startSensor() } else { stopSensor() }
    }

    private func startEngine() {
        do {
            try engine.start()
            engineError = nil
        } catch {
            engineError = "\(error)"
        }
    }

    private func startTap() {
        guard !tap.isRunning else { return }
        guard KeyTap.hasPermission else {
            permissionMissing = true
            listening = false
            return
        }
        do {
            try tap.start()
            permissionMissing = false
            listening = true
        } catch {
            permissionMissing = !KeyTap.hasPermission
            listening = false
        }
    }

    private func startSensor() {
        guard !sensor.isRunning else { return }
        if case .unavailable = sensorStatus { return }
        do {
            try sensor.start()
            sensorStartedAt = MonotonicClock.now()
            sensorStatus = .starting
        } catch {
            sensorStatus = .unavailable("\(error)")
        }
    }

    private func stopSensor() {
        sensor.stop()
        if case .unavailable = sensorStatus { return }
        sensorStatus = .off
    }

    private func contextChanged() {
        frontmostBundleID = frontmost.bundleID
        micInUse = SystemAudio.micInUse
        outputIsBluetooth = SystemAudio.outputIsBluetooth
        pipeline.setContext(frontmostBundleID: frontmostBundleID, micInUse: micInUse)
    }

    @discardableResult
    private func drainLatencies(keep: Bool) -> Int {
        drained.removeAll(keepingCapacity: true)
        mixer.drainLatencies(into: &drained)
        guard keep, !drained.isEmpty else { return drained.count }
        for value in drained { stats.add(value) }
        latencyP50 = stats.p50
        latencyP99 = stats.p99
        latencyCount = stats.count
        return drained.count
    }

    private func didWake() {
        if case .unavailable = sensorStatus { sensorStatus = .off }
        if sensor.isRunning { sensor.rewake() }
        apply()
    }

    private func engineReconfigured() {
        outputIsBluetooth = SystemAudio.outputIsBluetooth
        if let error = engine.lastError { engineError = "\(error)" }
        guard engine.sampleRate != bankRate else { return }
        bankRate = engine.sampleRate
        loadBanks(at: bankRate)
    }

    // 4 Hz: latency stats, retired banks, sensor and permission state.
    private func refresh() {
        // An audition's sample lands within a render or two of being queued; wait that out, then drop the whole drain.
        if !auditionedSinceDrain {
            drainLatencies(keep: true)
        } else if MonotonicClock.now() - lastAudition >= 0.05 {
            // Clear only once the audition's sample has been discarded, or after 1 s if it never comes.
            if drainLatencies(keep: false) > 0 || MonotonicClock.now() - lastAudition >= 1 { auditionedSinceDrain = false }
        }
        mixer.collectRetired(now: MonotonicClock.now())
        let velocity = pipeline.lastVelocity
        if velocity != lastVelocity { lastVelocity = velocity }

        let streaming = sensor.isStreaming
        if sensor.isRunning {
            let status: SensorStatus = streaming ? .streaming
                : MonotonicClock.now() - sensorStartedAt < 1 ? .starting : .stalled
            if status != sensorStatus { sensorStatus = status }
        }
        if streaming != sensorAvailable {
            sensorAvailable = streaming
            if let bank = banks[settings.boardID]?.bank {
                pipeline.update(settings: settings, bank: bank, sensorAvailable: streaming)
            }
        }
        if settings.enabled && !tap.isRunning && KeyTap.hasPermission { startTap() }
        if !settings.enabled && engine.isRunning && MonotonicClock.now() >= auditionUntil && mixer.activeVoices == 0 {
            engine.stop()
        }
    }

    // MARK: Banks

    /// The loaded bank, or one built now if the background load hasn't reached it yet.
    private func bank(for id: String) -> SampleBank? {
        if let loaded = banks[id] { return loaded.bank }
        guard let board = boards.first(where: { $0.id == id }),
              let bank = try? SampleBank(board: board, sampleRate: bankRate) else { return nil }
        banks[id] = (bank, bankRate)
        return bank
    }

    /// Builds banks off the main thread, current board first; a newer generation supersedes older ones.
    private func loadBanks(at rate: Double) {
        bankGeneration += 1
        let generation = bankGeneration
        let current = settings.boardID
        let todo = boards.filter { banks[$0.id]?.rate != rate }.sorted { $0.id == current && $1.id != current }
        guard !todo.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for board in todo {
                guard let bank = try? SampleBank(board: board, sampleRate: rate) else { continue }
                Task { @MainActor in self?.install(bank, rate: rate, generation: generation) }
            }
        }
    }

    // Replaced banks are retired, never dropped: voices or queued triggers may still read them.
    private func install(_ bank: SampleBank, rate: Double, generation: Int) {
        guard generation == bankGeneration, banks[bank.boardID]?.rate != rate else { return mixer.retire(bank) }
        if let old = banks[bank.boardID] { mixer.retire(old.bank) }
        banks[bank.boardID] = (bank, rate)
        if bank.boardID == settings.boardID {
            pipeline.update(settings: settings, bank: bank, sensorAvailable: sensorAvailable)
        }
    }
}
