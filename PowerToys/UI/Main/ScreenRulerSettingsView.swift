import SwiftUI

struct ScreenRulerSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var ruler = state.screenRuler

        CardSection("Measure") {
            if state.permissions.status(.screenRecording) != .granted {
                CardRow(
                    "Screen Recording is off", hint: "Needed to read the screen. After allowing it, quit and open \(AppInfo.name) again."
                ) {
                    HStack(spacing: 6) {
                        Button("Open Settings") { state.permissions.openSettings(for: .screenRecording) }
                        Button("Quit & Reopen") { Relaunch.now() }
                    }
                }
            }
            CardRow(
                "Measure the screen",
                hint:
                    "Lines run out from the pointer to the nearest edges. Click to copy that spacing, or drag to measure an area. Esc cancels."
            ) {
                Button("Measure…") { Task { await ruler.measure() } }
                    .disabled(ruler.isMeasuring)
            }
            ShortcutRow(definition: ScreenRulerController.measureShortcut)
        }

        CardSection("Options") {
            CardRow("Units", hint: "Points match AppKit, SwiftUI and CSS. Pixels are the display's own, twice as many on Retina.") {
                Picker("Units", selection: $ruler.unit) {
                    ForEach(RulerUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            CardRow("Edge tolerance", hint: "How different a color has to be to count as an edge. Raise it for gradients and shadows.") {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(get: { Double(ruler.tolerance) }, set: { ruler.tolerance = Int($0.rounded()) }),
                        in: Double(
                            ScreenRulerController.toleranceRange.lowerBound)...Double(ScreenRulerController.toleranceRange.upperBound)
                    )
                    .controlSize(.small)
                    .frame(width: 140)
                    .accessibilityLabel("Edge tolerance")
                    Text("\(ruler.tolerance)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
            }
        }

        if let latest = ruler.latest {
            CardSection("Latest") {
                CardRow(latest.text(in: ruler.unit), hint: latest.kind == .spacing ? "Spacing between edges" : "Area dragged over") {
                    Button("Copy") { ruler.copy(latest) }
                }
            }
        }
    }
}
