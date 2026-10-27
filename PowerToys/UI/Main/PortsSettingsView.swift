import AppKit
import SwiftUI

struct PortsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""

    var body: some View {
        @Bindable var ports = state.ports
        let visible = ports.visibleListeners
        let shown = visible.filter { $0.matches(search) }
        let isEnabled = state.isEnabled(.portsProcesses)

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            CardSection(ports.isLoaded ? "Listening · \(visible.count)" : "Listening") {
                CardRow {
                    TextField("Filter by port, name or command", text: $search)
                        .textFieldStyle(.roundedBorder)
                } trailing: {
                    EmptyView()
                }
                if let error = ports.error {
                    CardRow {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    } trailing: {
                        EmptyView()
                    }
                }
                ForEach(shown) { listener in
                    PortRow(listener: listener)
                }
                if ports.isLoaded, shown.isEmpty {
                    CardRow(
                        search.isEmpty ? "Nothing is listening" : "No matches",
                        hint: search.isEmpty ? "Start a dev server or database and it shows up here." : nil
                    ) {
                        EmptyView()
                    }
                }
            }

            CardSection("Options") {
                CardRow("Show system services", hint: hiddenHint(ports.listeners.count - visible.count)) {
                    RowSwitch(label: "Show system services", isOn: $ports.showsSystemServices)
                }
                CardRow("Show in the menu bar", hint: "Lists what's listening in the menu, with a button to quit each.") {
                    RowSwitch(label: "Show in the menu bar", isOn: $ports.showsInMenuBar)
                }
            }
        }
        // Only while the module is on.
        .task(id: isEnabled) {
            if isEnabled { await ports.watch() }
        }
    }

    private func hiddenHint(_ hidden: Int) -> String {
        let base = "Background services macOS runs, such as AirPlay and Handoff. Ones running as root aren't listed."
        return hidden > 0 && !state.ports.showsSystemServices ? "\(base) \(hidden) hidden." : base
    }
}

private struct PortRow: View {
    let listener: Listener

    @Environment(AppState.self) private var state

    var body: some View {
        let ports = state.ports

        CardRow {
            HStack(alignment: .top, spacing: 10) {
                ProcessIcon(pid: listener.pid, size: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(":\(String(listener.port))")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text(listener.name)
                            .font(.system(size: 13))
                        ReachTag(isLocalOnly: listener.isLocalOnly)
                    }
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(listener.process?.commandLine ?? listener.command)
                    if let status = ports.status(of: listener) {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
        } trailing: {
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(listener.url)
                } label: {
                    Image(systemName: "safari")
                }
                .help("Open \(listener.url.absoluteString)")
                Menu {
                    PortActions(listener: listener)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Options for port \(listener.port)")
                QuitButton(listener: listener)
            }
            .buttonStyle(.borderless)
        }
        .contextMenu { PortActions(listener: listener) }
    }

    private var details: String {
        var parts: [String] = []
        if let process = listener.process {
            if !process.commandLine.isEmpty { parts.append(process.commandLine) }
            if let folder = process.shortDirectory, folder != "/" { parts.append(folder) }
            if let started = process.started { parts.append("up \(ProcessDetails.uptime(since: started))") }
        }
        parts.append("PID \(listener.pid)")
        if !listener.workers.isEmpty {
            let count = listener.workers.count
            parts.append("\(count) worker\(count == 1 ? "" : "s") (\(listener.workers.map(String.init).joined(separator: ", ")))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Quit, or Force Quit once a process has ignored quitting.
struct QuitButton: View {
    let listener: Listener

    @Environment(AppState.self) private var state

    var body: some View {
        let ports = state.ports
        let isStubborn = ports.stubborn.contains(listener.pid)
        Button {
            Task { await ports.quit(listener, force: isStubborn) }
        } label: {
            Image(systemName: isStubborn ? "xmark.octagon.fill" : "xmark.circle")
                .foregroundStyle(isStubborn ? Color.red : Palette.secondaryText)
        }
        .buttonStyle(.borderless)
        .disabled(ports.quitting.contains(listener.pid))
        .help(isStubborn ? "Force quit \(listener.name)" : "Quit \(listener.name)")
    }
}

struct PortActions: View {
    let listener: Listener

    @Environment(AppState.self) private var state

    var body: some View {
        let ports = state.ports
        Button("Open in Browser") { NSWorkspace.shared.open(listener.url) }
        Button("Copy URL") { copy(listener.url.absoluteString) }
        Button("Copy PID") { copy(String(listener.pid)) }
        if let folder = listener.process?.directory, folder != "/" {
            Button("Show Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: folder, directoryHint: .isDirectory)])
            }
        }
        Divider()
        Button("Quit") { Task { await ports.quit(listener) } }
        Button("Force Quit", role: .destructive) { Task { await ports.quit(listener, force: true) } }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// "localhost" for ports only this Mac can reach, "network" for ones other devices can.
private struct ReachTag: View {
    let isLocalOnly: Bool

    var body: some View {
        Text(isLocalOnly ? "localhost" : "network")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(isLocalOnly ? Palette.secondaryText : Color.orange)
            .background(Capsule().fill((isLocalOnly ? Color.secondary : Color.orange).opacity(0.12)))
            .help(isLocalOnly ? "Only this Mac can connect." : "Other devices on your network can connect.")
    }
}

/// The app's icon when the process is an app, otherwise a terminal symbol.
struct ProcessIcon: View {
    let pid: pid_t
    let size: CGFloat

    /// Icons by process, looked up once rather than on every refresh. Nil for processes that
    /// aren't apps.
    private static var icons: [pid_t: NSImage?] = [:]

    private static func icon(for pid: pid_t) -> NSImage? {
        if let known = icons[pid] { return known }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        if icons.count > 500 { icons.removeAll() }
        icons[pid] = icon
        return icon
    }

    var body: some View {
        if let icon = Self.icon(for: pid) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.6))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: size, height: size)
        }
    }
}
