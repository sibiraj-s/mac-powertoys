import SwiftUI

struct SystemTogglesSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // One container, so the refreshes below run once rather than once per section.
        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            ForEach(SystemToggle.Group.allCases) { group in
                CardSection(group.title) {
                    ForEach(group.toggles) { toggle in
                        SystemToggleRow(toggle: toggle)
                    }
                }
            }
        }
        .onAppear { state.systemToggles.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.systemToggles.refresh()
        }
    }
}

/// One toggle or action: its shortcut, whether it's in the menu bar, and the switch or Run button.
private struct SystemToggleRow: View {
    let toggle: SystemToggle

    @Environment(AppState.self) private var state
    @State private var problem: String?

    var body: some View {
        let controller = state.systemToggles
        let inMenuBar = controller.isInMenuBar(toggle)

        CardRow {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: toggle.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 16)
                RowLabel(title: toggle.title, hint: hint)
            }
        } trailing: {
            HStack(spacing: 10) {
                ShortcutField(definition: toggle.shortcut, problem: $problem)
                Button {
                    controller.setInMenuBar(toggle, !inMenuBar)
                } label: {
                    Image(systemName: inMenuBar ? "menubar.arrow.up.rectangle" : "menubar.rectangle")
                        .foregroundStyle(inMenuBar ? Color.accentColor : Palette.secondaryText)
                }
                .buttonStyle(.borderless)
                .help(inMenuBar ? "Remove from the menu bar" : "Show in the menu bar")
                .accessibilityLabel(inMenuBar ? "In the menu bar" : "Not in the menu bar")

                if toggle.isAction {
                    Button("Run") { Task { await controller.run(toggle) } }
                        .disabled(controller.running.contains(toggle))
                        .frame(minWidth: 44)
                } else {
                    RowSwitch(label: toggle.title, isOn: Binding(
                        get: { controller.isOn(toggle) },
                        set: { controller.set(toggle, on: $0) }
                    ))
                    .disabled(controller.states[toggle] == nil)
                    .frame(minWidth: 44)
                }
            }
        }
    }

    private var hint: String {
        if let error = state.systemToggles.errors[toggle] { return error }
        if let shortcutHint = state.shortcuts.hint(for: toggle.shortcut, problem: problem) { return shortcutHint }
        if toggle == .wifi, state.systemToggles.states[.wifi] == nil { return "This Mac has no Wi‑Fi." }
        return toggle.hint
    }
}
