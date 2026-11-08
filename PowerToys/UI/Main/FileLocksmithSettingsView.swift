import AppKit
import SwiftUI

struct FileLocksmithSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var isTargeted = false

    var body: some View {
        let locksmith = state.locksmith

        CardSection("Check") {
            CardRow {
                RowLabel(title: targetTitle, hint: targetHint)
            } trailing: {
                HStack(spacing: 6) {
                    Button("Choose…") { choose() }
                    Button("Finder Selection") { Task { await locksmith.checkFinderSelection() } }
                        .help("Checks the first item selected in Finder.")
                    Menu("Disk") {
                        if locksmith.volumes.isEmpty {
                            Text("No disks to eject")
                        }
                        ForEach(locksmith.volumes, id: \.self) { volume in
                            Button(volume.lastPathComponent) { Task { await locksmith.check(volume) } }
                        }
                    }
                    .fixedSize()
                    .help("Checks what's keeping a disk from ejecting.")
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                Task { await locksmith.check(url) }
                return true
            } isTargeted: {
                isTargeted = $0
            }
        }
        .onAppear { locksmith.refreshVolumes() }

        if let message = locksmith.error ?? locksmith.notice {
            MessageBanner(message: message, isError: locksmith.error != nil, dismiss: nil)
        }

        if locksmith.target != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SectionTitle(locksmith.hasScanned ? "Using it · \(locksmith.holders.count)" : "Using it")
                    Spacer()
                    if locksmith.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check Again") { Task { await locksmith.scan() } }
                        .disabled(locksmith.isScanning)
                }
                .controlSize(.small)

                CardSection {
                    ForEach(locksmith.holders) { holder in
                        HolderRow(holder: holder)
                    }
                    if locksmith.hasScanned, locksmith.holders.isEmpty {
                        CardRow("Nothing has it open", hint: emptyHint) {
                            if locksmith.targetIsVolume {
                                Button("Eject") { Task { await locksmith.ejectTarget() } }
                            }
                        }
                    }
                    if !locksmith.scannedAsAdministrator {
                        CardRow(
                            "Include system processes",
                            hint:
                                "Processes macOS runs, such as Spotlight indexing a disk, are only listed after an administrator password."
                        ) {
                            Button("Check as Administrator") { Task { await locksmith.scan(asAdministrator: true) } }
                                .disabled(locksmith.isScanning)
                        }
                    }
                }
            }
        }
    }

    private var targetTitle: String {
        guard let target = state.locksmith.target else { return "Drop a file, folder or disk here" }
        return FileManager.default.displayName(atPath: target.path(percentEncoded: false))
    }

    private var targetHint: String {
        guard let target = state.locksmith.target else {
            return "Or choose one, use what's selected in Finder, or pick a disk that won't eject."
        }
        return ProcessDetails.abbreviatingHome(target.path(percentEncoded: false))
    }

    private var emptyHint: String {
        let locksmith = state.locksmith
        if locksmith.targetIsVolume {
            return locksmith.scannedAsAdministrator ? "It can be ejected now." : "Try ejecting it now."
        }
        return locksmith.scannedAsAdministrator
            ? "No process has it open." : "None of your processes has it open."
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Check"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.locksmith.check(url) }
    }
}

private struct HolderRow: View {
    let holder: FileHolder

    @Environment(AppState.self) private var state

    var body: some View {
        let locksmith = state.locksmith
        let isStubborn = locksmith.stubborn.contains(holder.pid)

        CardRow {
            HStack(alignment: .top, spacing: 10) {
                ProcessIcon(pid: holder.pid, size: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(holder.name).font(.system(size: 13))
                        Text("PID \(String(holder.pid))")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    Text(holder.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(holder.files.map { "\($0.use): \($0.path)" }.joined(separator: "\n"))
                    if let status = locksmith.status(of: holder) {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
        } trailing: {
            Button(isStubborn ? "Force Quit" : "Quit") {
                Task { await locksmith.quit(holder, force: isStubborn) }
            }
            .disabled(locksmith.quitting.contains(holder.pid))
            .help(isStubborn ? "Stops \(holder.name) now; unsaved changes are lost." : "Asks \(holder.name) to quit.")
        }
        .contextMenu {
            Button("Quit") { Task { await locksmith.quit(holder) } }
            Button("Force Quit", role: .destructive) { Task { await locksmith.quit(holder, force: true) } }
            Divider()
            Button("Copy PID") { NSPasteboard.general.copy(String(holder.pid)) }
        }
    }
}
