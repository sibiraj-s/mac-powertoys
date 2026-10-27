import SwiftUI

struct ZonesSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var screens = Displays.ordered
    @State private var displayKey = NSScreen.main.map { Displays.key(for: $0) } ?? ""

    var body: some View {
        @Bindable var zones = state.zones

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Layout")
                Spacer()
                if screens.count > 1 {
                    Picker("Display", selection: $displayKey) {
                        ForEach(screens, id: \.self) { screen in
                            Text(screen.localizedName).tag(Displays.key(for: screen))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                ForEach(ZoneLayout.all) { layout in
                    LayoutCard(layout: layout, isSelected: zones.layout(forDisplay: displayKey) == layout) {
                        zones.setLayout(layout, forDisplay: displayKey)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = Displays.ordered
            if !screens.map({ Displays.key(for: $0) }).contains(displayKey) {
                displayKey = NSScreen.main.map { Displays.key(for: $0) } ?? ""
            }
        }

        CardSection("Behavior") {
            CardRow("Hold ⇧ while dragging to show zones", hint: "Release over a zone to snap the window into it.") {
                RowSwitch(label: "Hold Shift while dragging to show zones", isOn: $zones.snapsWhileDragging)
            }
            CardRow("Span multiple zones with ⌥", hint: "Also hold ⌥ and drag across neighboring zones to merge them.") {
                RowSwitch(label: "Span multiple zones with Option", isOn: $zones.spansWithOption)
            }
            .disabled(!zones.snapsWhileDragging)
            CardRow("Restore original size when unsnapped", hint: "Dragging a snapped window out returns it to its previous size.") {
                RowSwitch(label: "Restore original size when unsnapped", isOn: $zones.restoresSizeOnUnsnap)
            }
        }

        CardSection("Shortcuts") {
            ForEach(ZonesController.Action.allCases) { action in
                CardRow(action.title, hint: zones.unavailableActions.contains(action) ? "Another app is using this shortcut." : nil) {
                    KeyCaps(keys: action.hotKey.keyCaps)
                        .opacity(zones.unavailableActions.contains(action) ? 0.5 : 1)
                }
            }
        }
    }
}

private struct LayoutCard: View {
    let layout: ZoneLayout
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                LayoutPreview(layout: layout, isSelected: isSelected)
                    .aspectRatio(16 / 10, contentMode: .fit)
                Text(layout.name)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.08) : Palette.content))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Palette.border, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A miniature display with the layout's zones; the selected layout's main zone is highlighted.
private struct LayoutPreview: View {
    let layout: ZoneLayout
    let isSelected: Bool

    var body: some View {
        GeometryReader { geometry in
            let frames = layout.frames(in: CGRect(origin: .zero, size: geometry.size).insetBy(dx: 3, dy: 3))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.18))
                ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isSelected && index == mainZone ? Color.accentColor : Color(white: 0.56))
                        .padding(1.5)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
    }

    /// The single largest zone, if one is larger than the rest (Focus's middle column).
    private var mainZone: Int? {
        let areas = layout.zones.map { $0.width * $0.height }
        guard let largest = areas.max(), areas.filter({ $0 == largest }).count == 1 else { return nil }
        return areas.firstIndex(of: largest)
    }
}
