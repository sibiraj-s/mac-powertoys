import AppKit
import SwiftUI

struct HostsEnvSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case hosts, environment

        var id: Self { self }
        var title: String { self == .hosts ? "Hosts" : "Environment" }
    }

    @AppStorage("hostsEnv.tab") private var tab = Tab.hosts

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch tab {
            case .hosts: HostsView()
            case .environment: EnvironmentView()
            }
        }
    }
}

// MARK: - Hosts

private struct HostsView: View {
    @Environment(AppState.self) private var state
    @State private var editing: EntryDraft?
    @State private var naming: GroupDraft?
    @State private var removingGroup: String?
    @State private var confirmingRestore = false

    var body: some View {
        let hosts = state.hosts
        let file = hosts.file

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            if let error = hosts.error {
                CardSection {
                    CardRow {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    } trailing: {
                        EmptyView()
                    }
                }
            }

            ForEach(file.sections) { section in
                HostsSectionView(
                    section: section, file: file,
                    edit: { editing = EntryDraft(entry: $0, group: section.name) },
                    add: { editing = EntryDraft(group: section.name) },
                    rename: { naming = GroupDraft(renaming: $0) },
                    remove: { removingGroup = $0 }
                )
            }

            if !file.systemEntries.isEmpty {
                CardSection("Built in") {
                    ForEach(file.systemEntries) { entry in
                        CardRow {
                            HostLabel(entry: entry, hint: nil)
                        } trailing: {
                            Image(systemName: "lock")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.secondaryText)
                                .help("macOS needs this entry")
                        }
                    }
                }
            }

            CardSection("Hosts file") {
                CardRow("New group", hint: "Entries in a group switch on and off together, such as everything for a staging setup.") {
                    Button("New Group…") { naming = GroupDraft(renaming: nil) }
                }
                CardRow("Flush DNS cache", hint: "Saving does this already. Useful after changing DNS settings.") {
                    Button("Flush") { Task { await hosts.flushDNS() } }
                }
                if hosts.hasBackup, let backup = hosts.backupURL {
                    CardRow("Original file", hint: "Before its first change, PowerToys saved a copy of \(HostsFile.path) to \(backup.path(percentEncoded: false).replacing(NSHomeDirectory(), with: "~")).") {
                        HStack(spacing: 6) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                            Button("Restore…") { confirmingRestore = true }
                        }
                    }
                }
                CardRow(HostsFile.path, hint: "Saved as you change it. macOS asks for an administrator password, then remembers it for a few minutes.") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(HostsFile.path, inFileViewerRootedAtPath: "")
                    }
                }
            }
        }
        .disabled(hosts.isSaving)
        .onAppear { hosts.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hosts.reload()
        }
        .sheet(item: $editing) { draft in
            HostEntryEditor(draft: draft, groups: file.groups)
        }
        .sheet(item: $naming) { draft in
            GroupNameEditor(draft: draft, existing: file.groups)
        }
        .confirmationDialog(
            "Delete the group “\(removingGroup ?? "")”?", isPresented: isRemovingGroup
        ) {
            Button("Delete Group and Entries", role: .destructive) {
                guard let group = removingGroup else { return }
                Task { await hosts.change { $0.removeGroup(group) } }
            }
        } message: {
            Text("Its entries are removed from the hosts file too.")
        }
        .confirmationDialog("Restore the original hosts file?", isPresented: $confirmingRestore) {
            Button("Restore", role: .destructive) { Task { await hosts.restoreOriginal() } }
        } message: {
            Text("Everything changed since PowerToys first edited it is replaced, including groups.")
        }
    }

    private var isRemovingGroup: Binding<Bool> {
        Binding(get: { removingGroup != nil }, set: { if !$0 { removingGroup = nil } })
    }
}

/// The entries outside groups, or one group with its switch.
private struct HostsSectionView: View {
    let section: HostsFile.Section
    let file: HostsFile
    let edit: (HostEntry) -> Void
    let add: () -> Void
    let rename: (String) -> Void
    let remove: (String) -> Void

    @Environment(AppState.self) private var state

    var body: some View {
        let hosts = state.hosts
        let onCount = section.entries.count(where: \.isEnabled)

        CardSection(section.name ?? "Entries") {
            if let group = section.name {
                CardRow {
                    Text(section.entries.isEmpty ? "No entries yet" : "\(onCount) of \(section.entries.count) on")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                } trailing: {
                    HStack(spacing: 10) {
                        Menu {
                            Button("Rename…") { rename(group) }
                            Button("Delete…", role: .destructive) { remove(group) }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("\(group) options")
                        RowSwitch(label: "Turn \(group) on", isOn: Binding(
                            get: { onCount > 0 },
                            set: { on in Task { await hosts.change { $0.setEnabled(group: group, on) } } }
                        ))
                        .disabled(section.entries.isEmpty)
                    }
                }
            }

            ForEach(section.entries) { entry in
                HostEntryRow(entry: entry, file: file, edit: { edit(entry) })
            }

            if section.name == nil, section.entries.isEmpty {
                CardRow("No entries yet", hint: "Point a host name at an address, such as myapp.test at 127.0.0.1.") {
                    EmptyView()
                }
            }

            CardRow {
                Button(action: add) {
                    Label("Add Entry", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            } trailing: {
                EmptyView()
            }
        }
    }
}

private struct HostEntryRow: View {
    let entry: HostEntry
    let file: HostsFile
    let edit: () -> Void

    @Environment(AppState.self) private var state

    var body: some View {
        let hosts = state.hosts

        CardRow {
            HostLabel(entry: entry, hint: hint)
                .opacity(entry.isEnabled ? 1 : 0.5)
        } trailing: {
            HStack(spacing: 10) {
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Options for \(entry.hostnames.joined(separator: " "))")
                RowSwitch(label: "Use \(entry.hostnames.joined(separator: " "))", isOn: Binding(
                    get: { entry.isEnabled },
                    set: { on in Task { await hosts.change { $0.setEnabled(entry.id, on) } } }
                ))
            }
        }
        .contentShape(Rectangle())
        .contextMenu { actions }
        .onTapGesture(count: 2, perform: edit)
    }

    @ViewBuilder
    private var actions: some View {
        let hosts = state.hosts
        Button("Edit…", action: edit)
        if !file.groups.isEmpty {
            Menu("Move To") {
                let current = file.group(of: entry.id)
                ForEach([String?.none] + file.groups.map(Optional.some), id: \.self) { group in
                    Button(group ?? "Entries") {
                        Task { await hosts.change { $0.move(entry.id, to: group) } }
                    }
                    .disabled(group == current)
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await hosts.change { $0.remove(entry.id) } }
        }
    }

    private var hint: String? {
        let shadowed = file.shadowedHostnames(of: entry)
        if !shadowed.isEmpty {
            return "\(shadowed.joined(separator: ", ")) \(shadowed.count == 1 ? "is" : "are") set by an earlier entry, which wins."
        }
        return entry.comment
    }
}

/// Host names, then the address in a fixed-width font, and a hint below.
private struct HostLabel: View {
    let entry: HostEntry
    let hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.hostnames.joined(separator: " "))
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(entry.address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Editing

private struct EntryDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var address: String
    var hostnames: String
    var comment: String
    var group: String?
    let original: HostEntry?

    init(entry: HostEntry? = nil, group: String?) {
        id = entry?.id ?? UUID()
        isNew = entry == nil
        address = entry?.address ?? "127.0.0.1"
        hostnames = entry?.hostnames.joined(separator: " ") ?? ""
        comment = entry?.comment ?? ""
        self.group = group
        original = entry
    }

    var entry: HostEntry {
        let comment = comment.trimmingCharacters(in: .whitespaces)
        return HostEntry(
            id: id, address: address.trimmingCharacters(in: .whitespaces),
            hostnames: HostEntry.hostnames(from: hostnames),
            comment: comment.isEmpty ? nil : comment.replacing("\n", with: " "),
            isEnabled: original?.isEnabled ?? true
        )
    }

    var problem: String? {
        HostEntry.problem(address: address, hostnames: HostEntry.hostnames(from: hostnames))
    }
}

private struct HostEntryEditor: View {
    @State var draft: EntryDraft
    let groups: [String]

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var showsProblem = false

    /// The entry was changed or removed outside PowerToys while this was open.
    private var isStale: Bool { !draft.isNew && !state.hosts.contains(draft.id) }

    var body: some View {
        EditorSheet(
            title: draft.isNew ? "Add Entry" : "Edit Entry",
            problem: isStale
                ? "This entry was changed or removed elsewhere. Cancel, then edit it again."
                : showsProblem ? draft.problem : nil,
            saveTitle: draft.isNew ? "Add" : "Save",
            canSave: draft.problem == nil && !isStale,
            save: save
        ) {
            Form {
                TextField("Host names", text: $draft.hostnames, prompt: Text("myapp.test api.myapp.test"))
                TextField("Address", text: $draft.address, prompt: Text("127.0.0.1"))
                    .font(.system(size: 12, design: .monospaced))
                TextField("Note", text: $draft.comment, prompt: Text("Optional"))
                if !groups.isEmpty {
                    Picker("Group", selection: $draft.group) {
                        Text("None").tag(String?.none)
                        ForEach(groups, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
            }
            .onChange(of: draft.hostnames) { showsProblem = true }
            .onChange(of: draft.address) { showsProblem = true }
        }
    }

    private func save() async {
        guard !isStale else { return }
        let entry = draft.entry
        let group = draft.group
        let saved = await state.hosts.change { file in
            if draft.isNew {
                file.add(entry, to: group)
            } else {
                file.update(entry)
                file.move(entry.id, to: group)
            }
        }
        if saved { dismiss() }
    }
}

private struct GroupDraft: Identifiable {
    let id = UUID()
    /// The group being renamed; nil for a new one.
    let renaming: String?
}

private struct GroupNameEditor: View {
    let draft: GroupDraft
    let existing: [String]

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        EditorSheet(
            title: draft.renaming == nil ? "New Group" : "Rename Group",
            problem: name.isEmpty ? nil : problem,
            saveTitle: draft.renaming == nil ? "Create" : "Rename",
            canSave: problem == nil,
            save: save
        ) {
            Form {
                TextField("Name", text: $name, prompt: Text("Staging"))
            }
        }
        .onAppear { name = draft.renaming ?? "" }
    }

    private var problem: String? {
        if let old = draft.renaming, name.trimmingCharacters(in: .whitespaces) == old { return nil }
        return HostsFile.problem(groupName: name, existing: existing.filter { $0 != draft.renaming })
    }

    private func save() async {
        let name = name.trimmingCharacters(in: .whitespaces)
        let saved = await state.hosts.change { file in
            if let old = draft.renaming {
                file.renameGroup(old, to: name)
            } else {
                file.addGroup(name)
            }
        }
        if saved { dismiss() }
    }
}

/// A small sheet with a form, a problem line, and Cancel and Save buttons.
private struct EditorSheet<Content: View>: View {
    let title: String
    let problem: String?
    let saveTitle: String
    let canSave: Bool
    let save: () async -> Void
    @ViewBuilder let content: Content

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content
                .controlSize(.regular)
            Text(problem ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            HStack {
                if state.hosts.isSaving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || state.hosts.isSaving)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
