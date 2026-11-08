import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeysSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var keys = state.keys

        CardSection("Caps Lock") {
            CardRow("Caps Lock key", hint: keys.capsLock.hint) {
                Picker("Caps Lock key", selection: $keys.capsLock) {
                    ForEach(CapsLockMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        CardSection("Remaps") {
            ForEach(keys.remaps) { remap in
                RemapRow(remap: remap)
            }
            CardRow(
                keys.remaps.isEmpty ? "No remaps yet" : "Add another",
                hint: "Press other keys instead of the ones you record, everywhere or in one app."
            ) {
                Button("Add Remap") { keys.addRemap() }
                    .controlSize(.small)
            }
        }
    }
}

private struct RemapRow: View {
    let remap: KeyRemap

    @Environment(AppState.self) private var state
    @State private var problem: String?

    var body: some View {
        let keys = state.keys
        CardRow {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    recorder(remap.from, validate: { keys.problem(with: $0, from: remap) }) { from in
                        var changed = remap
                        changed.from = from
                        keys.update(changed)
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                    if case .keys(let output) = remap.output {
                        recorder(output, validate: { _ in nil }) { output in
                            var changed = remap
                            changed.output = .keys(output)
                            keys.update(changed)
                        }
                    }
                    Picker(
                        "Output",
                        selection: Binding(
                            get: { remap.output.kind },
                            set: { kind in
                                var changed = remap
                                changed.output = .init(kind: kind)
                                keys.update(changed)
                            })
                    ) {
                        ForEach(KeyRemap.Output.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let problem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
        } trailing: {
            HStack(spacing: 8) {
                AppScopeMenu(app: remap.app) { app in
                    var changed = remap
                    changed.app = app
                    keys.update(changed)
                }
                Button {
                    keys.remove(remap.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove remap")
            }
        }
    }

    private func recorder(
        _ hotKey: HotKey?, validate: @escaping (HotKey) -> String?, onChange: @escaping (HotKey?) -> Void
    ) -> some View {
        ShortcutRecorder(
            hotKey: hotKey,
            validate: validate,
            onProblem: { problem = $0 },
            onChange: onChange,
            onRecordingChange: { recording in
                // Record the keys as pressed, not as already remapped or taken by a shortcut.
                state.keys.isPaused = recording
                recording ? state.shortcuts.suspend() : state.shortcuts.resume()
            }
        )
    }
}

/// Picks the app a remap applies in: every app, a running one, or any other from a file panel.
private struct AppScopeMenu: View {
    let app: KeyRemap.App?
    let onChange: (KeyRemap.App?) -> Void

    var body: some View {
        Menu {
            Button("All Apps") { onChange(nil) }
            Divider()
            ForEach(Self.runningApps, id: \.bundleID) { app in
                Button(app.name) { onChange(app) }
            }
            Divider()
            Button("Other App…") { chooseApp() }
        } label: {
            Text(app?.name ?? "All Apps")
                .font(.system(size: 11))
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help(app.map { "Only in \($0.name)" } ?? "In every app")
    }

    private static var runningApps: [KeyRemap.App] {
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> KeyRemap.App? in
            guard app.activationPolicy == .regular, app != .current, let id = app.bundleIdentifier else { return nil }
            return KeyRemap.App(bundleID: id, name: app.localizedName ?? id)
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier
        else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacing(/\.app$/, with: "")
        onChange(KeyRemap.App(bundleID: id, name: name))
    }
}
