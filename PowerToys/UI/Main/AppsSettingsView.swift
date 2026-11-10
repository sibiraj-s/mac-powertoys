import AppKit
import SwiftUI

/// The Apps module: every installed app in one list, each with its size, an Uninstall button, and
/// an Update button when a newer version was found.
struct AppsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var query = ""
    @State private var sort = AppSort.name
    @State private var filter = AppFilter.all
    /// Said after an update button that copies a command rather than opening something.
    @State private var copied: String?

    var body: some View {
        let list = state.apps.list
        let uninstaller = state.apps.uninstaller
        let updates = state.apps.updates

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Picker("Show", selection: $filter) {
                    Text("All").tag(AppFilter.all)
                    Text(updates.available.isEmpty ? "Updates" : "Updates · \(updates.available.count)").tag(AppFilter.updates)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Sort by", selection: $sort) {
                    ForEach(AppSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Spacer()
                if list.isLoading || updates.isChecking { ProgressView().controlSize(.small) }
                Menu {
                    Button("Check for Updates") { Task { await updates.check() } }
                        .disabled(updates.isChecking)
                    Button("Refresh List") { Task { await list.load(refresh: true) } }
                        .disabled(list.isLoading)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Check for updates or list the apps again")
            }
            .controlSize(.small)

            Text(status(list, updates))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.secondaryText)

            if let result = uninstaller.result, uninstaller.inspected == nil {
                MessageBanner(message: result, isError: uninstaller.resultIsError, dismiss: { uninstaller.dismissResult() })
            }
            if let copied {
                MessageBanner(message: copied, isError: false, dismiss: { self.copied = nil })
            }

            let apps = shown(list.apps, updates)
            CardSection {
                if apps.isEmpty {
                    Text(emptyText(list, updates))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(apps) { app in
                            AppRow(
                                app: app, update: updates.update(for: app),
                                isBusy: uninstaller.isRemoving || uninstaller.isQuitting,
                                uninstall: { Task { await uninstaller.inspect(app) } },
                                onUpdate: { found in update(app, found) })
                        }
                    }
                }
            }
        }
        // Only while the module is on; turning it on starts the first check.
        .task(id: state.isEnabled(.apps)) {
            guard state.isEnabled(.apps) else { return }
            await list.load()
            if updates.checkedAt == nil { await updates.check() }
        }
        .sheet(
            isPresented: Binding(get: { uninstaller.inspected != nil }, set: { if !$0 { uninstaller.close() } })
        ) {
            UninstallSheet()
        }
    }

    private func status(_ list: InstalledAppList, _ updates: AppUpdateChecker) -> String {
        guard list.hasLoaded else { return state.isEnabled(.apps) ? "Finding apps…" : "Turn on Apps to list your apps." }
        let count = list.apps.count == 1 ? "1 app" : "\(list.apps.count) apps"
        if updates.isChecking { return "\(count) · Checking for updates, \(updates.checkedCount) of \(list.apps.count)…" }
        guard let checkedAt = updates.checkedAt else { return count }
        let found = updates.available.count
        let summary = found == 0 ? "no updates found" : found == 1 ? "1 update" : "\(found) updates"
        return "\(count) · \(summary), checked \(checkedAt.formatted(.relative(presentation: .named)))"
    }

    private func emptyText(_ list: InstalledAppList, _ updates: AppUpdateChecker) -> String {
        if !list.hasLoaded { return state.isEnabled(.apps) ? "Finding apps…" : "Turn on Apps to list your apps." }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "No matching apps." }
        if filter == .updates { return updates.isChecking ? "Checking for updates…" : "No updates found." }
        return "No apps found."
    }

    private func shown(_ apps: [InstalledApp], _ updates: AppUpdateChecker) -> [InstalledApp] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let matching = apps.filter { app in
            (filter == .all || updates.update(for: app) != nil)
                && (query.isEmpty || app.name.localizedCaseInsensitiveContains(query)
                    || app.bundleID.localizedCaseInsensitiveContains(query))
        }
        switch sort {
        case .name: return matching
        case .size: return matching.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        // Never opened first, then the longest ago: the likeliest to be forgotten.
        case .lastOpened: return matching.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    /// Where to get the update: the App Store page, the app itself, which installs from its feed,
    /// or Homebrew's command, copied.
    private func update(_ app: InstalledApp, _ found: AppUpdates.Found) {
        switch found.source {
        case .appStore(let page):
            NSWorkspace.shared.open(page)
        case .feed:
            NSWorkspace.shared.open(app.url)
        case .homebrew(let cask):
            let command = "brew upgrade --cask \(cask)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = "Copied “\(command)”. Run it in Terminal to update \(app.name)."
        }
    }
}

private enum AppSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case lastOpened = "Last opened"

    var id: Self { self }
}

private enum AppFilter: Hashable {
    case all, updates
}

/// An app: icon, name, version and when it was last opened, then an Update button when there's
/// a newer version, its size, and Uninstall.
private struct AppRow: View {
    let app: InstalledApp
    let update: AppUpdates.Found?
    let isBusy: Bool
    let uninstall: () -> Void
    let onUpdate: (AppUpdates.Found) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name).lineLimit(1)
                    if app.isAppStore { Tag(text: "App Store") }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            .help(app.url.path)
            Spacer(minLength: 8)
            if let update {
                Button(update.latest.isEmpty || update.latest == update.installed ? "Update" : "Update to \(update.latest)") {
                    onUpdate(update)
                }
                .buttonStyle(.borderedProminent)
                .help(updateHelp(update))
            }
            Text(app.size.map(CleanerController.format) ?? "—")
                .monospacedDigit()
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 64, alignment: .trailing)
            Button("Uninstall…", action: uninstall)
                .disabled(isBusy)
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider).frame(height: 1)
        }
    }

    private var subtitle: String {
        let version = (update?.installed ?? app.version).map { "Version \($0)" }
        let opened = app.lastUsed.map { "Opened \($0.formatted(.relative(presentation: .named)))" } ?? "Not opened recently"
        return [version, opened].compactMap(\.self).joined(separator: " · ")
    }

    private func updateHelp(_ found: AppUpdates.Found) -> String {
        switch found.source {
        case .appStore: "Open \(app.name) in the App Store"
        case .feed: "Open \(app.name), then use its Check for Updates"
        case .homebrew(let cask): "Copy brew upgrade --cask \(cask)"
        }
    }
}

/// One app's bundle and data with a checkbox each, to uninstall it or remove only its data.
private struct UninstallSheet: View {
    @Environment(AppState.self) private var state
    @State private var confirming = false

    var body: some View {
        let uninstaller = state.apps.uninstaller
        VStack(alignment: .leading, spacing: 0) {
            if let app = uninstaller.inspected {
                detail(app, uninstaller)
            }
        }
        .frame(width: 560, height: 480)
        .interactiveDismissDisabled(uninstaller.isRemoving || uninstaller.isQuitting)
    }

    @ViewBuilder
    private func detail(_ app: InstalledApp, _ uninstaller: AppUninstaller) -> some View {
        let items = uninstaller.footprint
        let removable = items.filter { $0.skipReason == nil }
        let chosen = uninstaller.chosen
        let busy = uninstaller.isInspecting || uninstaller.isRemoving || uninstaller.isQuitting

        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 14, weight: .semibold))
                Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap(\.self).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Text(CleanerController.format(uninstaller.chosenSize))
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
        }
        .padding(16)

        resultBanner(uninstaller)

        if uninstaller.appIsOpen {
            notice(
                symbol: "app.badge", tint: .orange,
                text:
                    "\(app.name), or a part of it such as a widget or notification extension, is running. Quit it to remove it and its data."
            ) {
                Button("Quit \(app.name)") { Task { await uninstaller.quitInspectedApp() } }
                    .controlSize(.small)
                    .disabled(uninstaller.isQuitting)
            }
        } else if items.contains(where: { $0.skipReason == AppLeftovers.needsFullDiskAccess }) {
            notice(
                symbol: "lock.shield", tint: .orange,
                text: "macOS only lets apps with Full Disk Access remove other apps' containers. Grant it, then look again."
            ) {
                Button("Open Settings") { state.permissions.openSettings(for: .fullDiskAccess) }
                    .controlSize(.small)
            }
        }

        HStack(spacing: 10) {
            Text("Item")
            Spacer()
            Text("Size").frame(width: 64, alignment: .trailing)
            Color.clear.frame(width: 16, height: 1)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Palette.sidebar.opacity(0.6))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }

        if items.isEmpty {
            Text(uninstaller.isInspecting ? "Looking for \(app.name)'s files…" : "Nothing found.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        FootprintRow(
                            item: item, uninstaller: uninstaller, isNamedLikeApp: AppUninstall.isNamedLikeApp(item, app))
                    }
                }
            }
        }

        Divider()
        HStack(spacing: 10) {
            Text("\(chosen.count) of \(removable.count) selected")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Palette.secondaryText)
            Spacer()
            Button("Cancel") { uninstaller.close() }
                .keyboardShortcut(.cancelAction)
                .disabled(uninstaller.isRemoving || uninstaller.isQuitting)
            Button(uninstaller.removesApp ? "Uninstall…" : "Remove Data…", role: .destructive) { confirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || chosen.isEmpty)
        }
        .padding(12)
        .confirmationDialog(confirmTitle(app, uninstaller), isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { Task { await uninstaller.remove() } }
        } message: {
            Text(
                app.isAppStore && uninstaller.removesApp
                    ? "Everything ticked goes to the Trash, where it can be put back. Finder may ask for your password to remove an App Store app."
                    : "Everything ticked goes to the Trash, where it can be put back.")
        }
    }

    private func confirmTitle(_ app: InstalledApp, _ uninstaller: AppUninstaller) -> String {
        let size = CleanerController.format(uninstaller.chosenSize)
        return uninstaller.removesApp ? "Uninstall \(app.name) (\(size))?" : "Remove \(size) of \(app.name)'s data?"
    }

    // MARK: Pieces

    @ViewBuilder
    private func resultBanner(_ uninstaller: AppUninstaller) -> some View {
        if let result = uninstaller.result {
            MessageBanner(message: result, isError: uninstaller.resultIsError, dismiss: { uninstaller.dismissResult() })
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private func notice<Action: View>(
        symbol: String, tint: Color, text: String, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

/// The app's bundle or one of its data folders: a checkbox when it can go, or a lock and why not.
private struct FootprintRow: View {
    let item: CleanupItem
    let uninstaller: AppUninstaller
    let isNamedLikeApp: Bool

    var body: some View {
        let willRemove = uninstaller.willRemove(item)
        HStack(spacing: 10) {
            if item.skipReason == nil {
                Toggle(item.name, isOn: Binding(get: { willRemove }, set: { uninstaller.setWillRemove($0, item) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 10))
                    .frame(width: 14)
            }
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.url?.path ?? item.name)
            Spacer(minLength: 8)
            if let reason = item.skipReason {
                Tag(text: reason)
            } else if isNamedLikeApp {
                Tag(text: "Matched by name")
                    .help("Named like the app rather than by its ID, so it could be another tool's. Look before ticking it.")
            }
            Text(CleanerController.format(item.size))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Button {
                if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .frame(width: 16)
        }
        .font(.system(size: 12))
        .foregroundStyle(willRemove ? Color.primary : Palette.secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider).frame(height: 1)
        }
    }
}
