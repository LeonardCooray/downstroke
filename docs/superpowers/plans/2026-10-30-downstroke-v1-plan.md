# Downstroke v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Downstroke, a menu bar Mac app that plays a real mechanical-switch recording on every key press and release, shaped by hit strength measured with the MacBook's accelerometer, through a real-time audio engine with measured latency.

**Architecture:** A SwiftPM package with two targets. `DownstrokeCore` holds everything testable without permissions or hardware: sensor maths, key classification and layout, sound-pack loading, PCM decoding and layer derivation, the real-time voice mixer and its lock-free trigger queue, trigger planning, mute rules, the typing pipeline and settings. `Downstroke` is the AppKit app: the listen-only `CGEvent` tap, the IOKit accelerometer reader, the `AVAudioEngine` host, output-device and microphone watchers, the menu bar panel (mockup A), the settings window, the hotkey and the `--probe`, `--bench` and `--self-test` modes.

**Tech Stack:** Swift 6.4.2, SwiftPM, AppKit, SwiftUI (panel and settings, `ObservableObject` only), AVFoundation (`AVAudioEngine`, `AVAudioSourceNode`, `AVAudioFile`, `AVAudioConverter`), Core Audio HAL properties, IOKit HID, Carbon `RegisterEventHotKey`, `SMAppService`, `Synchronization` (`Atomic`, `Mutex`), Swift Testing. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-30-downstroke-design.md` in the repo (copied in Task 1 from the workstation's `Meckey REA Resources/2026-10-30-meckey-rea-design.md`). Prior art: `prior-art-research-2026-10-30.md`. Sensor facts: Switchcraft's `docs/SENSOR.md`; pack format: Switchcraft's `docs/SOUNDPACK_FORMAT.md`.

## Global Constraints

- Repo: public `LeonardCooray/downstroke`, cloned at `/Users/leonard/src/downstroke`, MIT. All work on branch `feat/v1`, never `main`; Leonard merges. Commits use `git -c user.name="Leonard Cooray" -c user.email="leonardcooray@gmail.com"`. No Claude attribution in commits or PRs.
- Bundle ID `com.leonardcooray.downstroke`, app name `Downstroke`, minimum macOS 27.0, menu bar only (`LSUIElement`), no Dock icon. Signing identity `Downstroke Local Signing` (ad-hoc fallback with a warning, as Tracer).
- SwiftPM and the Command Line Tools only. Tests use Swift Testing, run with `scripts/test.sh` (never bare `swift test`). No `@State`, `@Observable` or other Observation/SwiftUI state macros in app code; use `ObservableObject` + `@Published` + `@StateObject`/`@ObservedObject`. `scripts/bundle.sh` builds in `build/.swiftpm-build`.
- Permissions: Input Monitoring only (listen-only tap). Never prompt at launch; request from a panel button. Never Accessibility, never the microphone.
- No network code of any kind.
- Read only key code, autorepeat flag and event timestamp. Never characters. Never store or log key events.
- Render thread rules: no allocation, no waiting locks, no file I/O, no decoding, no logging, no Objective-C/Swift class retain/release in the render loop. Producers reach it through a lock-free queue; the render thread only uses atomics.
- Hit-strength window: 15 ms before to 8 ms after the key event. Bump rejection above 0.3 g. Fixed strength is velocity 0.5.
- Velocity layers soft/medium/hard/slam centred at 0.125/0.375/0.625/0.875, crossfaded linearly between the two nearest.
- Per-press variation: playback rate uniform in 0.97…1.03, gain uniform in 0.9…1.1. Autorepeat presses don't play.
- Voices: at least 48, oldest stolen when full. I/O buffer request 128 frames.
- Defaults: enabled on, volume 0.68, board `holy-panda`, hit strength on (unless Task 3's checkpoint says otherwise), sensitivity 0.5, key-up sounds on, stereo width 0.5, muted apps empty, mute while mic in use on, launch at login off, hotkey ⌃⌥⌘K.
- Launch at login via `SMAppService.mainApp` only.
- Licence notices for Switchcraft (MIT), Mechvibes (MIT), kbsim (MIT), olvvier/apple-silicon-accelerometer (MIT) and the freesound CC0 recordings stay in `LICENSES/` and are credited in the README and About box. Nothing from Meckey.
- Code comments are one short line or none.

## Review Focus

- **Output device changes mid-typing** (headphones in or out, AirPods connect): the engine rebuilds on `AVAudioEngineConfigurationChange`, the next key plays, nothing crashes, and the footer switches to "Bluetooth adds delay" for Bluetooth. (Task 8 self-test `audio-reconfigure`.)
- **macOS disables the event tap** (`tapDisabledByTimeout` / `ByUserInput`) or Input Monitoring is revoked while running: the tap re-enables itself; if it can't be created the panel shows the permission banner. (Task 3 `KeyTapTests`-style self-test `tap-reenable`; Task 9 banner.)
- **Sensor stalls** (sleep/wake, lid closed on an external keyboard): pending presses are flushed at fixed strength no later than 12 ms after the key event, and the sensor is re-woken after system wake. (Task 7 test `stalledSensorFlushesAtFixedStrength`; Task 8 wake handler.)
- **Board switched while sounds are still ringing:** no click, no crash, and the old bank's memory is freed only after its retire delay. (Task 6 test `retiredBankOutlivesVoices`.)
- **Bursts and chords beyond 48 voices:** the oldest voice is stolen and the limiter keeps output within ±1.0. (Task 6 tests `stealsOldestVoiceWhenFull` and `limiterNeverExceedsFullScale`.)

---

## File Structure

```
downstroke/
  Package.swift
  Resources/Info.plist
  Resources/SoundPacks/<id>.switchcraft/   # 20 packs vendored from Switchcraft, manifest gains "texture"
  LICENSES/                                # Switchcraft, mechvibes, kbsim, apple-silicon-accelerometer (MIT), freesound CC0 note
  scripts/test.sh  scripts/bundle.sh  scripts/vendor-packs.sh
  docs/signing.md
  docs/superpowers/specs/2026-10-30-downstroke-design.md
  docs/superpowers/plans/2026-10-30-downstroke-v1-plan.md
  Sources/DownstrokeCore/
    MonotonicClock.swift   # seconds on the mach clock
    Sensor.swift           # AccelSample, SampleRing, ImpactFilter, ImpactAnalyzer
    VelocityMapper.swift
    Keys.swift             # KeyEvent, KeyGroup, KeyClassifier, KeyLayout
    Packs.swift            # PackManifest, Texture, Board, PackLibrary
    PCM.swift              # PCMClip, AudioDecoder
    LayerDerivation.swift  # soft/medium/slam from a hard hit
    SampleBank.swift       # owned PCM storage + clip lookup with fallback
    TriggerQueue.swift     # lock-free SPSC ring with a producer-side Mutex
    VoiceMixer.swift       # render(), voices, limiter, latency taps
    LatencyStats.swift
    TriggerPlanner.swift   # KeyEvent + velocity + settings -> [Trigger]
    MuteRules.swift
    TypingPipeline.swift
    Settings.swift         # DownstrokeSettings + SettingsStore
    Hotkey.swift           # copied from Tracer (Leonard's own MIT code)
  Sources/Downstroke/
    main.swift  AppController.swift
    KeyTap.swift  MotionSensor.swift  AudioEngine.swift  SystemAudio.swift  FrontmostApp.swift
    HotkeyCenter.swift     # adapted from Tracer
    AppModel.swift  MenuBarController.swift  PanelView.swift  SettingsView.swift
    ProbeMode.swift  BenchMode.swift  DebugSelfTest.swift
  Tests/DownstrokeCoreTests/  (one file per Core file above)
```

---

### Task 1: Repo, skeleton, vendored packs, signed menu bar app

**Files:**
- Create: `Package.swift`, `Resources/Info.plist`, `scripts/test.sh`, `scripts/bundle.sh`, `scripts/vendor-packs.sh`, `docs/signing.md`, `LICENSE`, `LICENSES/*`, `README.md` (stub), `Sources/Downstroke/main.swift`, `Sources/Downstroke/MenuBarController.swift`, `Sources/DownstrokeCore/MonotonicClock.swift`, `Tests/DownstrokeCoreTests/MonotonicClockTests.swift`, the spec and plan copies under `docs/superpowers/`.

**Interfaces:**
- Produces: `MonotonicClock.now() -> Double`, `MonotonicClock.seconds(fromMachTicks: UInt64) -> Double`, `MonotonicClock.seconds(fromNanoseconds: UInt64) -> Double` (all seconds on the mach clock); `Resources/SoundPacks/` populated; `build/Downstroke.app` signed.

- [ ] **Step 1:** `gh repo create LeonardCooray/downstroke --public --clone` into `/Users/leonard/src/downstroke`, add an empty initial commit on `main`, push, then `git switch -c feat/v1`.
- [ ] **Step 2:** Copy Tracer's `scripts/test.sh`, `scripts/bundle.sh` and `docs/signing.md`, replacing Tracer/TRACER with Downstroke/DOWNSTROKE; `bundle.sh` also copies `Resources/SoundPacks` into `Contents/Resources/SoundPacks`. `Package.swift`: targets `DownstrokeCore`, `Downstroke` (executable, depends on Core), `DownstrokeCoreTests`; platform `.macOS("27.0")`. `Info.plist` as Tracer's with Downstroke values.
- [ ] **Step 3:** `scripts/vendor-packs.sh`: sparse-clone `mustafa4101996ahmed/switchcraft` at a pinned commit (record the SHA in the script), copy `SoundPacks/*.switchcraft` to `Resources/SoundPacks/` and `LICENSES/*` (excluding Sparkle) to `LICENSES/`, then add `"texture"` to each manifest from this table:

| texture | pack ids |
|---|---|
| thocky | holy-panda, topre, cherry-mx-black-pbt, cherry-mx-brown-pbt |
| creamy | nk-cream, alpaca, turquoise, red-ink, black-ink |
| clacky | cherry-mx-blue-abs, cherry-mx-blue-pbt, box-navy, blue-alps, buckling-spring |
| crisp | cherry-mx-red-abs, cherry-mx-brown-abs, cherry-mx-clear |
| thump | cherry-mx-black-abs, cherry-mx-red-pbt, cherry-mx-silent |

  Add `LICENSES/freesound-CC0.txt` naming humi74 (412926) and bonesawmgraw (572978). Run it; expect 20 folders and about 5.4 MB of WAVs.
- [ ] **Step 4:** Failing test `machTicksRoundTrip`: `#expect(abs(MonotonicClock.seconds(fromMachTicks: mach_absolute_time()) - MonotonicClock.now()) < 0.001)` and `seconds(fromNanoseconds: 1_500_000_000) == 1.5`. Run `scripts/test.sh` → fails to compile. Implement with `mach_timebase_info`. Run → passes.
- [ ] **Step 5:** `main.swift` + `MenuBarController`: an `NSStatusItem` with a keyboard SF Symbol that opens an empty `NSPanel` (non-activating, `.hudWindow`-style vibrancy via `NSVisualEffectView` `.popover` material, built once at launch and reused). Run `scripts/bundle.sh --debug`; expect `Built build/Downstroke.app` (or the ad-hoc warning). `codesign -dv build/Downstroke.app` shows identifier `com.leonardcooray.downstroke`.
- [ ] **Step 6:** Commit `feat: package skeleton, vendored switch packs, signed menu bar app`.

### Task 2: Sensor maths

**Files:** Create `Sources/DownstrokeCore/Sensor.swift`, `VelocityMapper.swift`; tests `SensorTests.swift`, `VelocityMapperTests.swift`.

**Interfaces:**
- Produces: `struct AccelSample { time: Double; x, y, z: Float }` (g); `final class SampleRing: @unchecked Sendable` with `init(capacity: Int = 4096)`, `append(_ s: AccelSample)` (single writer, wait-free), `impacts(from: Double, to: Double) -> [Float]` (reader; may allocate), `latestTime: Double?`; `struct ImpactFilter` with `init(sampleRate: Double = 800, cutoff: Double = 25)`, `mutating func process(_ s: AccelSample) -> Float` (2nd-order Butterworth high-pass per axis, returns vector magnitude in g); the ring stores the filtered magnitude alongside time; `enum ImpactAnalyzer { static func peak(in ring: SampleRing, keyTime: Double, preMs: Double = 15, postMs: Double = 8) -> Float? }` (nil when the ring has no sample at or after `keyTime + postMs/1000`); `struct VelocityMapper { init(sensitivity: Float); func velocity(forPeak g: Float) -> Float? }`.

- [ ] **Step 1: Failing tests** (synthetic 800 Hz signals, generator helper in the test file):
```swift
@Test func filterRemovesGravity() // 1 s of constant (0,0,1) g → last 400 outputs all < 0.0005
@Test func peakFindsBottomOutInsideWindow() // noise 0.0006 g + 0.012 g impulse at keyTime+0.007 → peak ≈ 0.012 ±0.002
@Test func peakIgnoresImpulseOutsideWindow() // impulse at keyTime+0.020 → peak < 0.002
@Test func peakIsNilBeforeWindowCloses() // ring ends at keyTime+0.005 → nil
@Test func ringWrapsKeepingNewest() // capacity 8, append 20 → impacts covers only the last 8 times
@Test func velocityCurve() // s=0.5: 0.004→0, 0.005→0, 0.06→1, 0.0173→≈0.5 (±0.02), 0.5→nil
@Test func sensitivityMovesCeiling() // s=1: 0.03→1; s=0: 0.12→1
```
- [ ] **Step 2:** Run `scripts/test.sh --filter SensorTests` → fail. Implement. `VelocityMapper`: floor 0.005 g, ceiling `0.06 * pow(4, 0.5 - sensitivity)`, `v = clamp(log(p/floor) / log(ceiling/floor), 0, 1)`, nil above 0.3 g.
- [ ] **Step 3:** Run → pass. Commit `feat(core): accelerometer filter, impact window and velocity mapping`.

### Task 3: Key tap, motion sensor and the probe — CHECKPOINT

**Files:** Create `Sources/DownstrokeCore/Keys.swift` (only `KeyEvent` here; the rest in Task 4), `Sources/Downstroke/KeyTap.swift`, `MotionSensor.swift`, `ProbeMode.swift`, `DebugSelfTest.swift`.

**Interfaces:**
- Consumes: `SampleRing`, `ImpactFilter`, `ImpactAnalyzer`, `MonotonicClock`.
- Produces: `struct KeyEvent: Sendable { time: Double; keyCode: UInt16; isRelease: Bool; isModifier: Bool }`; `final class KeyTap { var onEvent: (@Sendable (KeyEvent) -> Void)?; func start() throws; func stop(); var isRunning: Bool; static var hasPermission: Bool (CGPreflightListenEventAccess); static func requestPermission() (CGRequestListenEventAccess) }`; `final class MotionSensor { init(ring: SampleRing); func start() throws; func stop(); var onSample: (@Sendable (Double) -> Void)?; var isStreaming: Bool; func rewake() }`.

- [ ] **Step 1:** `KeyTap`: listen-only `.cgSessionEventTap` for keyDown, keyUp, flagsChanged on a dedicated `Thread` (`qualityOfService = .userInteractive`) with its own run loop. Autorepeat keyDowns are dropped here. flagsChanged becomes a press or release by comparing the modifier bit for that key code with the previous flags. Event time from `event.timestamp` via `MonotonicClock.seconds(fromNanoseconds:)`, falling back to `now()` when 0. On `tapDisabledByTimeout`/`ByUserInput`, re-enable.
- [ ] **Step 2:** `MotionSensor`: per Switchcraft's `docs/SENSOR.md` (adapt `HIDAccelerometer.swift`, credit in a one-line header comment): match `AppleSPUHIDDevice` usage page 0xFF00 usage 3; write `SensorPropertyReportingState`, `SensorPropertyPowerState`, `ReportInterval` to the `AppleSPUHIDDriver` service with `IORegistryEntrySetCFProperty`; keep a strong reference to the `IOHIDDevice`; parse 22-byte reports (Int32 LE at 6/10/14, ÷65536); timestamp via `IOHIDDeviceRegisterInputReportWithTimeStampCallback`; run on its own `.userInteractive` thread; each sample goes through one `ImpactFilter` into the ring, then `onSample(time)`. `rewake()` rewrites the wake properties.
- [ ] **Step 3:** `ProbeMode` (`Downstroke --probe`): starts both, prints sample rate after 2 s, then prompts "Type 20 SOFT presses" then "Type 20 HARD presses", records `ImpactAnalyzer.peak` per press, and prints `soft median`, `hard median`, `ratio`, `PASS` if ratio ≥ 2.0 else `FAIL`. Exits non-zero if the tap or sensor fails to start, printing which and the IOReturn.
- [ ] **Step 4:** `DebugSelfTest` (`--self-test tap-reenable`): creates a `KeyTap`, simulates the disabled-by-timeout callback path and checks the tap is enabled again (`CGEvent.tapIsEnabled`). Prints PASS/FAIL lines like Tracer. Bundle and run it.
- [ ] **Step 5:** Commit `feat: key tap, motion sensor reader and --probe mode`.
- [ ] **Step 6: CHECKPOINT (Leonard).** Leonard creates `Downstroke Local Signing` (docs/signing.md), runs `scripts/bundle.sh`, grants Input Monitoring to `build/Downstroke.app`, and runs `build/Downstroke.app/Contents/MacOS/Downstroke --probe`. Record the output in the PR description and the workstation MEMORY.md. If the result is FAIL or the sensor won't stream, set the default `hitStrengthEnabled` to `false` in Task 7. Work on Tasks 4–6 may proceed while waiting.

### Task 4: Keys and sound packs

**Files:** Modify `Keys.swift`; create `Packs.swift`; tests `KeysTests.swift`, `PacksTests.swift`.

**Interfaces:**
- Produces: `enum KeyGroup: String, CaseIterable { alpha, number, space, enter, backspace, tab, modifier, arrow, function, escape, punctuation, other }`; `enum KeyClassifier { static func group(for keyCode: UInt16) -> KeyGroup }` (ANSI virtual key codes); `enum KeyLayout { static func position(for keyCode: UInt16) -> Float }` (0 = left edge, 1 = right edge of the MacBook keyboard, 0.5 for unknown); `enum Texture: String, CaseIterable, Codable { thocky, creamy, clacky, crisp, thump }` in that display order with `title` ("Thocky"…); `struct PackManifest: Codable` (fields per Switchcraft format v1 plus `texture: Texture?`, `color: String?`); `struct Board: Identifiable, Sendable { id: String; name: String; texture: Texture; color: String; credits: String; folder: URL; manifest: PackManifest }`; `enum PackLibrary { static func load(from directory: URL) throws -> [Board] }` (sorted by texture order then name; missing texture → `.crisp`; skips invalid packs and reports them via a returned `[String]` of errors in an overload `loadReporting`).

- [ ] **Step 1: Failing tests:**
```swift
@Test func classifiesKeys() // 0(A)→.alpha, 49→.space, 36→.enter, 51→.backspace, 48→.tab, 56(shift)→.modifier, 123→.arrow, 122(F1)→.function, 53→.escape, 18(1)→.number, 43(,)→.punctuation, 200→.other
@Test func layoutPositions() // 50(`) < 0.1, 42(\) > 0.9, 49(space) within 0.45...0.55, 0(A) < 9(V) < 37(L)
@Test func loadsVendoredPacks() // load(Resources/SoundPacks) → 20 boards, first texture .thocky, holy-panda has texture .thocky, every board has non-empty credits
@Test func rejectsWrongFormatVersion() // temp pack formatVersion 2 → skipped, one error mentioning its folder
@Test func scansFoldersWhenSamplesMissing() // temp pack without "samples" + sounds/alpha/hard/1.wav → manifest samples alpha.hard has 1 path
```
  Tests find `Resources/SoundPacks` via `#filePath`.
- [ ] **Step 2:** Run → fail. Implement. Run → pass. Commit `feat(core): key groups, keyboard layout and pack library`.

### Task 5: PCM, velocity layers and the sample bank

**Files:** Create `PCM.swift`, `LayerDerivation.swift`, `SampleBank.swift`; tests `PCMTests.swift`, `LayerDerivationTests.swift`, `SampleBankTests.swift`.

**Interfaces:**
- Produces: `struct PCMClip: Sendable { left: [Float]; right: [Float]? }` with `frameCount`; `enum AudioDecoder { static func decode(_ url: URL, sampleRate: Double) throws -> PCMClip }` (`AVAudioFile` + `AVAudioConverter` to Float32 at `sampleRate`, keeps 1 or 2 channels); `enum Layer: Int, CaseIterable { soft, medium, hard, slam }` with `centre` 0.125/0.375/0.625/0.875; `enum LayerDerivation { static func derive(from hard: PCMClip, sampleRate: Double) -> [Layer: PCMClip] }`; `struct ClipRef: Sendable { left: UnsafePointer<Float>; right: UnsafePointer<Float>?; frames: Int }`; `final class SampleBank: @unchecked Sendable { init(board: Board, sampleRate: Double) throws; let boardID: String; func presses(_ g: KeyGroup, _ l: Layer) -> [ClipRef]; func releases(_ g: KeyGroup) -> [ClipRef]; var byteCount: Int }`. The bank copies every clip into storage it allocates once and frees in `deinit`; `ClipRef`s stay valid for the bank's lifetime. Missing group falls back to `.alpha`; missing layer falls back to the nearest present layer; packs with `deriveVelocityLayers` get derived layers.

- [ ] **Step 1: Failing tests:**
```swift
@Test func decodesAndResamples() // holy-panda alpha hard 1.wav at 48000 and 44100 → frame ratio 48000/44100 ±1%, peak |x| in 0.05...1.0
@Test func softIsDarkerAndQuieter() // derive on a 10 ms white-noise burst: RMS soft < medium < hard; energy above 4 kHz soft < 0.2 × hard
@Test func slamNeverExceedsFullScale() // hard clip at 0.99 peak → slam max |x| ≤ 1.0, RMS slam > hard
@Test func derivationKeepsLengthAndOnset() // every layer same frameCount as hard; first-sample index above 0.01 within 0.8 ms (soft) / identical (others)
@Test func bankFallsBack() // holy-panda bank: presses(.function, .soft) non-empty (from alpha); releases(.space) non-empty
@Test func bankFitsBudget() // all 20 banks at 48 kHz: total byteCount < 80_000_000
```
- [ ] **Step 2:** Run → fail. Implement `derive` exactly per Switchcraft's table: soft = two cascaded 2800 Hz low-pass biquads, −6 dB, 0.8 ms raised-cosine onset; medium = 6500 Hz low-pass, −2.5 dB; hard = unchanged; slam = +5 dB low shelf at 180 Hz, then +2 dB gain into `tanh`, normalised so peak ≤ 1.0. Run → pass.
- [ ] **Step 3:** Commit `feat(core): PCM decoding, derived velocity layers and sample bank`.

### Task 6: Lock-free trigger queue, voice mixer and latency stats

**Files:** Create `TriggerQueue.swift`, `VoiceMixer.swift`, `LatencyStats.swift`; tests for each.

**Interfaces:**
- Consumes: `ClipRef`, `SampleBank`.
- Produces: `struct Trigger: Sendable { clip: ClipRef; gain: Float; pan: Float /* -1…1 */; rate: Float; eventTime: Double }`; `final class TriggerQueue: @unchecked Sendable { init(capacity: Int = 256); func push(_ t: Trigger) -> Bool /* any thread; producers serialised by a Mutex */; func pop() -> Trigger? /* render thread only, atomics only */ }`; `final class VoiceMixer: @unchecked Sendable { init(queue: TriggerQueue, maxVoices: Int = 48); func render(frames: Int, hostTime: Double, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>); func setMasterGain(_ g: Float) /* atomic, smoothed over 10 ms */; func setSampleRate(_ sr: Double); var activeVoices: Int /* atomic */; func drainLatencies(into: inout [Double]) /* main thread */ ; func retire(_ bank: SampleBank, after seconds: Double = 2) /* main thread */ }`; `struct LatencyStats { mutating func add(_ s: Double); var p50: Double?; var p99: Double?; var count: Int }` (last 512 values).

- [ ] **Step 1: Failing tests** (render into preallocated buffers of 128 frames):
```swift
@Test func queueIsFIFOAndBounded() // push 256 → true, 257th → false; pops come out in order
@Test func queueSurvivesConcurrentProducers() // 4 threads × 1000 pushes, one consumer popping → 4000 distinct triggers, none lost or duplicated
@Test func rendersClipWithPanAndGain() // 64-frame clip of 0.5, pan -1, gain 1 → left sum ≈ 32, right ≈ 0
@Test func rateResamplesLinearly() // ramp clip 0..99, rate 0.5 → output[1] ≈ 0.5
@Test func stealsOldestVoiceWhenFull() // 49 long triggers → activeVoices == 48 and the first trigger's voice is gone
@Test func limiterNeverExceedsFullScale() // 48 voices of 0.9 → every output sample |x| ≤ 1.0
@Test func recordsLatencyAtVoiceStart() // trigger eventTime 10.000, render hostTime 10.004 → drainLatencies gives [0.004]
@Test func retiredBankOutlivesVoices() // start a voice from bank A, retire(A, after: 0.05), keep rendering: no crash, voice finishes; A deinit only after 0.05 s and after activeVoices referencing it reach 0
@Test func renderDoesNotAllocate() // render 10_000 cycles with 48 active voices under malloc counting (malloc_zone statistics before/after) → 0 new allocations
@Test func latencyPercentiles() // add 1…100 ms → p50 ≈ 50 ms, p99 ≈ 99 ms
```
- [ ] **Step 2:** Run → fail. Implement: voices preallocated (`UnsafeMutablePointer`), linear interpolation, constant-power pan, instant-attack peak limiter with 50 ms release. Latencies go through a second fixed SPSC ring of `Double` from render to main. Bank retirement: keep retired banks in a main-thread list with a deadline; free when past the deadline and no voice's pointer range falls inside the bank (voices carry the bank's identity as an `Int` tag, not a reference).
- [ ] **Step 3:** Run → pass. Commit `feat(core): lock-free trigger queue and real-time voice mixer`.

### Task 7: Trigger planning, mute rules, typing pipeline and settings

**Files:** Create `TriggerPlanner.swift`, `MuteRules.swift`, `TypingPipeline.swift`, `Settings.swift`, `Hotkey.swift` (copy Tracer's); tests for each.

**Interfaces:**
- Consumes: `KeyEvent`, `KeyClassifier`, `KeyLayout`, `SampleBank`, `Trigger`, `TriggerQueue`, `SampleRing`, `ImpactAnalyzer`, `VelocityMapper`.
- Produces:
  - `struct DownstrokeSettings: Codable, Equatable` with the defaults in Global Constraints (`enabled`, `volume`, `boardID`, `hitStrengthEnabled`, `sensitivity`, `keyUpSounds`, `stereoWidth`, `mutedBundleIDs: [String]`, `muteWhileMicInUse`, `launchAtLogin`, `hotkey: Hotkey`); `final class SettingsStore { init(defaults: UserDefaults = .standard); var settings: DownstrokeSettings; func save() }` (key `settings.v1`; unknown or corrupt data → defaults).
  - `struct TriggerPlanner { var random: any RandomNumberGenerator; mutating func plan(_ e: KeyEvent, velocity: Float, bank: SampleBank, settings: DownstrokeSettings) -> [Trigger] }`: a press yields one trigger per nearest layer (two when between centres) with crossfade weights, gain `(0.55 + 0.45·v) × weight × rand(0.9…1.1)`, rate `rand(0.97…1.03)` shared by both, pan `(KeyLayout.position − 0.5) × 2 × stereoWidth`; a release yields one trigger at gain 0.6 if `keyUpSounds`, else none. Clip choice within a list is random but never the same index twice in a row per group.
  - `enum MuteRules { static func shouldPlay(enabled: Bool, frontmostBundleID: String?, muted: [String], micInUse: Bool, muteWhileMicInUse: Bool) -> Bool }`.
  - `final class TypingPipeline: @unchecked Sendable { init(queue: TriggerQueue, ring: SampleRing?); func update(settings: DownstrokeSettings, bank: SampleBank, sensorAvailable: Bool); func setContext(frontmostBundleID: String?, micInUse: Bool); func keyEvent(_ e: KeyEvent, now: Double); func tick(now: Double) /* sensor thread after each sample, and a 1 ms fallback timer */; func audition(boardBank: SampleBank) }`. Internal state behind a `Mutex`. Sensing on and available: presses wait until `now ≥ time + 0.008`, then velocity = mapper(peak) ?? 0.5. A press still pending at `time + 0.012` is flushed at 0.5. Releases of a pending press are planned right after it. Sensing off or unavailable: plan immediately at 0.5. Muted → drop. `audition` plays a fixed A-key press at v 0.625, centre pan, ignoring mute rules.

- [ ] **Step 1: Failing tests** (fake `TriggerQueue` consumer reading pushed triggers; seeded RNG):
```swift
@Test func settingsDefaultsAndRoundTrip() // fresh suite → defaults equal Global Constraints; change volume, save, reload → equal
@Test func corruptSettingsFallBackToDefaults()
@Test func planCrossfadesNearestLayers() // v=0.5 → two triggers (medium, hard) weights 0.5/0.5; v=0.9 → one (slam)
@Test func planPansByKeyPosition() // keyCode 50 with width 1 → pan < -0.8; width 0 → pan 0
@Test func planVariationInRange() // 1000 plans → rate in 0.97...1.03, gain factor in 0.9...1.1
@Test func noKeyUpWhenDisabled()
@Test func muteRules() // disabled → false; frontmost in muted → false; mic in use + rule on → false; otherwise true
@Test func waitsForWindowWhenSensing() // keyEvent at t=1.0, tick(1.007) → nothing; tick(1.0081) → triggers with velocity from ring
@Test func stalledSensorFlushesAtFixedStrength() // no ring samples; tick(1.0121) → triggers at v 0.5
@Test func immediateWhenSensingOff() // keyEvent at t → triggers pushed during keyEvent
@Test func releaseFollowsPendingPress() // press then release before window closes → press triggers then release trigger, in order
@Test func autorepeatNeverReachesPipeline() // documented: KeyTap drops repeats; pipeline plays every press it receives
```
- [ ] **Step 2:** Run → fail. Implement. Run → pass. Apply Task 3's checkpoint result to the `hitStrengthEnabled` default. Commit `feat(core): trigger planning, mute rules, typing pipeline and settings`.

### Task 8: Audio engine, system audio, end to end, bench

**Files:** Create `Sources/Downstroke/AudioEngine.swift`, `SystemAudio.swift`, `FrontmostApp.swift`, `AppController.swift`, `BenchMode.swift`; extend `DebugSelfTest.swift`.

**Interfaces:**
- Consumes: everything in Core, `KeyTap`, `MotionSensor`.
- Produces: `final class AudioEngine { init(mixer: VoiceMixer); func start() throws; func stop(); var sampleRate: Double; var ioBufferFrames: Int; var onReconfigure: (() -> Void)? }`; `enum SystemAudio { static var outputIsBluetooth: Bool; static var micInUse: Bool; static func observe(_ change: @escaping () -> Void) }`; `final class FrontmostApp { var bundleID: String? ; var onChange }`; `final class AppController: ObservableObject` (owns everything; `@Published` status for the UI: `listening`, `permissionMissing`, `sensorStatus`, `latencyP50`, `latencyP99`, `lastVelocity`, `outputIsBluetooth`, `boards`, `settings`).

- [ ] **Step 1:** `AudioEngine`: one `AVAudioSourceNode` (stereo Float32 at the output device's rate) whose render block calls `mixer.render` with the timestamp's host time in seconds; connect to `mainMixerNode`; set `kAudioDevicePropertyBufferFrameSize` to 128 on the output unit; on `AVAudioEngineConfigurationChange` rebuild, update the mixer's sample rate, reload banks at the new rate if it changed (off the main thread, swap + retire), restart. Keep running while enabled; stop when disabled.
- [ ] **Step 2:** `SystemAudio`: Bluetooth when the default output device's `kAudioDevicePropertyTransportType` is Bluetooth or Bluetooth LE; mic in use via `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device; listeners on default-device and running-state changes call `observe`'s closure. `FrontmostApp` from `NSWorkspace.didActivateApplicationNotification`.
- [ ] **Step 3:** `AppController`: load boards from the bundle's `SoundPacks`, build the current bank synchronously at launch, then all the others on a background queue straight after, so switching or auditioning never waits on decoding. Wire `KeyTap.onEvent → pipeline.keyEvent`, `MotionSensor.onSample → pipeline.tick`, a 1 ms `DispatchSourceTimer` on a `.userInteractive` queue → `pipeline.tick` only while a press is pending, `FrontmostApp`/`SystemAudio` → `pipeline.setContext`, a 4 Hz main-thread timer draining latencies into `LatencyStats` and publishing UI state. Re-wake the sensor on `NSWorkspace.didWakeNotification`.
- [ ] **Step 4:** `--self-test audio` (engine starts, an audition trigger produces a latency sample within 200 ms) and `--self-test audio-reconfigure` (post `AVAudioEngineConfigurationChange`, then a trigger still produces a latency sample). Bundle and run both → PASS.
- [ ] **Step 5:** `BenchMode` (`--bench`): runs the real engine and pipeline with synthetic `KeyEvent`s (and a synthetic sensor feeding the ring for the sensing run) at 15 keys/s for 10 s, sensing off then on; 10 s idle with the engine running. Prints and checks: latency p99 (sensing off) ≤ 0.003 + ioBuffer/sampleRate; latency p99 (sensing on) ≤ 0.008 + 0.003 + ioBuffer/sampleRate; idle CPU ≤ 1.0% of a core and typing CPU ≤ 3.0% (`getrusage` deltas); `phys_footprint` ≤ 100 MB with all 20 banks loaded; render overruns 0 (render calls taking more than half the buffer duration, counted atomically). Prints `PASS`/`FAIL` per line, exits non-zero on any FAIL. If idle CPU fails, pause the engine after 60 s without triggers and re-measure first-key latency after a pause; record which in the PR.
- [ ] **Step 6:** Run `build/Downstroke.app/Contents/MacOS/Downstroke --bench` → all PASS. Commit `feat: audio engine, end-to-end pipeline and bench mode`.

### Task 9: Menu bar panel (mockup A)

**Files:** Create `AppModel.swift` (if `AppController` grows too large, the UI-facing state lives here), `PanelView.swift`; modify `MenuBarController.swift`.

**Interfaces:**
- Consumes: `AppController` published state and its methods `setEnabled(_:)`, `setVolume(_:)`, `selectBoard(_:)`, `audition(_:)`, `requestPermission()`, `openSettings()`.

- [ ] **Step 1:** `PanelView` per mockup A (`.superpowers/brainstorm/*/content/panel-directions.html` option A in the workstation), width 310 pt, inside the existing vibrancy panel, top to bottom:
  - Header: "Downstroke", status line ("Listening · <board>", "Off", "Needs Input Monitoring", "Muted in <app>", "Muted: mic in use"), system `Toggle` (switch style) for on/off.
  - When permission is missing: a banner with "Allow Input Monitoring…" calling `requestPermission()` and a line telling him to reopen the app after granting.
  - "Volume" label and a slider with the percentage.
  - "Hit strength" label and a 16-segment meter driven by `lastVelocity`, decaying over 300 ms; shows "Fixed strength" text instead when sensing is off or unavailable.
  - Boards grouped under texture headings in `Texture` order, each row a stem-colour swatch, the name and a tick on the current board; a hover of 400 ms or the row's play button auditions it; click selects.
  - Footer: "Key → sound N ms" (p50, rounded) or "Bluetooth adds delay", and "Settings… ⌘,".
- [ ] **Step 2:** Panel opens on status-item click within one frame (prebuilt, `orderFront` only), closes on outside click or Escape; ⌘, opens Settings while it's open. Menu bar glyph: `keyboard` SF Symbol, dimmed when off.
- [ ] **Step 3:** `--self-test panel`: opens the panel, checks it's visible, every texture heading present in order, 20 board rows, selecting a row changes `settings.boardID`, and panel open time < 16 ms. Bundle and run → PASS. Take a screenshot of the panel (`screencapture -l <windowID>`) for the PR.
- [ ] **Step 4:** Commit `feat: menu bar panel`.

### Task 10: Settings window, hotkey, per-app mute, launch at login, diagnostics

**Files:** Create `SettingsView.swift`, `HotkeyCenter.swift` (adapted from Tracer); modify `AppController.swift`.

- [ ] **Step 1:** Settings window (⌘,), sections:
  - Sound: hit strength toggle, sensitivity slider (0…1), key-up sounds toggle, stereo width slider.
  - Apps: muted apps list with "+" (pick from running regular apps, store bundle IDs) and "−"; "Mute while the microphone is in use" toggle.
  - General: hotkey recorder (Tracer's), launch at login toggle (`SMAppService.mainApp`, showing the error text if registration fails).
  - Diagnostics: permission state, sensor status (streaming at N Hz / unavailable + reason), output device and Bluetooth flag, I/O buffer frames, sample rate, latency p50/p99 and count, active voices.
  - About: version, credits for every bundled pack and the libraries in `LICENSES/`.
- [ ] **Step 2:** `HotkeyCenter` registers ⌃⌥⌘K by default to toggle `enabled`; a failed registration shows in Settings and the panel status.
- [ ] **Step 3:** `--self-test settings`: changing each setting updates `SettingsStore` and the pipeline (`update` called), muting the frontmost app's bundle ID makes an audition-free synthetic key produce no trigger, and the hotkey handler toggles `enabled`. Bundle and run → PASS.
- [ ] **Step 4:** Commit `feat: settings window, hotkey, per-app and mic muting, launch at login`.

### Task 11: README, final verification and PR

- [ ] **Step 1:** README: what it is, install/build (`scripts/bundle.sh`, signing doc, Input Monitoring), the hit-strength explanation and its 8 ms trade-off, privacy, bench numbers from this Mac, credits and licences for every pack and borrowed approach.
- [ ] **Step 2:** Run `scripts/test.sh` (all pass), `scripts/bundle.sh`, every `--self-test` suite (`tap-reenable`, `audio`, `audio-reconfigure`, `panel`, `settings`) and `--bench`. Paste results into the PR.
- [ ] **Step 3:** Push `feat/v1`, open the PR to `main` with a "Verified" list (tests, self-tests, bench, screenshot) and a "Not verified — needs Leonard" list: real typing feel and hit strength by ear, physical hotkey, Input Monitoring grant flow, launch at login, AirPods/headphone switching by ear, sleep/wake sensor re-wake.
- [ ] **Step 4:** Update the workstation MEMORY.md status with the PR link.
