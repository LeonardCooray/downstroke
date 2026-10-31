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

`build/Downstroke.app/Contents/MacOS/Downstroke --bench` replays synthetic key events through the real engine and pipeline and checks these budgets:

- Latency from key event to the start of the render cycle that plays it, p99: at most 3 ms plus the buffer with hit strength off, and at most 8 + 3 ms plus the buffer with it on.
- Idle CPU: at most 1.0% of a core with hit strength off, and 1.5% with it on (macOS's HID path for the 800 Hz sensor costs about 1% by itself).
- Typing CPU: at most 3%.
- Memory: at most 100 MB with all 20 boards loaded.
- Render overruns: zero.

The bench also prints output-time latency, which is what you actually hear (it includes the device's output delay). Results from this Mac (MacBook Pro, Apple M5 Pro, macOS 27.2, built-in speakers, release build):

```text
banks: 20 loaded in 0.16 s, 32.4 MB of PCM
engine: 48000 Hz, I/O buffer 128 frames (2.67 ms), render lead 3.66 ms (output host time minus render start)
output device: safety offset 48 + latency 60 frames = 2.25 ms; lead minus buffer 0.99 ms
render-cycle start = output host time minus the smallest render lead seen (3.55 ms)
PASS latency p99, key event to render-cycle start, hit strength off 2.79 ms (budget 5.67 ms; p50 1.36 ms, max 2.80 ms, n=450)
PASS latency p99, key event to render-cycle start, hit strength on 11.55 ms (budget 13.67 ms; p50 2.79 ms, max 11.98 ms, n=300)
info key event to output time (what you hear, as the live readout), hit strength off: p99 6.34 ms, p50 4.91 ms, max 6.35 ms, n=450 (not checked)
info key event to output time (what you hear, as the live readout), hit strength on: p99 15.10 ms, p50 6.34 ms, max 15.53 ms, n=300 (not checked)
PASS idle CPU, engine running (hit strength off) 0.41% of a core (budget 1.0%)
info idle CPU, engine + synthetic 800 Hz sensor: 0.83% of a core (not checked)
FAIL idle CPU, engine + real sensor (794 Hz), hit-strength-on idle budget 1.59% of a core (budget 1.5%)
info idle CPU, real sensor only, engine stopped: 1.11% of a core (not checked)
PASS typing CPU, hit strength off 0.57% of a core (budget 3.0%)
PASS typing CPU, hit strength on (synthetic sensor) 1.52% of a core (budget 3.0%)
PASS phys_footprint 55.6 MB with 20 of 20 banks loaded (budget 100 MB, all banks)
PASS render overruns 0 in 19682 renders (worst 0.015 ms, limit 1.333 ms)
FAIL
```

Read it like this: with hit strength off the p99 latency is 2.79 ms to the start of the render cycle that plays the key, and about 6.3 ms to the output time (what you hear). With it on, the 8 ms measurement window brings that to 11.55 ms (15.1 ms at the output), and key releases, which need no measurement, stay at 2.78 ms. Nothing overran in 19,682 renders.

One budget is missed on this Mac. Idle CPU with the real sensor streaming and the engine running measured 1.59% and 1.60% across two runs, against the 1.5% budget. The sensor on its own costs 1.1% (macOS's HID path), and the engine adds roughly 0.4% on top. Everything else passes.

The bench uses its own isolated preferences domain and plays audio briefly at the default volume (0.68).

## Features

- Menu bar panel: on/off, volume, a live hit-strength meter, and the key-to-sound latency readout.
- 20 boards grouped by texture (Thocky, Creamy, Clacky, Crisp, Thump). Hover a board or press its play button to audition it; click to switch, effective on the next key.
- Global hotkey, ⌃⌥⌘K by default, to toggle sound from any app.
- Mute in chosen apps, and mute while the microphone is in use.
- Key-up sounds (the switch's release).
- Stereo placement by key position, with a width slider.
- Launch at login, off by default (via `SMAppService`).
- Diagnostics in Settings: latency p50/p99, sensor, output and permission status.
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
