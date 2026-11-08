import SwiftUI

struct WindowSwitcherSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var switcher = state.windowSwitcher

        CardSection("Switch") {
            if state.permissions.status(.accessibility) != .granted {
                CardRow("Accessibility is off", hint: "Needed to find windows and bring them forward.") {
                    Button("Allow") { state.permissions.request(.accessibility) }
                }
            }
            ShortcutRow(definition: WindowSwitcherController.switchShortcut)
            CardRow(
                "How it works",
                hint:
                    "Hold the shortcut's modifier keys and press its key to step through windows, ⇧ to step back. Let go to switch. Esc cancels; arrows and clicks work too."
            ) { EmptyView() }
            CardRow("Actions", hint: "While switching: W closes the window, M minimizes it, H hides its app and Q quits it.") {
                EmptyView()
            }
        }

        CardSection("Look") {
            CardRow("Style", hint: "Grid shows every window at once. Stack puts the selected window in front with the next ones behind it.")
            {
                Picker("Style", selection: $switcher.style) {
                    ForEach(WindowSwitcherController.Style.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            CardRow(
                "Peek",
                hint: switcher.style == .grid
                    ? "Dims the screen around the selected window so you can see where you'll land."
                    : "Grid only: the stack already shows the selected window large."
            ) {
                RowSwitch(label: "Peek", isOn: $switcher.peeks)
                    .disabled(switcher.style != .grid)
            }
            if state.permissions.status(.screenRecording) != .granted {
                CardRow(
                    "Screen Recording is off (optional)",
                    hint:
                        "Shows a preview of each window instead of its app's icon. After allowing it, quit and open \(AppInfo.name) again."
                ) {
                    HStack(spacing: 6) {
                        Button("Open Settings") { state.permissions.openSettings(for: .screenRecording) }
                        Button("Quit & Reopen") { Relaunch.now() }
                    }
                }
            }
        }
    }
}
