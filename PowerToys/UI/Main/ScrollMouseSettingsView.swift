import SwiftUI

struct ScrollMouseSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var scrollMouse = state.scrollMouse

        CardSection("Scrolling") {
            CardRow("Reverse mouse wheel", hint: "Flips the direction set in System Settings, for wheel mice only.") {
                RowSwitch(label: "Reverse mouse wheel", isOn: $scrollMouse.reversesMouse)
            }
            CardRow("Reverse trackpad", hint: "Flips it for trackpads and Magic Mouse.") {
                RowSwitch(label: "Reverse trackpad", isOn: $scrollMouse.reversesTrackpad)
            }
            CardRow("Smooth wheel scrolling", hint: "Glides between wheel notches. Hold a modifier key to scroll a line at a time.") {
                RowSwitch(label: "Smooth wheel scrolling", isOn: $scrollMouse.smoothsWheel)
            }
        }

        CardSection("Buttons") {
            ForEach(MouseButton.allCases) { button in
                ButtonActionRow(button: button)
            }
        }
    }
}

private struct ButtonActionRow: View {
    let button: MouseButton

    @Environment(AppState.self) private var state

    var body: some View {
        let scrollMouse = state.scrollMouse
        let action = scrollMouse.action(for: button)
        CardRow(button.title, hint: hint(for: action)) {
            HStack(spacing: 8) {
                if case .keys(let hotKey) = action {
                    ShortcutRecorder(
                        hotKey: hotKey,
                        validate: { _ in nil },
                        onProblem: { _ in },
                        onChange: { scrollMouse.setAction(.keys($0), for: button) },
                        onRecordingChange: { $0 ? state.shortcuts.suspend() : state.shortcuts.resume() }
                    )
                }
                Picker(
                    button.title,
                    selection: Binding(
                        get: { action.kind },
                        set: { scrollMouse.setAction(ButtonAction(kind: $0), for: button) })
                ) {
                    ForEach(ButtonAction.Kind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func hint(for action: ButtonAction) -> String {
        switch action {
        case .standard: button.hint
        case .back: "Presses ⌘[, Back in browsers, Finder and most apps."
        case .forward: "Presses ⌘], Forward in browsers, Finder and most apps."
        case .keys(nil): "Click to record the keys to press."
        case .keys: "Presses these keys in the app you're using."
        }
    }
}
