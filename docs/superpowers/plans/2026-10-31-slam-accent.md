# Slam Accent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace continuous hit strength with a slam accent: normal presses play at fixed strength, presses over a tunable threshold play the slam layer.

**Architecture:** A pure `SlamMapper` in Core replaces `VelocityMapper`. The impact filter drops to 5 Hz. `TypingPipeline` publishes each press's meter level (impact relative to the threshold) and a slam count. The panel meter and Settings UI follow.

**Tech Stack:** Swift 6.4 / SwiftPM, Swift Testing, SwiftUI hosted in AppKit (no `@State`/`@Observable` in app code).

**Spec:** `docs/superpowers/specs/2026-10-31-slam-accent-design.md`

## Global Constraints

- Below the threshold, velocity is exactly 0.5, the same as with the accent off.
- Ramp: 0.5 at the threshold, rising linearly to 0.875 at 1.5× the threshold, capped at 0.875.
- Peaks over 0.3 g are bumps and play at 0.5.
- Threshold = 0.030 g × (0.008/0.030)^sensitivity (log scale; sensitivity 0 → 30 mg, 1 → 8 mg, 0.5 → ~15.5 mg).
- `ImpactFilter` default cutoff 5 Hz; window −15/+8 ms and the 12 ms give-up unchanged.
- `hitStrengthEnabled` defaults to true; storage key unchanged.
- Code comments: one short line or none. Run tests with `scripts/test.sh`, never bare `swift test`.

## Review Focus

- A peak exactly at the threshold → treated as a slam start (velocity 0.5, counted as a slam only when velocity > 0.5).
- No peak found (sensor gap, give-up) → velocity 0.5, meter level 0, not counted as a slam.
- A bump (> 0.3 g) → velocity 0.5, not counted, meter level 0.
- The sensor turning unavailable mid-typing → the meter shows "Fixed strength" and no slams are counted.
- Old saved settings without the key → accent on; saved `false` stays false.

---

### Task 1: Core: SlamMapper, 5 Hz filter, pipeline level and slam count

**Files:**
- Create: `Sources/DownstrokeCore/SlamMapper.swift`; Delete: `Sources/DownstrokeCore/VelocityMapper.swift`
- Modify: `Sources/DownstrokeCore/Sensor.swift` (ImpactFilter default cutoff 5), `Sources/DownstrokeCore/Settings.swift` (`hitStrengthEnabled = true`), `Sources/DownstrokeCore/TypingPipeline.swift`
- Test: `Tests/DownstrokeCoreTests/SlamMapperTests.swift` (replaces `VelocityMapperTests.swift`), `TypingPipelineTests.swift`, `SettingsTests.swift`, `SensorTests.swift`, new `CaptureReplayTests.swift`

**Interfaces (produces):**
- `public struct SlamMapper: Sendable` with `static let normalVelocity: Float = 0.5`, `static let slamVelocity: Float = 0.875`, `static let bumpThreshold: Float = 0.3`, `let threshold: Float`, `init(sensitivity: Float)`, `func velocity(forPeak g: Float) -> Float` (bumps return 0.5), `func meterLevel(forPeak g: Float) -> Float` = min(g / (2 × threshold), 1), 0 for bumps.
- `TypingPipeline.lastPress: (count: UInt32, level: Float)` (level replaces velocity), `TypingPipeline.slamCount: Int` (presses played above 0.5).

- [ ] **Step 1:** Write `SlamMapperTests`: threshold(0.5) ≈ 0.01549; threshold(0) == 0.030, threshold(1) == 0.008; velocity at 0.5×, 0.99× threshold == 0.5; at 1.25× ≈ 0.6875; at 1.5× and 3× == 0.875; at 0.31 g == 0.5; meterLevel at threshold == 0.5, at 4× == 1, at 0.31 g == 0. Sensor test: a 5 Hz default filter passes a 10 Hz sine near unity gain after settling.
- [ ] **Step 2:** Pipeline tests: with threshold 0.0155 (sensitivity 0.5), a press with ring peak 0.010 plays `[.press(.medium), .press(.hard)]` and `lastPress.level ≈ 0.32`, `slamCount == 0`; a 0.05 peak plays `[.press(.slam)]`, `slamCount == 1`; a 0.5 g bump plays medium+hard, `slamCount == 0`, level 0; the fixed-strength paths leave level 0. Update existing tests that assumed the old mapping (e.g. `waitsForWindowWhenSensing` expects slam for 0.06; keep). Settings test: default `hitStrengthEnabled == true`, decoding `{}` gives true, decoding `{"hitStrengthEnabled":false}` gives false.
- [ ] **Step 3:** Run `scripts/test.sh`; expect the new tests to fail to compile.
- [ ] **Step 4:** Implement `SlamMapper`, delete `VelocityMapper`, switch the pipeline (`resolve` uses `SlamMapper(sensitivity:)`; `emit` takes the level and bumps `slamCount` when velocity > 0.5), set the defaults.
- [ ] **Step 5:** `CaptureReplayTests`, enabled only when `DOWNSTROKE_CAPTURE` names a capture CSV: feed raw `s` rows through `ImpactFilter()` into a `SampleRing(capacity: 1 << 18)`, then for each `d` row take `ImpactAnalyzer.peak` and `SlamMapper(sensitivity: 0.5)`; print the slam fraction for the last `hard` block and for every other block; expect the last block ≥ 0.6 and the others ≤ 0.1.
- [ ] **Step 6:** Run `scripts/test.sh` (all pass), then `DOWNSTROKE_CAPTURE=build/capture-1.csv scripts/test.sh` and record the printed fractions.
- [ ] **Step 7:** Commit `feat: slam accent mapping in Core, 5 Hz impact filter`.

### Task 2: App: meter, Settings, Diagnostics, probe and README

**Files:**
- Modify: `Sources/Downstroke/AppModel.swift` (MeterModel steps on `level`), `Sources/Downstroke/PanelView.swift` (section "Slam accent"; segments at or past the middle lit orange, below it secondary; a tick at the middle; a11y label "Last hit against slam threshold"), `Sources/Downstroke/SettingsView.swift`, `Sources/Downstroke/SettingsWindowController.swift`, `Sources/Downstroke/ProbeMode.swift`, `Sources/Downstroke/DebugSelfTest.swift`, `Sources/Downstroke/BenchMode.swift` (only if it no longer compiles), `README.md`

**Interfaces (consumes):** `TypingPipeline.lastPress.level`, `TypingPipeline.slamCount`, `SlamMapper.threshold`.

- [ ] **Step 1:** Settings › Sound copy, exact: section header "Slam accent"; toggle "Accent hard hits" with subtitle "Hit a key much harder than usual and it sounds heavier."; slider label "Slam threshold", min label "Hard to trigger", max label "Easy to trigger". Sensor-off text becomes "Off: slam accent is off".
- [ ] **Step 2:** Diagnostics: a row "Slams since launch" showing `pipeline.slamCount`, refreshed with the other rows.
- [ ] **Step 3:** Probe: keep its flow, but report the slam threshold and how many HARD presses cross it instead of the 2× ratio; PASS when ≥ 60% of HARD and ≤ 10% of SOFT cross.
- [ ] **Step 4:** Update the self-tests to the new copy and meter (panel + settings suites), and README's hit-strength section to describe the slam accent.
- [ ] **Step 5:** Verify: `scripts/test.sh`, `scripts/bundle.sh --debug`, then `--self-test panel`, `--self-test settings`, `--self-test sensor-restart`, `--self-test audio`; then `scripts/bundle.sh` and a release `--bench` from a foreground terminal. Look at the panel and Settings captures in light and dark.
- [ ] **Step 6:** Commit `feat: slam accent meter, settings and diagnostics`.
