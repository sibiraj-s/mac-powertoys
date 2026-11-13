import SwiftUI

struct LanesSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var lanes = state.lanes

        CardSection("Scrolling") {
            CardRow(
                "Scroll a row with a swipe or the wheel",
                hint:
                    "Hold these keys and swipe sideways with two fingers on the trackpad to scroll the row under the pointer, or turn the mouse wheel to step along it a window at a time. Apps don't get scrolling done with them held. Needs Accessibility."
            ) {
                Picker("Scroll a row with a swipe or the wheel", selection: $lanes.scrollModifier) {
                    ForEach(LanesController.ScrollModifier.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            CardRow(
                "Overview while scrolling",
                hint:
                    "Shows the whole row while you scroll it, with the part on screen framed and the window the row is on picked out. Pick where on the display it goes."
            ) {
                Picker("Overview while scrolling", selection: $lanes.overviewPosition) {
                    ForEach(LaneOverview.Position.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if lanes.overviewPosition != .off, state.permissions.status(.screenRecording) != .granted {
                CardRow(
                    "Screen Recording is off (optional)",
                    hint:
                        "Shows a picture of each window in the overview instead of its app's icon. After allowing it, quit and open \(AppInfo.name) again."
                ) {
                    HStack(spacing: 6) {
                        Button("Open Settings") { state.permissions.openSettings(for: .screenRecording) }
                        Button("Quit & Reopen") { Relaunch.now() }
                    }
                }
            }
        }

        CardSection("Shortcuts") {
            ForEach(LanesController.Action.allCases) { action in
                ShortcutRow(definition: action.shortcut)
            }
        }

        // What Lanes does on its own, as plain text: in a card these would read as settings.
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("How it works")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.notes, id: \.self) { note in
                    Text(note).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryText)
            .padding(.leading, 2)
        }
    }

    private static let notes = [
        "Each display has one row of windows. A new window opens beside the one you're using, and the row scrolls to the window with the keyboard.",
        "Drag a window's edge to set its width, or drag the window to another place in the row. Minimized windows come back where they were.",
        "Dialogs, fixed-size windows, full-screen apps and \(AppInfo.name)'s own windows are left alone.",
        "Turning Lanes off, or quitting \(AppInfo.name), puts every window back where it was.",
        "Lanes and Zones can't be on together: turning one on turns the other off.",
    ]
}
