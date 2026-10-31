import AppKit
import DownstrokeCore
import SwiftUI

/// The live panel: `PanelContent` fed from the controller.
struct PanelView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var model: PanelModel

    var body: some View {
        PanelContent(state: PanelState(controller), model: model)
    }
}

struct PanelContent: View {
    static let width: CGFloat = 310
    static let listHeight: CGFloat = 344

    let state: PanelState
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if state.permissionMissing {
                PermissionBanner(request: model.requestPermission)
                    .padding(.top, 12)
            }
            SectionLabel("Volume").padding(.top, 14)
            volume
            SectionLabel("Hit strength").padding(.top, 12)
            Group {
                if state.fixedStrength {
                    Text("Fixed strength")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    HitMeter(meter: model.meter)
                }
            }
            .frame(height: HitMeter.height)
            .padding(.top, 2)
            boards.padding(.top, 14)
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .environment(\.controlActiveState, .key)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Downstroke")
                    .font(.system(size: 14, weight: .semibold))
                Text(state.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("status")
            }
            Spacer(minLength: 0)
            Toggle("Downstroke", isOn: Binding(get: { state.enabled }, set: model.setEnabled))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .focusable(false)
                .accessibilityIdentifier("enabled")
        }
    }

    private var volume: some View {
        let value = model.dragVolume ?? state.volume
        return HStack(spacing: 10) {
            Slider(
                value: Binding(get: { Double(value) }, set: { model.dragVolume(Float($0)) }),
                in: 0...1,
                onEditingChanged: { editing in if !editing { model.commitVolume() } }
            )
            .controlSize(.regular)
            .focusable(false)
            .accessibilityLabel("Volume")
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.top, 2)
    }

    private var boards: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(state.sections.enumerated()), id: \.element.id) { index, section in
                        SectionLabel(section.texture.title)
                            .padding(.top, index == 0 ? 0 : 9)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("texture.\(section.texture.rawValue)")
                        ForEach(section.rows) { row in
                            BoardRow(
                                row: row,
                                current: row.id == state.currentBoardID,
                                hovered: model.hoveredBoard == row.id,
                                model: model
                            )
                            .id(row.id)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .frame(height: Self.listHeight)
            .onChange(of: model.openCount, initial: true) {
                proxy.scrollTo(state.currentBoardID, anchor: .center)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(state.footer)
                .accessibilityIdentifier("latency")
            Spacer(minLength: 0)
            Button(action: model.openSettings) {
                HStack(spacing: 4) {
                    Text("Settings…")
                    Text("⌘,").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityIdentifier("settings")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.top, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(.separator).frame(height: 1)
        }
        .padding(.top, 8)
    }
}

private struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.bottom, 5)
    }
}

private struct PermissionBanner: View {
    let request: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "keyboard.badge.eye")
                .font(.system(size: 17))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text("Downstroke needs Input Monitoring to hear your keys.")
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Input Monitoring…", action: request)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .focusable(false)
                    .accessibilityIdentifier("allowInputMonitoring")
                Text("After granting access, quit and reopen Downstroke.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.25)))
    }
}

/// 16 rising bars, lit left to right by the last hit's strength.
private struct HitMeter: View {
    static let height: CGFloat = 22
    @ObservedObject var meter: MeterModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<MeterModel.segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < meter.lit ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.quaternary))
                    .frame(height: 7 + CGFloat(i) / CGFloat(MeterModel.segments - 1) * (Self.height - 7))
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Hit strength")
        .accessibilityValue("\(meter.lit) of \(MeterModel.segments)")
    }
}

private struct BoardRow: View {
    let row: PanelState.Row
    let current: Bool
    let hovered: Bool
    let model: PanelModel

    var body: some View {
        HStack(spacing: 8) {
            Swatch(hex: row.color)
            Text(row.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovered {
                Button { model.play(row.id) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(current ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.quaternary), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Preview \(row.name)")
                .accessibilityLabel("Preview \(row.name)")
            }
            if current {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(current ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(current ? AnyShapeStyle(Color.accentColor) : hovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .onHover { model.hover(row.id, inside: $0) }
        .onTapGesture { model.select(row.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("board.\(row.id)")
        .accessibilityAction { model.select(row.id) }
    }
}

private struct Swatch: View {
    let hex: String

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(nsColor: Self.color(hex)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
            .frame(width: 10, height: 10)
    }

    static func color(_ hex: String) -> NSColor {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .systemGray }
        return NSColor(
            srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
