import AppKit
import SwiftUI

struct LaunchAgentsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var trashing: LaunchItem?

    var body: some View {
        @Bindable var launch = state.launchAgents
        let isEnabled = state.isEnabled(.launchAgents)

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            CardSection {
                CardRow {
                    TextField("Filter by label or program", text: $search)
                        .textFieldStyle(.roundedBorder)
                } trailing: {
                    EmptyView()
                }
                if let error = launch.error {
                    CardRow {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    } trailing: {
                        EmptyView()
                    }
                }
            }

            ForEach(launch.locations) { location in
                let items = launch.items(in: location).filter { $0.matches(search) }
                // Empty folders other than your own are left out, as are Apple's when filtering finds nothing.
                if !items.isEmpty || (location == .userAgents && search.isEmpty) {
                    CardSection("\(location.title) · \(items.count)") {
                        CardRow {
                            Text(location.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.secondaryText)
                        } trailing: {
                            Button {
                                NSWorkspace.shared.open(location.directory)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Open \(location.directory.path)")
                        }
                        ForEach(items) { item in
                            LaunchItemRow(item: item, trash: { trashing = item })
                        }
                        if items.isEmpty {
                            CardRow("None", hint: nil) { EmptyView() }
                        }
                    }
                }
            }

            CardSection("Options") {
                CardRow("Show Apple's agents and daemons", hint: "Hundreds of jobs that are part of macOS. Shown read-only.") {
                    RowSwitch(label: "Show Apple's agents and daemons", isOn: $launch.showsAppleItems)
                }
                CardRow("Login items", hint: "Apps that open at login, and background items apps add, are in System Settings.") {
                    Button("Open") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                }
            }
        }
        .task(id: isEnabled) {
            if isEnabled { await launch.watch() }
        }
        .confirmationDialog(
            "Move “\(trashing?.label ?? "")” to the Trash?", isPresented: isTrashing
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let item = trashing else { return }
                Task { await launch.moveToTrash(item) }
            }
        } message: {
            Text("It's unloaded first, so it stops running. You can put it back from the Trash.")
        }
    }

    private var isTrashing: Binding<Bool> {
        Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })
    }
}

private struct LaunchItemRow: View {
    let item: LaunchItem
    let trash: () -> Void

    @Environment(AppState.self) private var state

    var body: some View {
        let launch = state.launchAgents
        let status = launch.status(of: item)
        let isBusy = launch.busy.contains(item.id)

        CardRow {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(status.pid != nil ? Palette.on : status.hasFailed ? Color.orange : Palette.off)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                    .accessibilityLabel(status.text)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(details(status))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(item.program.joined(separator: " "))
                    if item.isProgramMissing {
                        Text("Its program is gone, so it can't run. It may be left over from a deleted app.")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    } else if status.hasFailed, status.isEnabled {
                        Text(status.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
                .opacity(status.isEnabled ? 1 : 0.6)
            }
        } trailing: {
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Menu {
                    actions(status)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Options for \(item.label)")
                if !item.location.isApple {
                    RowSwitch(label: "Turn \(item.label) on", isOn: Binding(
                        get: { status.isEnabled },
                        set: { on in Task { await launch.setEnabled(item, on) } }
                    ))
                    .disabled(isBusy)
                }
            }
        }
        .contextMenu { actions(status) }
    }

    private func details(_ status: LaunchStatus) -> String {
        var parts = [item.schedule]
        if !item.commandLine.isEmpty { parts.append(item.commandLine) }
        if !status.hasFailed || !status.isEnabled { parts.append(status.text) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(_ status: LaunchStatus) -> some View {
        let launch = state.launchAgents
        if !item.location.isApple {
            Button("Start") { Task { await launch.perform(.start, on: item) } }
                .disabled(!status.isEnabled || status.pid != nil)
            Button("Restart") { Task { await launch.perform(.restart, on: item) } }
                .disabled(!status.isLoaded)
            if item.restartsWhenStopped {
                // launchd would start it again at once; the switch is what keeps it stopped.
                Button("Stop (Turn It Off to Keep It Stopped)") {}
                    .disabled(true)
            } else {
                Button("Stop") { Task { await launch.perform(.stop, on: item) } }
                    .disabled(status.pid == nil)
            }
            Divider()
        }
        Button("Open Plist") { NSWorkspace.shared.open(item.url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        ForEach(item.logPaths, id: \.self) { path in
            Button("Open \(URL(filePath: path).lastPathComponent)") {
                launch.openLog(path, of: item)
            }
        }
        Button("Copy Label") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.label, forType: .string)
        }
        if item.location.canTrash {
            Divider()
            Button("Move to Trash…", role: .destructive, action: trash)
        }
    }
}
