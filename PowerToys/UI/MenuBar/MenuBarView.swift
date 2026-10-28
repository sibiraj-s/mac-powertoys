import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    /// The menu's own window, so other windows becoming key don't trigger refreshes.
    @State private var window: NSWindow?

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
                    ForEach(state.systemToggles.menuBarItems) { toggle in
                        QuickToggle(
                            title: toggle.shortTitle,
                            subtitle: state.systemToggles.status(of: toggle),
                            symbol: toggle.symbol,
                            isOn: !toggle.isAction && state.systemToggles.isOn(toggle)
                        ) {
                            Task { await state.systemToggles.perform(toggle) }
                        }
                    }
                }
                if state.isEnabled(.clipboard) {
                    QuickToggle(title: "Clipboard", subtitle: historyKeys ?? "History", symbol: "doc.on.clipboard", isOn: false) {
                        state.clipboard.showHistory()
                    }
                }
                QuickToggle(title: "Mic", subtitle: "Soon", symbol: "mic", isOn: false) {}
                    .disabled(true)
                if state.isEnabled(.colorPicker) {
                    QuickToggle(title: "Pick color", subtitle: pickSubtitle, symbol: "eyedropper", isOn: false) {
                        // Out of the way, so the color under the menu can be picked too.
                        window?.close()
                        Task { await state.colorPicker.pick() }
                    }
                    .disabled(state.colorPicker.isPicking)
                    .contextMenu {
                        ForEach(state.colorPicker.history.prefix(8)) { color in
                            Button("Copy \(color.formatted(as: state.colorPicker.format))") { state.colorPicker.copy(color) }
                        }
                    }
                }
                if state.isEnabled(.textExtractor) {
                    QuickToggle(title: "Grab text", subtitle: grabSubtitle, symbol: "text.viewfinder", isOn: false) {
                        // Out of the way, so text under the menu can be read too.
                        window?.close()
                        Task { await state.textExtractor.extract() }
                    }
                    .disabled(state.textExtractor.isExtracting)
                    .contextMenu {
                        ForEach(state.textExtractor.history.prefix(8)) { item in
                            Button("Copy “\(item.menuTitle)”") { state.textExtractor.copy(item) }
                        }
                    }
                }
                QuickToggle(title: "Pin window", subtitle: "Soon", symbol: "pin", isOn: false) {}
                    .disabled(true)
            }

            if state.isEnabled(.portsProcesses), state.ports.showsInMenuBar {
                Divider()
                MenuPorts()
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
        // Settings can change elsewhere. The menu's window stays alive between openings, so
        // read them again each time it becomes key, not only on first appearance.
        .background(WindowReader { window = $0 })
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window, notification.object as? NSWindow === window else { return }
            refresh()
        }
    }

    private func refresh() {
        state.systemToggles.refresh()
        if state.isEnabled(.portsProcesses), state.ports.showsInMenuBar {
            Task { await state.ports.refresh() }
        }
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

    /// The keys that open clipboard history, as customized.
    private var historyKeys: String? {
        state.shortcuts.hotKey(for: ClipboardController.Action.showHistory.shortcut)?.keyCaps.joined()
    }

    private var pickSubtitle: String {
        let picker = state.colorPicker
        if let latest = picker.latest { return latest.formatted(as: picker.format) }
        return state.shortcuts.hotKey(for: ColorPickerController.pickShortcut)?.keyCaps.joined() ?? "Magnifier"
    }

    private var grabSubtitle: String {
        state.shortcuts.hotKey(for: TextExtractorController.extractShortcut)?.keyCaps.joined() ?? "To clipboard"
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

/// What's listening, each with a button to open it and one to quit it.
private struct MenuPorts: View {
    static let limit = 6

    @Environment(AppState.self) private var state

    var body: some View {
        let listeners = state.ports.visibleListeners
        VStack(alignment: .leading, spacing: 2) {
            Text("Listening")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            if let error = state.ports.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            if state.ports.isLoaded, listeners.isEmpty, state.ports.error == nil {
                Text("Nothing is listening")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            ForEach(listeners.prefix(Self.limit)) { listener in
                HStack(spacing: 8) {
                    ProcessIcon(pid: listener.pid, size: 16)
                    Text(":\(String(listener.port))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(listener.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(listener.url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .help("Open \(listener.url.absoluteString)")
                    QuitButton(listener: listener)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .frame(minHeight: 24)
                .contextMenu { PortActions(listener: listener) }
            }
            if listeners.count > Self.limit {
                Text("\(listeners.count - Self.limit) more in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
    }
}
