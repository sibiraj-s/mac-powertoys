import AppKit
import SwiftUI

struct DefaultsBrowserSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var tab = Tab.tweaks

    private enum Tab: String, CaseIterable, Identifiable {
        case tweaks = "Hidden Settings", domains = "All Domains"
        var id: Self { self }
    }

    var body: some View {
        let browser = state.defaultsBrowser
        let isEnabled = state.isEnabled(.defaultsBrowser)

        Group {
            if !isEnabled {
                CardSection("Settings") {
                    CardRow("Turn on Defaults Browser to see the settings", hint: "Nothing is read until it's on.") { EmptyView() }
                }
            } else if browser.openDomain != nil {
                DomainView()
            } else {
                VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
                    Picker("Show", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    switch tab {
                    case .tweaks: TweakList()
                    case .domains: DomainList()
                    }
                }
            }
        }
        .task(id: isEnabled) {
            if isEnabled { await browser.loadTweaks() }
        }
    }
}

// MARK: - Hidden settings

private struct TweakList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let browser = state.defaultsBrowser
        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            if let error = browser.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            ForEach(DefaultsTweak.Group.allCases) { group in
                CardSection(group.rawValue) {
                    ForEach(DefaultsTweak.tweaks(in: group)) { tweak in
                        TweakRow(tweak: tweak)
                    }
                    ForEach(restarts(in: group), id: \.self) { restart in
                        if let name = restart.processName, browser.pendingRestarts.contains(restart) {
                            CardRow {
                                Label("Restart \(name) to see the change.", systemImage: "arrow.clockwise")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            } trailing: {
                                Button("Restart \(name)") { browser.restart(restart) }
                            }
                        }
                    }
                }
            }
            Text("Each key can also be found under All Domains. PowerToys saves a domain's settings before changing it the first time, and they can be restored from there.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await browser.loadTweaks() }
        }
    }

    private func restarts(in group: DefaultsTweak.Group) -> [DefaultsTweak.Restart] {
        var seen: [DefaultsTweak.Restart] = []
        for tweak in DefaultsTweak.tweaks(in: group) where !seen.contains(tweak.restart) {
            seen.append(tweak.restart)
        }
        return seen
    }
}

private struct TweakRow: View {
    let tweak: DefaultsTweak

    @Environment(AppState.self) private var state

    var body: some View {
        let browser = state.defaultsBrowser
        let stored = browser.storedValue(of: tweak)

        CardRow {
            VStack(alignment: .leading, spacing: 3) {
                RowLabel(title: tweak.title, hint: tweak.hint)
                if case .toggle = tweak.control, stored != nil, !tweak.isOn(stored) {
                    Text("Set to \(stored?.summary ?? "") some other way.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .help("\(tweak.domain) \(tweak.key)")
        } trailing: {
            switch tweak.control {
            case .toggle(let value):
                RowSwitch(label: tweak.title, isOn: Binding(
                    get: { tweak.isOn(stored) },
                    set: { on in Task { await browser.apply(tweak, on ? value : nil) } }
                ))
            case .choice(let choices):
                Picker(tweak.title, selection: Binding(
                    get: { tweak.choice(for: stored) },
                    set: { choice in
                        guard let choice else { return }
                        Task { await browser.apply(tweak, choice.value) }
                    }
                )) {
                    ForEach(choices, id: \.self) { Text($0.title).tag(Optional($0)) }
                    if tweak.choice(for: stored) == nil {
                        Text(stored?.summary ?? "Other").tag(DefaultsTweak.Choice?.none)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .contextMenu {
            Button("Copy defaults write Command") {
                let value: DefaultsValue? = switch tweak.control {
                case .toggle(let value): value
                case .choice: stored
                }
                if let value { copy(DefaultsValue.writeCommand(domain: tweak.domain, key: tweak.key, value: value)) }
            }
            Button("Copy defaults delete Command") { copy(DefaultsValue.deleteCommand(domain: tweak.domain, key: tweak.key)) }
            Divider()
            Button("Open \(tweak.domain)") {
                Task { await browser.open(browser.domain(named: tweak.domain), filter: tweak.key) }
            }
        }
    }
}

// MARK: - Domains

private enum DomainFilter: String, CaseIterable, Identifiable {
    case all = "All", apps = "Apps", apple = "macOS"

    var id: Self { self }

    func includes(_ domain: DefaultsDomain) -> Bool {
        switch self {
        case .all: true
        case .apps: !domain.isApple
        case .apple: domain.isApple
        }
    }
}

private struct DomainList: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var filter = DomainFilter.all

    var body: some View {
        let browser = state.defaultsBrowser
        let query = search.trimmingCharacters(in: .whitespaces)
        let domains = browser.domains(matching: query).filter(filter.includes)
        let canOpenTyped = query.contains(".") && !query.contains(" ") && !browser.domains.contains { $0.id == query }

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            CardSection {
                CardRow {
                    TextField("Filter by app, domain or key", text: $search)
                        .textFieldStyle(.roundedBorder)
                } trailing: {
                    Picker("Show", selection: $filter) {
                        ForEach(DomainFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if canOpenTyped {
                    CardRow("Open “\(query)”", hint: "For an app that hasn't saved any settings yet.") {
                        Button("Open") { open(browser.domain(named: query), search: nil) }
                    }
                }
                CardRow {
                    Text("Apps from the App Store keep their settings in their own container, which macOS doesn't let other apps list without asking, so they aren't here. Type one's bundle ID above to open it; macOS may ask whether to allow it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    EmptyView()
                }
            }

            CardSection(browser.isLoaded ? "Domains · \(domains.count)" : "Domains") {
                if !browser.isLoaded {
                    CardRow { ProgressView().controlSize(.small) } trailing: { EmptyView() }
                } else if domains.isEmpty {
                    CardRow("No matches", hint: nil) { EmptyView() }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(domains) { domain in
                            let keys = query.isEmpty ? [] : browser.matchingKeys(in: domain, query)
                            Button {
                                open(domain, search: keys.isEmpty ? nil : query)
                            } label: {
                                DomainRow(domain: domain, matchingKeys: keys)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        // Each time the list shows, for domains added since, here or elsewhere.
        .task { await state.defaultsBrowser.loadDomains() }
    }

    private func open(_ domain: DefaultsDomain, search: String?) {
        Task { await state.defaultsBrowser.open(domain, filter: search ?? "") }
    }
}

private struct DomainRow: View {
    let domain: DefaultsDomain
    let matchingKeys: [String]

    var body: some View {
        CardRow {
            HStack(spacing: 10) {
                DomainIcon(domain: domain, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(domain.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        guard !matchingKeys.isEmpty else { return domain.isGlobal || domain.appName != nil ? domain.id : "" }
        let shown = matchingKeys.prefix(3).joined(separator: ", ")
        return matchingKeys.count > 3 ? "\(shown) and \(matchingKeys.count - 3) more" : shown
    }
}

private struct DomainIcon: View {
    let domain: DefaultsDomain
    let size: CGFloat

    var body: some View {
        Group {
            if let appURL = domain.appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
            } else {
                Image(systemName: domain.isGlobal ? "globe" : "doc.text")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - A domain

private struct DomainView: View {
    @Environment(AppState.self) private var state
    @State private var deleting: String?
    @State private var isRestoring = false

    var body: some View {
        @Bindable var browser = state.defaultsBrowser
        if let domain = browser.openDomain {
            let query = browser.keyFilter.trimmingCharacters(in: .whitespaces)
            let keys = browser.values.keys
                .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) || browser.values[$0]?.contains(query) == true }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
                Button {
                    browser.close()
                } label: {
                    Label("All domains", systemImage: "chevron.left")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)

                header(domain)

                CardSection("Keys · \(keys.count)") {
                    CardRow {
                        TextField("Filter by key or value", text: $browser.keyFilter)
                            .textFieldStyle(.roundedBorder)
                    } trailing: {
                        EmptyView()
                    }
                    ForEach(keys, id: \.self) { key in
                        if let value = browser.values[key] {
                            KeyRow(domain: domain, key: key, value: value, delete: { deleting = key })
                        }
                    }
                    if keys.isEmpty {
                        CardRow(browser.values.isEmpty ? "No settings saved" : "No matches", hint: nil) { EmptyView() }
                    }
                }

                CardSection("Add a key") {
                    AddKeyRow()
                }
            }
            .task(id: domain.id) { await browser.watch() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await browser.reload() }
            }
            .confirmationDialog("Delete “\(deleting ?? "")”?", isPresented: isDeleting) {
                Button("Delete", role: .destructive) {
                    guard let key = deleting else { return }
                    Task { await browser.delete(key) }
                }
            } message: {
                Text("\(domain.title) goes back to its default for it.")
            }
            .confirmationDialog("Restore \(domain.title) as it was?", isPresented: $isRestoring) {
                Button("Restore", role: .destructive) { Task { await browser.restoreBackup() } }
            } message: {
                Text("Keys added since are deleted, and changed ones get their old values back.")
            }
        }
    }

    @ViewBuilder
    private func header(_ domain: DefaultsDomain) -> some View {
        let browser = state.defaultsBrowser
        CardSection {
            CardRow {
                HStack(spacing: 12) {
                    DomainIcon(domain: domain, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(domain.title).font(.system(size: 13, weight: .medium))
                        Text(domain.id)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.secondaryText)
                            .textSelection(.enabled)
                    }
                }
            } trailing: {
                HStack(spacing: 10) {
                    Button {
                        copy(DefaultsValue.readCommand(domain: domain.id))
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy \(DefaultsValue.readCommand(domain: domain.id))")
                    if let file = domain.fileURL, FileManager.default.fileExists(atPath: file.path) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Show \(file.lastPathComponent) in Finder")
                    }
                }
            }

            if let app = browser.runningApp {
                CardRow {
                    Label("\(domain.title) is running. Apps read most settings when they open, and may save over a change when they quit.", systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } trailing: {
                    Button("Restart") { Task { await browser.restartApp() } }
                        .help("Quit \(app.localizedName ?? domain.title) and open it again")
                }
            } else if domain.isGlobal {
                CardRow {
                    Label("Every app reads these. Most pick up a change the next time they open.", systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                } trailing: {
                    EmptyView()
                }
            }

            if browser.hasBackup(domain), let backup = browser.backupURL(for: domain) {
                CardRow("Original settings", hint: "Saved before PowerToys first changed this domain.") {
                    HStack(spacing: 6) {
                        Button("Restore…") { isRestoring = true }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                    }
                }
            } else if browser.backupDirectory != nil {
                CardRow("Original settings", hint: "PowerToys saves a copy of this domain before its first change, so it can be put back.") {
                    EmptyView()
                }
            }

            if let error = browser.error {
                CardRow {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                } trailing: {
                    EmptyView()
                }
            }
        }
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

private struct KeyRow: View {
    let domain: DefaultsDomain
    let key: String
    let value: DefaultsValue
    let delete: () -> Void

    @Environment(AppState.self) private var state
    @State private var isExpanded = false

    var body: some View {
        let browser = state.defaultsBrowser
        VStack(spacing: 0) {
            CardRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text(key)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(key)
                    Text(value.kind.title)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.secondaryText)
                }
            } trailing: {
                HStack(spacing: 8) {
                    switch value {
                    case .bool(let isOn):
                        RowSwitch(label: key, isOn: Binding(
                            get: { isOn },
                            set: { on in Task { await browser.set(.bool(on), for: key) } }
                        ))
                    case .integer, .unsigned, .real, .string:
                        ValueField(value: value) { new in Task { await browser.set(new, for: key) } }
                    case .array, .dictionary:
                        Button {
                            isExpanded.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Text(value.summary)
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .disabled(value.children.isEmpty)
                    case .date, .data:
                        Text(value.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    Menu {
                        actions
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Options for \(key)")
                }
            }
            .contextMenu { actions }

            if isExpanded {
                ValueTree(value: value)
                    .padding(.leading, 28)
                    .padding(.trailing, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Palette.divider).frame(height: 1)
                    }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Copy Key") { copy(key) }
        Button("Copy Value") { copy(value.isEditable ? value.editableText : value.xmlFragment) }
        Divider()
        Button("Copy defaults write Command") { copy(DefaultsValue.writeCommand(domain: domain.id, key: key, value: value)) }
        Button("Copy defaults read Command") { copy(DefaultsValue.readCommand(domain: domain.id, key: key)) }
        Button("Copy defaults delete Command") { copy(DefaultsValue.deleteCommand(domain: domain.id, key: key)) }
        Divider()
        Button("Delete…", role: .destructive, action: delete)
    }
}

/// The value as text, which turns into a field when clicked. Return or clicking away saves,
/// Esc cancels, and text that isn't a value of the same kind is refused.
private struct ValueField: View {
    let value: DefaultsValue
    let commit: (DefaultsValue) -> Void

    @State private var text = ""
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("Value", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: value.kind == .string ? .default : .monospaced))
                .lineLimit(1...6)
                .frame(width: 240)
                .focused($isFocused)
                .onSubmit(save)
                .onExitCommand { isEditing = false }
                .onChange(of: isFocused) { if !isFocused { save() } }
                .onAppear { isFocused = true }
        } else {
            Button {
                text = value.editableText
                isEditing = true
            } label: {
                Text(value.summary.isEmpty ? "Empty" : value.summary)
                    .font(.system(size: 12, design: value.kind == .string ? .default : .monospaced))
                    .foregroundStyle(value.summary.isEmpty ? Palette.secondaryText : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .trailing)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("Click to change")
        }
    }

    private func save() {
        guard isEditing else { return }
        isEditing = false
        guard let new = DefaultsValue.parse(text, as: value.kind) else {
            NSSound.beep()
            return
        }
        if new != value { commit(new) }
    }
}

/// An array's items or a dictionary's entries, nested ones opening on a click. Read-only.
private struct ValueTree: View {
    let value: DefaultsValue

    static let limit = 200

    var body: some View {
        let children = value.children
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(children.prefix(Self.limit).enumerated()), id: \.offset) { _, child in
                TreeNode(label: child.label, value: child.value)
            }
            if children.count > Self.limit {
                Text("and \(children.count - Self.limit) more")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
    }
}

private struct TreeNode: View {
    let label: String
    let value: DefaultsValue

    @State private var isExpanded = false

    var body: some View {
        let isContainer = value.kind == .array || value.kind == .dictionary
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 10)
                    .opacity(isContainer && !value.children.isEmpty ? 1 : 0)
                Text(label)
                    .foregroundStyle(Palette.secondaryText)
                Text(value.summary)
                    .lineLimit(isContainer ? 1 : 3)
                    .textSelection(.enabled)
            }
            .font(.system(size: 11, design: .monospaced))
            .contentShape(Rectangle())
            .onTapGesture { if isContainer { isExpanded.toggle() } }

            if isExpanded {
                ValueTree(value: value).padding(.leading, 16)
            }
        }
    }
}

private struct AddKeyRow: View {
    @Environment(AppState.self) private var state
    @State private var key = ""
    @State private var kind = DefaultsValue.Kind.bool
    @State private var text = ""
    @State private var isOn = true

    var body: some View {
        CardRow {
            HStack(spacing: 8) {
                TextField("Key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Picker("Type", selection: $kind) {
                    ForEach(DefaultsValue.Kind.editable) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                if kind == .bool {
                    RowSwitch(label: "Value", isOn: $isOn)
                } else {
                    TextField("Value", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit(add)
                }
            }
        } trailing: {
            Button("Add", action: add)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let value = kind == .bool ? String(isOn) : text
        Task {
            if await state.defaultsBrowser.add(key, text: value, as: kind) {
                key = ""
                text = ""
            }
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.copy(text)
}
