import SwiftUI

struct PinCropSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let pinCrop = state.pinCrop

        CardSection("Pin") {
            if state.permissions.status(.screenRecording) != .granted {
                CardRow(
                    "Screen Recording is off", hint: "Needed to show windows. After allowing it, quit and open \(AppInfo.name) again."
                ) {
                    HStack(spacing: 6) {
                        Button("Open Settings") { state.permissions.openSettings(for: .screenRecording) }
                        Button("Quit & Reopen") { Relaunch.now() }
                    }
                }
            }
            CardRow("Pin or crop a window", hint: "Click a window to pin all of it, or drag over part of one to crop it. Esc cancels.") {
                Button("Pin…") { Task { await pinCrop.pick() } }
                    .disabled(pinCrop.isPicking)
            }
            ShortcutRow(definition: PinCropController.pinShortcut)
            if state.permissions.status(.accessibility) != .granted {
                CardRow(
                    "Accessibility is off (optional)",
                    hint: "Lets double-clicking a pin put the real window in its place to use it. Without it, only the app comes forward."
                ) {
                    Button("Allow") { state.permissions.request(.accessibility) }
                }
            }
        }

        CardSection("Pinned · \(pinCrop.pins.count)") {
            if pinCrop.pins.isEmpty {
                CardRow(
                    "Nothing pinned",
                    hint:
                        "A pin stays above other windows on every Space. Double-click it to use the real window in its place, or right-click for opacity."
                ) { EmptyView() }
            } else {
                ForEach(pinCrop.pins) { pin in
                    PinRow(pin: pin)
                }
                CardRow("Close all pins") {
                    Button("Close All") { pinCrop.closeAll() }
                }
            }
        }
    }
}

private struct PinRow: View {
    let pin: PinCropController.Pin

    @Environment(AppState.self) private var state

    var body: some View {
        CardRow {
            HStack(spacing: 8) {
                if let icon = NSRunningApplication(processIdentifier: pin.selection.window.pid)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                RowLabel(title: pin.appName, hint: pin.detail)
            }
        } trailing: {
            HStack(spacing: 6) {
                Button("Show") { state.pinCrop.showSource(of: pin) }
                    .help("Use the \(pin.appName) window in the pin's place")
                Button {
                    state.pinCrop.close(pin)
                } label: {
                    Image(systemName: "xmark").frame(width: 12)
                }
                .help("Close pin")
            }
        }
    }
}
