# Downstroke (Meckey REA): design

*30 Oct 2026. Agreed with Leonard in conversation. "My call" marks what Claude proposed and Leonard didn't pick himself. Prior-art research is in `prior-art-research-2026-10-30.md` next to this file. Approved by Leonard on 30 Oct 2026.*

## Intent

Leonard wants his own version of Meckey (meckey.vercel.app): a Mac menu bar app that plays a real mechanical-switch recording on every key press on his MacBook's built-in keyboard. It should borrow the best ideas from Switchcraft, Kutuk and other competitors, feel great, and be "super fast and responsive". The headline idea, taken from Switchcraft, is that how hard a key lands shapes the sound: soft presses sound soft, hard presses have weight.

It's a personal tool on Leonard's own Mac, not a product for sale.

## Goals

- A real switch sound on every key press and release, shaped by measured hit strength, with no audible lag and no dropped or cut-off sounds during fast typing, rolls or chords.
- A beautiful native menu bar panel (mockup A) that opens instantly.
- Speed you can measure: a live key-to-sound latency readout, plus a bench command.
- Near-zero cost when idle.

## Non-goals (first version)

- On-screen keystroke overlay, WPM graph, Mechvibes pack import (later, each its own piece of work).
- Any network use: no update checks, no analytics, no downloads. Updates come from rebuilding.
- Recording new switch sounds, pack editing, or a pack store.
- External keyboards beyond "it still plays" (see Hit strength), Intel Macs, Windows.
- Calibration wizards, room reverb or other Switchcraft extras not listed under Features.

## Anti-goals

- Audible lag or stutter. If typing feels behind the sound, it has failed, however correct it is.
- Anything on the audio render thread that can block: allocation, locks it waits on, file I/O, decoding, logging, Objective-C messaging.
- Reading or keeping what was typed. Key codes and timestamps only; nothing stored or logged.
- Copying code, sounds or branding from Meckey or any other closed app.

## Constraints

- Leonard's Mac: MacBook Pro, Apple M5 Pro (Mac17,9), macOS 27.2. Switchcraft has verified accelerometer access on a MacBook Air M5 (Mac17,3); it's unverified on Mac17,9 until we probe it.
- Toolchain: Swift 6.4.2 with the Command Line Tools only, no full Xcode. Build with SwiftPM. Lessons from Tracer on the same Mac: Swift Testing works and XCTest doesn't; run tests through a `scripts/test.sh` wrapper, not bare `swift test`; don't use SwiftUI/Observation macros (`@State`, `@Observable`) in app code, use `ObservableObject`/`@StateObject`; bundle in a separate build directory.
- Input Monitoring permission is tied to the code signature, so rebuilds need a stable local signing identity (none exists yet; Leonard creates one, as for Tracer).
- Security software can treat a keyboard listener that starts at login with suspicion; launch at login uses `SMAppService` (not a hand-written LaunchAgent) and is off by default.
- The terminal has no Input Monitoring permission, so real key presses and real sensor readings during typing need Leonard to check by hand.
- Licences: Switchcraft code and the Mechvibes and kbsim recordings are MIT, the freesound recordings CC0. Keep every licence notice and credit them in the README and About box.
- Code comments are one short line or none. Public commits use leonardcooray@gmail.com. Feature branches and PRs; Leonard merges.

## Approaches considered

1. **Our own app, borrowing Switchcraft's proven pieces (chosen by Leonard).** Fresh Swift app built with SwiftPM, our own audio engine, key listener and UI, reusing Switchcraft's MIT accelerometer reader and its 20 openly licensed switch packs with credit. Codebase sized to our features, speed designed in, builds with the tools Leonard has.
2. **Fork Switchcraft and reshape it.** Faster to a first working build, but needs full Xcode, brings its whole architecture and extras, and panel A means rewriting its views anyway. Ruled out.
3. A raw Core Audio engine instead of AVAudioEngine was dropped: it saves about a millisecond against an 8 ms window Leonard has already accepted, for a lot more code.

## Decisions

- **Keyboard:** mainly the MacBook's built-in keyboard (Leonard).
- **Hit strength on by default, feel over speed (Leonard):** we wait for the key to bottom out and measure it, accepting about 8 ms before the sound starts. A setting turns it off for the fastest response.
- **Panel UI: mockup A, "Native Control Center" (Leonard).** Mockups are in `.superpowers/brainstorm/` in this workstation (`panel-directions.html`). A frosted-glass panel under the menu bar icon, top to bottom: app name with status line ("Listening · Holy Panda") and an on/off switch; a Volume slider showing the percentage; a live Hit strength meter; boards in a list grouped under texture headings with a tick on the current one; a footer with "Key → sound 9 ms" and "Settings… ⌘,". It should look like it shipped with macOS.
- **Build approach 1** (Leonard), above.
- **Features in v1 (my call, Leonard didn't object):**
  - Board picker grouped by texture (Thocky, Creamy, Clacky, Crisp, Thump); hovering a board for a moment, or clicking a small play button on it, auditions it without switching. Clicking switches, effective on the very next key.
  - Live hit-strength meter in the panel.
  - On/off and volume; global hotkey ⌃⌥⌘K toggles sound from any app.
  - Key-up sounds (on by default, toggle in Settings).
  - Stereo placement by key position (on by default, width slider in Settings).
  - Mute in chosen apps (list in Settings, added from running apps).
  - Mute while the microphone is in use (on by default), via CoreAudio's public "is running somewhere" flag, never opening the mic.
  - Launch at login (off by default).
  - Key-to-sound latency readout in the panel footer, plus a Diagnostics section in Settings.
  - Output device: follow the system default (my call; no picker in v1).
- **Sounds (my call):** bundle Switchcraft's 20 switches: Cherry MX Red, Black, Brown, Blue in ABS and PBT, MX Clear, MX Silent, Alpaca, NovelKeys Cream, Turquoise Tealios, Gateron Red Ink, Black Ink, Holy Panda, Topre, Kailh Box Navy, Alps SKCM Blue, Buckling Spring. Texture group per board is my call, set by ear and switch type, and stored in the pack manifest so it's easy to change.
- **Listening setup (Leonard):** mostly the MacBook's built-in speakers, so the latency budgets target built-in output. Bluetooth handling (my call): when output is a Bluetooth device, the panel footer says "Bluetooth adds delay" instead of a misleading latency figure; no muting. The bench and live readout measure up to the app's own output, not through the device.
- **Name (Leonard):** the app is called **Downstroke**. Public GitHub repo `LeonardCooray/downstroke` (my call, as for Tracer), cloned at `/Users/leonard/src/downstroke`, bundle ID `com.leonardcooray.downstroke`, local signing identity `Downstroke Local Signing`.

## How it works

**Key listener.** A listen-only `CGEvent` tap (Input Monitoring, not Accessibility) for key down, key up and modifier changes, on its own thread and run loop at high priority. It reads only the key code, the autorepeat flag and the event timestamp. It re-enables itself if macOS disables the tap. Autorepeat presses don't play (my call). If Input Monitoring is missing, the panel says so and offers a button that opens the right System Settings page; it never prompts at launch.

**Hit strength.** Read the built-in accelerometer at about 800 Hz using Switchcraft's MIT approach, into a lock-free ring buffer. For each key press, look at a window from 15 ms before to 8 ms after the key event, take the strongest filtered impact and map it to a velocity from 0 to 1. Then trigger the sound. If the sensor can't be read (unsupported Mac, external keyboard not shaking the case, sensor error), play immediately at a fixed medium strength and say so in Diagnostics; never fake dynamics. Mapping thresholds start from Switchcraft's defaults; an in-app calibration flow is not in v1 (a sensitivity slider is, my call).

**Sensor probe first (my call).** Waking the sensor means writing reporting properties to the `AppleSPUHIDDriver` service, as Switchcraft's `docs/SENSOR.md` describes. The plan's first task is a throwaway probe on Leonard's Mac17,9, wake the sensor, log readings while Leonard types soft and hard, and confirm the key listener runs. "Working" means the median peak from deliberately hard presses is at least twice the median from soft presses. If the sensor is unreadable or below that bar, hit strength ships off by default and the app plays at fixed strength with key variation; calibration stays out of v1 either way.

**Sound shaping.** Each pack holds real single hits per key group (letter rows, Space, Enter, Backspace, modifiers) plus key-ups. At load, derive four layers per hit (soft, medium, hard = the recording, slam) as Switchcraft does, and blend the two nearest layers for a given velocity, so strength changes brightness and weight, never pitch or timing. Small random pitch (±3%) and gain variation per press so repeats don't sound robotic (my call).

**Audio engine.** `AVAudioEngine` with one `AVAudioSourceNode` whose render block mixes a fixed pool of preallocated voices (at least 48) from PCM decoded into memory at startup, at the device sample rate. Triggers reach the render thread through a lock-free single-producer queue; the render thread never waits. Ask for a small I/O buffer (128 frames or less). A peak limiter keeps overlapping voices from clipping. When all voices are busy, steal the oldest. Rebuild cleanly on output device changes (headphones in or out) without a pause the user notices. While sound is off or nothing has played for a few seconds, the engine pauses so idle cost is near zero, and resumes fast enough that the first key isn't late (the builder decides how, and measures it).

**Settings.** Persisted in `UserDefaults`. Changes from the UI reach the engine without a restart.

**UI.** An `NSStatusItem` menu bar icon opening a prebuilt panel (built at launch and reused, so opening is instant), hosting native controls styled as mockup A. A Settings window (⌘,) with sections: Sound (key-ups, stereo width, sensitivity, hit strength on/off), Apps (mute list, mic muting), General (hotkey, launch at login), Diagnostics (latency stats, sensor status, permission status). No Dock icon.

## Performance budgets

Measured, not assumed. The builder adds a `bench` mode (command-line flag) that replays synthetic key events through the real pipeline and reports these numbers:

- Key event received → first sample of that sound rendered, p99: ≤ 3 ms plus the I/O buffer with hit strength off; the 8 ms window plus the same with it on.
- Idle CPU (sound on, not typing): ≤ 1% of one core. Typing at 120 WPM: ≤ 3%.
- Memory: ≤ 100 MB resident with all 20 packs loaded (or load packs on demand if that's over budget).
- Panel opens within one frame of the click; switching boards takes effect on the next key.
- Zero render-thread overruns or glitches during a 10-second 15-keys-per-second burst.

The panel footer shows the live p50 latency from real key presses; Diagnostics shows p50/p99.

## Privacy

No network code at all. Only key codes and timestamps are read, processed in memory and discarded. The microphone is never opened. Password fields are already hidden from listeners by macOS.

## Left to the builder

- Module and file layout, test strategy (deterministic synthetic sensor and key fixtures, as Switchcraft does), and how much Switchcraft code is adapted versus rewritten.
- Exact filter, detector and velocity-curve maths, layer derivation, and voice-stealing details, within the budgets above.
- Panel sizes, spacing, the menu bar glyph and the app icon, within the mockup A look.
- How the engine idles and wakes without making the first key late.
- Signing scripts and setup steps for Leonard's local signing identity, following Tracer's.
