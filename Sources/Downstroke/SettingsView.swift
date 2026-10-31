import AppKit
import Carbon.HIToolbox
import DownstrokeCore
import ServiceManagement
import SwiftUI

/// A grouped form at the window's fixed width: sized to its content, or scrolling at `height`.
private struct SettingsPage<Content: View>: View {
    var height: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if let height {
            Form { content }
                .formStyle(.grouped)
                .frame(width: SettingsWindowController.width, height: height)
        } else {
            Form { content }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(width: SettingsWindowController.width)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension AppController {
    func binding<T>(_ key: WritableKeyPath<DownstrokeSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: key] }, set: { value in self.update { $0[keyPath: key] = value } })
    }

    func sliderBinding(_ key: WritableKeyPath<DownstrokeSettings, Float>) -> Binding<Double> {
        Binding(get: { Double(self.settings[keyPath: key]) }, set: { value in self.update { $0[keyPath: key] = Float(value) } })
    }
}

// MARK: General

struct GeneralSettings: View {
    @ObservedObject var controller: AppController
    let recorder: HotkeyRecorderState

    var body: some View {
        SettingsPage {
            Section {
                LabeledContent {
                    HotkeyRecorder(hotkey: controller.settings.hotkey, state: recorder) {
                        controller.update { $0.hotkey = .defaultToggle }
                    }
                } label: {
                    Text("Turn Downstroke on or off")
                    Text("Works from any app.")
                }
                if let error = controller.hotkeyError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("hotkeyError")
                }
            } header: {
                Text("Keyboard shortcut")
            }
            Section {
                Toggle(isOn: Binding(get: { controller.launchesAtLogin }, set: controller.setLaunchAtLogin)) {
                    Text("Launch at login")
                    Text("Start Downstroke in the menu bar when you log in.")
                }
                if controller.loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Label("Approve Downstroke in Login Items to finish.", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if let error = controller.loginError {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("loginError")
                }
            }
            Section {
                LabeledContent {
                    Button("Quit") { NSApp.terminate(nil) }
                } label: {
                    Text("Quit Downstroke")
                    Text("Stops all key sounds until you open it again.")
                }
            }
        }
    }
}

/// Records a global shortcut from the key code and modifier flags only; never characters.
/// An ObservableObject rather than @State: the Command Line Tools build can't load the SwiftUI macro plugin.
@MainActor
final class HotkeyRecorderState: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var problem: String?
    private var monitor: Any?
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    var isMonitoring: Bool { monitor != nil }

    func start() {
        guard !recording else { return }
        recording = true
        problem = nil
        controller.setHotkeySuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(keyCode: event.keyCode, flags: event.modifierFlags)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        problem = nil
        guard recording else { return }
        recording = false
        controller.setHotkeySuspended(false)
    }

    func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let modifiers = Self.carbonModifiers(flags)
        if keyCode == UInt16(kVK_Escape) && modifiers == 0 { return stop() }
        let candidate = Hotkey(keyCode: UInt32(keyCode), modifiers: modifiers)
        if let problem = candidate.problem {
            self.problem = "\(candidate.displayString): \(problem)"
        } else {
            controller.update { $0.hotkey = candidate }
            stop()
        }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= Hotkey.command }
        if flags.contains(.shift) { m |= Hotkey.shift }
        if flags.contains(.option) { m |= Hotkey.option }
        if flags.contains(.control) { m |= Hotkey.control }
        return m
    }
}

struct HotkeyRecorder: View {
    let hotkey: Hotkey
    @ObservedObject var state: HotkeyRecorderState
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if hotkey != Hotkey.defaultToggle && !state.recording {
                    Button(action: onReset) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Restore \(Hotkey.defaultToggle.displayString)")
                    .accessibilityLabel("Restore default shortcut")
                }
                if state.recording {
                    Button(action: state.stop) { label("Type shortcut…") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(action: state.start) { label(hotkey.displayString) }
                        .buttonStyle(.bordered)
                }
            }
            if let problem = state.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            } else if state.recording {
                Text("Esc to cancel").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("hotkeyRecorder")
    }

    private func label(_ text: String) -> some View {
        Text(text).frame(minWidth: 104)
    }
}

// MARK: Sound

struct SoundSettings: View {
    @ObservedObject var controller: AppController

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: controller.binding(\.hitStrengthEnabled)) {
                    Text("Accent hard hits")
                    Text("Hit a key much harder than usual and it sounds heavier.")
                }
                Slider(value: controller.sliderBinding(\.sensitivity), in: 0...1) {
                    Text("Slam threshold")
                } minimumValueLabel: {
                    Text("Hard to trigger")
                } maximumValueLabel: {
                    Text("Easy to trigger")
                }
                .disabled(!controller.settings.hitStrengthEnabled)
                if case .unavailable = controller.sensorStatus, controller.settings.hitStrengthEnabled {
                    Label("Motion sensor unavailable, so there's no slam accent.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Slam accent")
            }
            Section {
                Toggle(isOn: controller.binding(\.keyUpSounds)) {
                    Text("Key-up sounds")
                    Text("Play each switch's release as well as its press.")
                }
                Slider(value: controller.sliderBinding(\.stereoWidth), in: 0...1) {
                    Text("Stereo width")
                    Text("Spreads keys from left to right as they sit on the keyboard.")
                } minimumValueLabel: {
                    Text("Mono")
                } maximumValueLabel: {
                    Text("Wide")
                }
            } header: {
                Text("Playback")
            }
        }
    }
}

// MARK: Apps

struct AppsSettings: View {
    @ObservedObject var controller: AppController
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage {
            Section {
                let muted = controller.settings.mutedBundleIDs
                if muted.isEmpty {
                    Text("No muted apps")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                ForEach(muted, id: \.self) { id in
                    MutedAppRow(info: AppInfo.lookup(id), selected: model.selectedMuted == id)
                        .onTapGesture { model.selectedMuted = model.selectedMuted == id ? nil : id }
                }
                HStack(spacing: 2) {
                    addMenu
                    Button(action: model.unmuteSelected) {
                        Image(systemName: "minus").frame(width: 22, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.selectedMuted == nil)
                    .help("Unmute the selected app")
                    .accessibilityLabel("Unmute selected app")
                    Spacer()
                }
            } header: {
                Text("Muted apps")
            } footer: {
                Text("Downstroke stays quiet while one of these apps is in front.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: controller.binding(\.muteWhileMicInUse)) {
                    Text("Mute while the microphone is in use")
                    Text("Keeps calls, recordings and dictation free of key sounds.")
                }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            let apps = model.mutableApps
            if apps.isEmpty { Text("No other apps running") }
            ForEach(apps) { app in
                Button { model.mute(app.id) } label: {
                    Label { Text(app.name) } icon: { Image(nsImage: Self.menuIcon(app.icon)) }
                }
            }
        } label: {
            Image(systemName: "plus").frame(width: 22, height: 18).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mute a running app")
        .accessibilityLabel("Mute a running app")
    }

    private static func menuIcon(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

private struct MutedAppRow: View {
    let info: AppInfo
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 24, height: 24)
            Text(info.name)
            Spacer(minLength: 8)
            if info.name != info.id {
                Text(info.id)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.2))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Diagnostics

struct DiagnosticsSettings: View {
    @ObservedObject var model: DiagnosticsModel
    let controller: AppController

    var body: some View {
        let s = model.snapshot
        SettingsPage {
            Section("Input") {
                row("Input Monitoring", s.permission ? "Granted" : "Not granted", health: s.permission ? .good : .bad)
                row("Key tap", s.tap)
                row("Motion sensor", s.sensor, health: s.sensorHealth)
                row("Slams since launch", "\(s.slams)")
            }
            Section("Audio output") {
                row("Engine", s.engine, health: s.engineHealth)
                row("Device", s.device)
                row("Bluetooth", s.bluetooth ? "Yes, adds delay" : "No", health: s.bluetooth ? .warning : nil)
                row("Sample rate", s.sampleRateText)
                row("I/O buffer", s.ioText)
                row("Active voices", "\(s.voices) of \(DiagnosticsSnapshot.maxVoices)")
            }
            Section("Key to sound latency") {
                row("Median (p50)", DiagnosticsSnapshot.ms(s.p50))
                row("p99", DiagnosticsSnapshot.ms(s.p99))
                row("Presses measured", "\(s.count)")
            }
            if !s.problems.isEmpty {
                Section("Problems") {
                    ForEach(s.problems, id: \.self) { problem in
                        Text(problem).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.snapshot.report, forType: .string)
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, health: DiagnosticsSnapshot.Health? = nil) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                if let health { StatusDot(health: health) }
                Text(value)
                    .monospacedDigit()
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct StatusDot: View {
    let health: DiagnosticsSnapshot.Health

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch health {
        case .good: .green
        case .warning: .orange
        case .bad: .red
        case .idle: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

// MARK: About

struct AboutSettings: View {
    @ObservedObject var controller: AppController
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsPage(height: 560) {
            Section {
                VStack(spacing: 6) {
                    AppTile()
                        .padding(.bottom, 4)
                    Text("Downstroke")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Version \(AboutInfo.version)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Mechanical keyboard sounds, shaped by how hard you type.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text("© 2026 Leonard Cooray · MIT License")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("Sound packs") {
                ForEach(Self.packCredits(controller.boards), id: \.credit) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.boards)
                        Text(group.credit)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }
            Section("Open source") {
                ForEach(LicenceNotice.all) { notice in
                    LabeledContent {
                        Button("Licence") { model.licence = notice }
                            .disabled(notice.text == nil)
                    } label: {
                        Text(notice.name)
                        Text(notice.detail)
                    }
                }
            }
        }
        .sheet(item: $model.licence) { notice in
            LicenceSheet(notice: notice) { model.licence = nil }
        }
    }

    /// Boards grouped by their credit line, largest group first.
    static func packCredits(_ boards: [Board]) -> [(credit: String, boards: String)] {
        let groups = Dictionary(grouping: boards.filter { !$0.credits.isEmpty }, by: \.credits)
        return groups
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { credit, boards in
                (credit, boards.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", "))
            }
    }
}

private struct AppTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.24), Color(red: 0.93, green: 0.36, blue: 0.13)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 64, height: 64)
            .overlay {
                Image(systemName: "keyboard")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}

private struct LicenceSheet: View {
    let notice: LicenceNotice
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.name).font(.headline)
                Text(notice.detail).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(notice.text ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(width: 440, height: 300)
            .background(.background.secondary, in: .rect(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
