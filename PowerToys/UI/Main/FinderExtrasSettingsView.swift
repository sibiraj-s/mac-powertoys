import FinderSync
import SwiftUI

struct FinderExtrasSettingsView: View {
    @Environment(AppState.self) private var state
    /// Looked up once, since asking Launch Services on every redraw, such as each keystroke in
    /// the file name, is wasteful. The chosen one is always listed.
    @State private var terminals: [(id: String, name: String)] = []

    var body: some View {
        @Bindable var extras = state.finderExtras

        FinderMenuSection()

        VStack(alignment: .leading, spacing: 8) {
            CardSection("Actions") {
                ForEach(FinderExtrasController.Action.allCases) { action in
                    ActionRow(action: action)
                }
            }
            if let message = extras.message {
                MessageBanner(message: message, isError: extras.isError, dismiss: nil)
            }
        }

        CardSection("Options") {
            CardRow("New file name", hint: "Numbered when the name is taken, as Finder does.") {
                TextField("New file name", text: $extras.newFileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .labelsHidden()
            }
            CardRow("Copy paths as") {
                Picker("Copy paths as", selection: $extras.pathStyle) {
                    ForEach(FinderExtrasController.PathStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            CardRow("Terminal") {
                Picker("Terminal", selection: $extras.terminalID) {
                    ForEach(terminals, id: \.id) { terminal in
                        Text(terminal.name).tag(terminal.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onAppear { terminals = FinderExtrasController.installedTerminals(including: extras.terminalID) }
            }
            CardRow("Resize images to", hint: "The longest side. Copies leave out metadata such as where a photo was taken.") {
                Picker("Resize images to", selection: $extras.imageSize) {
                    ForEach(ImageResizer.sizes, id: \.self) { size in
                        Text("\(size) px").tag(size)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            CardRow("Show hidden files", hint: "In System Toggles, with its own shortcut and menu bar tile.") { EmptyView() }
        }
    }
}

/// One action: what it does, its shortcut, and a button to run it on Finder's selection now.
private struct ActionRow: View {
    let action: FinderExtrasController.Action

    @Environment(AppState.self) private var state
    /// Looked up once, since asking Launch Services on every redraw, such as each keystroke in
    /// the file name, is wasteful. The chosen one is always listed.
    @State private var terminals: [(id: String, name: String)] = []
    @State private var problem: String?

    var body: some View {
        CardRow(action.title, hint: state.shortcuts.hint(for: action.shortcut, problem: problem) ?? action.hint) {
            HStack(spacing: 8) {
                ShortcutField(definition: action.shortcut, problem: $problem)
                Button("Run") { Task { await state.finderExtras.perform(action) } }
                    .help("Runs it on what's selected in Finder now.")
            }
        }
    }
}

/// Whether the actions are in Finder's right-click menu, which the user turns on in System Settings.
private struct FinderMenuSection: View {
    @State private var isOn = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        CardSection("Finder menu") {
            CardRow(
                isOn ? "In Finder's right-click menu" : "Add to Finder's right-click menu",
                hint: isOn
                    ? "Under PowerToys when you right-click files or empty space in a folder."
                    : "Turn on PowerToys under Finder in the extensions settings that open."
            ) {
                Button(isOn ? "Extension Settings" : "Turn On…") {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isOn = FIFinderSyncController.isExtensionEnabled
        }
    }
}
