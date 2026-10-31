# Downstroke

A macOS menu bar app that plays a real mechanical-switch recording on every key press, and shapes the sound by how hard you hit the key. It's built for a MacBook's built-in keyboard and aims to be fast enough that you never notice it's there.

It's a personal tool, not a product. It needs macOS 27 or later, and it's menu bar only (no Dock icon).

## Build and install

You need the Command Line Tools. Full Xcode isn't required.

```bash
scripts/bundle.sh          # release build, signed: build/Downstroke.app
scripts/bundle.sh --debug  # debug build, includes the --self-test suites
scripts/test.sh            # unit tests (use this, not bare `swift test`)
```

Copy `build/Downstroke.app` wherever you like and open it. Updates come from rebuilding; there's no update check.

macOS ties the Input Monitoring permission to the app's code signature. `scripts/bundle.sh` signs with a local certificate called `Downstroke Local Signing`; create it once as described in [docs/signing.md](docs/signing.md). If the certificate is missing, the script falls back to an ad-hoc signature with a warning, and macOS will ask for Input Monitoring again after every build.

**Input Monitoring.** Downstroke listens for key presses with a listen-only event tap, which needs this permission. It never prompts at launch. Open the menu bar panel and use the button there, which asks macOS for access and opens the Input Monitoring page in System Settings. If sounds don't start within a few seconds of allowing it, quit and reopen Downstroke (macOS often applies a new grant only on relaunch). It never asks for Accessibility or the microphone.

**Checking the sensor.** `build/Downstroke.app/Contents/MacOS/Downstroke --probe` (run from a terminal) wakes the accelerometer, reads it for a few seconds and checks that hard taps read at least twice as strong as soft ones. Use it to confirm hit strength will work on your Mac.

## Hit strength

How hard a key lands changes how it sounds. Downstroke reads the MacBook's built-in accelerometer at about 800 Hz (no root needed) and, for each key press, looks at a window from 15 ms before to 8 ms after the key event. The strongest impact in that window, with bumps above 0.3 g rejected, becomes a velocity from 0 to 1.

Each board has several real recordings of ordinary keys (5 to 26, depending on the pack) and usually one each for keys like space and return. At load, Downstroke derives four velocity layers (soft, medium, hard and slam) from every recording. Each press picks one recording and crossfades between that recording's two nearest layers, so strength changes the brightness and weight of the sound, not its pitch or timing. Every press also gets a small random pitch (±3%) and gain (±10%) variation so repeats don't sound robotic.

**The trade-off.** To measure a press, Downstroke has to wait for the key to bottom out, so the sound starts about 8 ms after the key event. That's the price of dynamics. If you'd rather have the fastest possible response, turn it off in **Settings › Sound**. The sound then starts as soon as the key event arrives.

**No sensor, no dynamics.** On a desktop Mac, an Intel Mac, or with an external keyboard (which doesn't shake the laptop's case), there's nothing to measure. Downstroke plays every press at a fixed medium strength and says so in Settings › Diagnostics. It never fakes dynamics.

## Speed

The audio side is a lock-free real-time mixer: a fixed pool of 48 voices, all samples decoded into memory at startup, and a 128-frame I/O buffer request. Key events reach the render thread through a lock-free queue, and the render thread never allocates, waits, logs or touches the disk. When all voices are busy, the oldest is stolen.

After 60 seconds with no key press, no audition and nothing still sounding, the audio engine pauses (the motion sensor keeps running, so hit strength still works). The next key restarts it without ever holding up the key listener. That one key still plays, late by the output device's restart time: about 35 ms on the built-in speakers (so about 37 ms from press to sound, against the usual 5 ms with hit strength off or 14 ms with it on), and longer on Bluetooth. Every key after it is back to normal. Settings › Diagnostics shows the engine as Running, Paused (idle) or Off.

`build/Downstroke.app/Contents/MacOS/Downstroke --bench` replays synthetic key events through the real engine and pipeline and checks these budgets:

- Latency from key event to the start of the render cycle that plays it, p99: at most 3 ms plus the buffer with hit strength off, and at most 8 + 3 ms plus the buffer with it on.
- Idle CPU: at most 1.0% of a core with hit strength off (engine running), and 1.5% with it on, measured with the engine paused after the idle timeout (macOS's HID path for the 800 Hz sensor costs about 1% by itself).
- First key after an idle pause, from key event to the start of the render cycle that plays it, p99: at most 50 ms.
- Typing CPU: at most 3%.
- Memory: at most 100 MB with all 20 boards loaded.
- Render overruns: zero.

The bench also prints output-time latency, which is what you actually hear (it includes the device's output delay). It uses a 1 s idle timeout instead of 60 s so the pause phases don't take minutes. Results from this Mac (MacBook Pro, Apple M5 Pro, macOS 27.2, built-in speakers, release build):

```text
banks: 20 loaded in 0.17 s, 32.4 MB of PCM
engine: 48000 Hz, I/O buffer 128 frames (2.67 ms), render lead 3.65 ms (output host time minus render start)
output device: safety offset 48 + latency 60 frames = 2.25 ms; lead minus buffer 0.99 ms
render-cycle start = output host time minus the smallest render lead seen (3.41 ms)
PASS latency p99, key event to render-cycle start, hit strength off 2.92 ms (budget 5.67 ms; p50 1.69 ms, max 2.92 ms, n=150)
PASS latency p99, key event to render-cycle start, hit strength on 11.80 ms (budget 13.67 ms; p50 10.38 ms, max 12.11 ms, n=150)
info key event to output time (what you hear, as the live readout), hit strength off: p99 6.33 ms, p50 5.10 ms, max 6.33 ms, n=150 (not checked)
info key event to output time (what you hear, as the live readout), hit strength on: p99 15.21 ms, p50 13.79 ms, max 15.53 ms, n=150 (not checked)
info stale triggers dropped: 0 (latency samples are key presses only, one per press)
PASS first key after an idle pause, key event to render-cycle start (hit strength off, idled with stop() + prepare()) 34.82 ms (budget 50.00 ms; p50 32.88 ms, max 34.82 ms, n=12)
info first key after an idle pause, key event to output time, stop() + prepare(): p99 38.23 ms, p50 36.29 ms, max 38.23 ms, n=12 (not checked)
info first key after an idle pause, engine start() call, stop() + prepare(): p99 33.38 ms, p50 31.53 ms, max 33.38 ms, n=12 (not checked)
info first key after an idle pause, key event to render-cycle start, pause() instead: p99 35.77 ms, p50 33.89 ms, max 35.77 ms, n=12 (not checked)
info first key after an idle pause, key event to output time, pause() instead: p99 39.18 ms, p50 37.30 ms, max 39.18 ms, n=12 (not checked)
info first key after an idle pause, engine start() call, pause() instead: p99 35.20 ms, p50 32.63 ms, max 35.20 ms, n=12 (not checked)
info idle pauses and wakes: 12 with stop() + prepare(), 12 with pause(); stale triggers dropped now 0
PASS idle CPU, engine running (hit strength off) 0.47% of a core (budget 1.0%)
info idle CPU, engine + synthetic 800 Hz sensor: 0.92% of a core (not checked)
PASS idle CPU, engine + real sensor (794 Hz), engine idle-paused (stop() + prepare()) after 1 s, hit-strength-on idle budget 0.98% of a core (budget 1.5%)
info idle CPU, engine running + real sensor: 1.41% of a core (not checked; before the idle pause)
info idle CPU, real sensor, engine idled with pause() instead: 0.96% of a core (not checked)
PASS typing CPU, hit strength off 0.63% of a core (budget 3.0%)
PASS typing CPU, hit strength on (synthetic sensor) 1.46% of a core (budget 3.0%)
PASS phys_footprint 55.8 MB with 20 of 20 banks loaded (budget 100 MB, all banks)
PASS render overruns 0 in 30906 renders (worst 0.021 ms, limit 1.333 ms)
PASS
```

Read it like this: with hit strength off the p99 latency is 2.92 ms to the start of the render cycle that plays the key, and about 6.3 ms to the output time (what you hear). With it on, the 8 ms measurement window brings that to 11.80 ms (15.2 ms at the output). Latency samples count each key press once; key releases aren't measured. Nothing overran in 30,906 renders.

Pausing the engine when idle is what brings hit strength on inside its budget. With the real sensor streaming, idle CPU is 1.41% while the engine runs and 0.98% once it has paused, which is about the sensor's own cost. The price is the first key after a pause: 34.82 ms p99 to the render cycle (38.2 ms at the output), almost all of it the output device restarting. A slower restart (Bluetooth, say) makes that key later but doesn't drop it: the key that wakes the engine, and any after it, are exempt from the mixer's 0.25 s stale-trigger guard. The engine idles with `stop()` and stays prepared; the bench also measures `pause()`, which costs the same idle CPU and resumes no faster.

The bench uses its own isolated preferences domain and plays audio briefly at the default volume (0.68).

## Features

- Menu bar panel: on/off, volume, a live hit-strength meter, and the key-to-sound latency readout.
- 20 boards grouped by texture (Thocky, Creamy, Clacky, Crisp, Thump). Hover a board or press its play button to audition it; click to switch, effective on the next key.
- Global hotkey, ⌃⌥⌘K by default, to toggle sound from any app.
- Mute in chosen apps, and mute while the microphone is in use.
- Key-up sounds (the switch's release).
- Stereo placement by key position, with a width slider.
- Launch at login, off by default (via `SMAppService`).
- Diagnostics in Settings: latency p50/p99, engine, sensor, output and permission status.
- Output follows the system default device. When it's Bluetooth, the panel says "Bluetooth adds delay" rather than showing a misleading figure.

Autorepeat presses don't play.

## Privacy

- The key listener is listen-only and reads three things: the key code, the autorepeat flag and the event timestamp. It never reads characters.
- Nothing about your typing is stored or logged. It's processed in memory and discarded.
- There's no network code at all: no analytics, no update checks, no downloads.
- The microphone is never opened. "Mute while the microphone is in use" uses Core Audio's per-process running-input flag, which only reports whether some app is recording.

## Credits and licences

The 20 boards are Switchcraft's switch packs, used under their open licences. The recordings come from:

- Cherry MX Red, Black, Brown and Blue (ABS and PBT): [Mechvibes](https://github.com/hainguyents13/mechvibes) by Hai Nguyen, MIT.
- Alpaca, Gateron Red Ink and Black Ink, NovelKeys Cream, Turquoise Tealios, Holy Panda, Topre, Kailh Box Navy, Alps SKCM Blue and Buckling Spring: [kbsim](https://github.com/tplai/kbsim) by Thomas Lai, MIT.
- Cherry MX Clear: "Mechanical keyboard clicking. Different keys" by humi74, [freesound.org/s/412926](https://freesound.org/s/412926/), CC0 1.0.
- Cherry MX Silent: "Typing Fast_A01" by bonesawmgraw, [freesound.org/s/572978](https://freesound.org/s/572978/), CC0 1.0.

Borrowed approaches:

- [Switchcraft](https://github.com/mustafa4101996ahmed/switchcraft) by Mustafa Ahmed (MIT): the sound packs, the pack format, the key listener and the accelerometer reader (`KeyTap.swift` and `MotionSensor.swift` are adapted from it).
- olvvier/apple-silicon-accelerometer (MIT): how to read the Apple silicon accelerometer.

Every licence notice is in [`LICENSES/`](LICENSES/) and is bundled into the app, and the same credits are in Settings › About. Downstroke was inspired by Meckey, Switchcraft and Kutuk; it contains no code or sounds from Meckey.

Downstroke itself is MIT licensed (see [LICENSE](LICENSE)). To refresh the vendored packs, run `scripts/vendor-packs.sh`.
