import SwiftUI
import AppKit
import Observation

/// Hover state lives here (the command-line toolchain lacks the @State macro plugin).
@MainActor @Observable
final class PanelState {
    static let shared = PanelState()
    var hovered: String?
    var showSettings = false
}

struct PanelView: View {
    @Environment(AudioController.self) private var audio
    var onDismiss: () -> Void
    var onSizeChange: (CGSize) -> Void

    var body: some View {
        let state = PanelState.shared
        VStack(alignment: .leading, spacing: 0) {
            Text("Sound")
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            // 🔈  ———— volume ————  [booster toggle]
            HStack(spacing: 7) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { audio.volume }, set: { audio.setVolume($0) }), in: 0...1)
                    .controlSize(.small)
                    .tint(.white)
                    .disabled(!audio.volumeAvailable)
                BoostToggle(on: audio.boostOn) { audio.boostOn.toggle() }
            }
            .padding(.horizontal, 12)

            if let error = audio.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }

            Separator().padding(.top, 8)

            Text("Output")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)

            VStack(spacing: 1) {
                ForEach(audio.devices) { device in
                    DeviceRow(device: device, selected: device.id == audio.currentID) {
                        audio.select(device)
                    }
                }
            }
            .padding(.horizontal, 4)

            Separator().padding(.top, 4).padding(.bottom, 3)

            HStack(spacing: 2) {
                MenuRow(id: "settings", title: "Sound Settings…") {
                    onDismiss()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
                GearButton(active: state.showSettings) { state.showSettings.toggle() }
                    .padding(.trailing, 4)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, state.showSettings ? 0 : 4)

            if state.showSettings {
                SettingsSection()
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 230)
        .fixedSize(horizontal: false, vertical: true)   // always natural height, never squeezed
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        // Pin content to the top so it doesn't drift while the window animates its height.
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

private struct GearButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        let hovered = PanelState.shared.hovered == "gear"
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .foregroundStyle(active ? Color.primary : .secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(active ? 0.18 : (hovered ? 0.12 : 0))))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { PanelState.shared.hovered = $0 ? "gear" : nil }
        .help("Amplify settings")
    }
}

/// Inline settings: launch at login + booster strength.
private struct SettingsSection: View {
    @Environment(AudioController.self) private var audio

    var body: some View {
        @Bindable var audio = audio
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Start at Login").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $audio.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Booster Strength").font(.system(size: 12))
                HStack(spacing: 4) {
                    ForEach(AudioController.strengthOptions, id: \.self) { value in
                        StrengthChip(value: value, selected: abs(audio.boostStrength - value) < 0.001) {
                            audio.boostStrength = value
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }
}

private struct StrengthChip: View {
    let value: Double
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let id = "strength\(value)"
        let hovered = PanelState.shared.hovered == id
        Button(action: action) {
            Text("\(Int(value * 100))%")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentColor)
                                           : AnyShapeStyle(Color.primary.opacity(hovered ? 0.18 : 0.1))))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { PanelState.shared.hovered = $0 ? id : nil }
    }
}

/// Round Control Center–style toggle: tap to turn the booster on/off for the current device.
private struct BoostToggle: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        let hovered = PanelState.shared.hovered == "boost"
        Button(action: action) {
            TripleChevron()
                .stroke(on ? Color.white : Color.primary,
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 8, height: 9)
                .frame(width: 20, height: 20)
                .background(Circle().fill(on ? AnyShapeStyle(Color.accentColor)
                                          : AnyShapeStyle(Color.primary.opacity(hovered ? 0.22 : 0.14))))
                .contentShape(.circle)
                .animation(.snappy(duration: 0.2), value: on)
        }
        .buttonStyle(.plain)
        .onHover { PanelState.shared.hovered = $0 ? "boost" : nil }
        .help(on ? "Booster on — click to turn off" : "Booster off — click to turn on")
    }
}

/// Three stacked upward chevrons (the booster glyph).
private struct TripleChevron: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let gap = r.height / 3.2
        let h = r.height - 2 * gap
        for i in 0..<3 {
            let top = r.minY + CGFloat(i) * gap
            p.move(to: CGPoint(x: r.minX, y: top + h))
            p.addLine(to: CGPoint(x: r.midX, y: top))
            p.addLine(to: CGPoint(x: r.maxX, y: top + h))
        }
        return p
    }
}

// MARK: - Rows

private struct DeviceRow: View {
    let device: OutputDevice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let hovered = PanelState.shared.hovered == "dev\(device.id)"
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: device.symbol)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.primary.opacity(0.15))))
                Text(device.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .contentShape(.rect)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { PanelState.shared.hovered = $0 ? "dev\(device.id)" : nil }
    }
}

private struct MenuRow: View {
    let id: String
    let title: String
    let action: () -> Void

    var body: some View {
        let hovered = PanelState.shared.hovered == id
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(.rect)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { PanelState.shared.hovered = $0 ? id : nil }
    }
}

private struct Separator: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.horizontal, 12)
    }
}
