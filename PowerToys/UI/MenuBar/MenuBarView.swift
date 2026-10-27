import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            LazyVGrid(columns: columns, spacing: 8) {
                if state.isEnabled(.awake) {
                    QuickToggle(title: "Awake", subtitle: awakeSubtitle, symbol: "cup.and.saucer", isOn: state.awake.isActive) {
                        state.awake.toggle()
                    }
                    .contextMenu {
                        ForEach(AwakeController.Duration.allCases) { duration in
                            Button(duration.title) { state.awake.start(duration) }
                        }
                        if state.awake.isActive {
                            Divider()
                            Button("Stop") { state.awake.stop() }
                        }
                        Divider()
                        Button(Vigil.installedURL != nil ? "Open Vigil…" : "Get Vigil for triggers…") { Vigil.open() }
                    }
                }
                if state.isEnabled(.systemToggles) {
                    QuickToggle(title: "Dark mode", subtitle: colorScheme == .dark ? "On" : "Off", symbol: "moon", isOn: colorScheme == .dark) {
                        SystemToggles.toggleDarkMode()
                    }
                }
                QuickToggle(title: "Mic", subtitle: "Soon", symbol: "mic", isOn: false) {}
                    .disabled(true)
                QuickToggle(title: "Pick color", subtitle: "Soon", symbol: "eyedropper", isOn: false) {}
                    .disabled(true)
                QuickToggle(title: "Grab text", subtitle: "Soon", symbol: "text.viewfinder", isOn: false) {}
                    .disabled(true)
                QuickToggle(title: "Pin window", subtitle: "Soon", symbol: "pin", isOn: false) {}
                    .disabled(true)
            }

            Divider()

            VStack(spacing: 0) {
                MenuRow(title: "Settings…", shortcut: "⌘,") { openMainWindow() }
                    .keyboardShortcut(",", modifiers: .command)
                MenuRow(title: "Quit \(AppInfo.name)", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(10)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text(AppInfo.name).font(.headline)
            Spacer()
            Text("\(state.enabledCount) modules on")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var awakeSubtitle: String {
        guard state.awake.isActive else { return "Off" }
        guard let endsAt = state.awake.endsAt else { return "On" }
        return "Until \(endsAt.formatted(date: .omitted, time: .shortened))"
    }

    private func openMainWindow() {
        openWindow(id: MainWindow.id)
        // Clicking the menu bar icon doesn't activate the app; bring the window forward.
        NSApp.activate()
    }
}

private struct QuickToggle: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .background(Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
                    .padding(.bottom, 2)
                Text(title).font(.caption.weight(.medium))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct MenuRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Color.secondary.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
