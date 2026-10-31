# Slam accent: design

Date: 31 Oct 2026. Replaces v1's continuous hit strength.

## Why

A raw-sensor recording on the M5 Pro MacBook Pro showed that the accelerometer can't tell ordinary soft typing from ordinary hard typing, but it reliably picks out a deliberate slam. v1 maps every press onto a soft-to-slam scale it can't measure, so it ships switched off. This change makes the feature do what the sensor can actually do: normal typing sounds steady, and a real slam sounds heavy.

## Goals

- A press hit much harder than normal plays the heavy slam sound; everything else plays the normal sound.
- A threshold Leonard can tune by feel.

## Non-goals

- Any gradation between soft and hard below slam level.
- Cutting the ~8 ms wait (that was the "late thump" approach, not chosen).
- Auto-calibration.

## Anti-goals

- Fake dynamics: an ordinary press must never land on a random layer.
- Normal presses sounding different with the accent on than with it off.

## Approaches

1. **Slam accent (chosen by Leonard).** Wait the existing window, play normal presses at today's fixed strength, and switch presses over a threshold to the slam layer. Smallest change, and it's honest about what the sensor sees.
2. **Late thump.** Play every key at once, then add a heavy layer about 8 ms later when a slam is detected. No wait, but it risks sounding like a double click. Not chosen.
3. **Recalibrate the full scale at 5 Hz.** Ruled out: below slam level the differences are noise, so presses would land on random layers.

## Behaviour

- **Filter:** the impact filter's high-pass moves from 25 Hz to 5 Hz. Capture 1's slams read about 3× the soft median at 5 Hz, against about 1.9× at 25 Hz.
- **Window:** unchanged, from 15 ms before to 8 ms after the key event, with the same 12 ms give-up.
- **Below the threshold:** the press plays at today's fixed velocity (0.5), identical to the accent being off.
- **At or above the threshold (my call):** velocity ramps from 0.5 at the threshold up to full slam (0.875) at 1.5× the threshold, so a borderline press gets a partly heavier sound rather than a hard flip.
- **Bumps:** peaks over 0.3 g (knocking or lifting the Mac) still play at fixed strength, as today.
- **Threshold:** the existing Sensitivity slider (saved value kept) maps on a log scale from 30 mg (Low) to 8 mg (High). The default 0.5 lands on about 16 mg, where capture 1 caught 81% of slams and flagged 3% of other presses.
- **Default (my call, flag for Leonard):** on, matching his "feel over speed" decision. Its cost is the ~8 ms wait on every key and about 0.5% of a core for the sensor. The setting is stored under the same key, so anyone who turned it off keeps it off.

## UI (my calls)

- **Settings › Sound:**
  - Section "Slam accent".
  - Toggle "Accent hard hits", subtitle "Hit a key much harder than usual and it sounds heavier."
  - Slider "Slam threshold", running from "Hard to trigger" to "Easy to trigger".
- **Panel meter:** shows the last press's measured impact against a tick at the threshold, and lights up when a press counted as a slam, so the slider can be tuned by eye. Today it shows a velocity that would sit at 0.5 almost all the time.
- **Diagnostics:** adds a slam count since launch.

## Left to the builder

- How the threshold and ramp live in Core (replace or reshape `VelocityMapper`), keeping it pure and unit-tested.
- Updating the probe, self-tests and bench to the new filter and mapping. Bench budgets stay as they are.
- README wording for the feature.

## Verification

- Unit tests for the mapping: below threshold gives exactly 0.5, the ramp, the bump cut-off, and the slider end points.
- Re-run capture 1 offline through the app's own Core filter and mapping. Expect roughly 80% of set 7 above threshold and under 5% of the other sets.
- Leonard by ear: normal typing sounds unchanged, deliberate slams sound heavy, and the meter and threshold make sense.
