import AppKit
import SwiftUI

/// The Cleaner row that opens the list of apps to uninstall.
struct UninstallAppsRow: View {
    @Environment(AppState.self) private var state
    @State private var isShowingApps = false

    var body: some View {
        let uninstaller = state.cleaner.uninstaller
        CardRow {
            HStack(spacing: 12) {
                SymbolTile(symbol: "trash.square")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall apps").font(.system(size: 13))
                    Text("Remove an app with its settings, caches and data, or only its data. Everything goes to the Trash.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
        } trailing: {
            HStack(spacing: 10) {
                if uninstaller.hasLoaded {
                    Text("\(uninstaller.apps.count) apps")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Palette.secondaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isShowingApps = true }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Uninstall apps")
        .sheet(isPresented: $isShowingApps) {
            UninstallAppsSheet()
        }
    }
}

private enum AppSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case lastOpened = "Last opened"

    var id: Self { self }
}

/// Installed apps, then one app's bundle and data with a checkbox each.
private struct UninstallAppsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var sort = AppSort.name
    @State private var confirming = false

    var body: some View {
        let uninstaller = state.cleaner.uninstaller
        VStack(alignment: .leading, spacing: 0) {
            if let app = uninstaller.inspected {
                detail(app, uninstaller)
            } else {
                list(uninstaller)
            }
        }
        .frame(width: 560, height: 520)
        .task { await uninstaller.load() }
        .onDisappear {
            uninstaller.close()
            uninstaller.dismissResult()
        }
    }

    // MARK: List

    @ViewBuilder
    private func list(_ uninstaller: AppUninstaller) -> some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: "trash.square", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Uninstall apps").font(.system(size: 14, weight: .semibold))
                Text("Apps in Applications folders. Parts of macOS can't be removed.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer()
            if uninstaller.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(16)

        resultBanner(uninstaller)

        HStack(spacing: 10) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            Picker("Sort by", selection: $sort) {
                ForEach(AppSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)

        Divider()
        let apps = shown(uninstaller.apps)
        if apps.isEmpty {
            Text(uninstaller.isLoading ? "Finding apps…" : query.isEmpty ? "No apps found." : "No matching apps.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let largest = apps.compactMap(\.size).max() ?? 0
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(apps) { app in
                        AppListRow(app: app, largest: largest) {
                            Task { await uninstaller.inspect(app) }
                        }
                    }
                }
            }
        }
        Divider()
        HStack {
            Text("\(apps.count) apps")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Palette.secondaryText)
            Spacer()
            Button("Refresh") { Task { await uninstaller.load(refresh: true) } }
                .disabled(uninstaller.isLoading)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func shown(_ apps: [InstalledApp]) -> [InstalledApp] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let matching =
            query.isEmpty
            ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .name: return matching
        case .size: return matching.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        // Never opened first, then the longest ago: the likeliest to be forgotten.
        case .lastOpened: return matching.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    // MARK: One app

    @ViewBuilder
    private func detail(_ app: InstalledApp, _ uninstaller: AppUninstaller) -> some View {
        let items = uninstaller.footprint
        let removable = items.filter { $0.skipReason == nil }
        let chosen = uninstaller.chosen
        let busy = uninstaller.isInspecting || uninstaller.isRemoving || uninstaller.isQuitting

        HStack(spacing: 12) {
            Button {
                uninstaller.close()
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("All apps")
            .accessibilityLabel("All apps")
            .keyboardShortcut(.cancelAction)
            .disabled(uninstaller.isRemoving)
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

/// An app: icon, name, version, when it was last opened and its size. Clicking it opens it.
private struct AppListRow: View {
    let app: InstalledApp
    let largest: Int64
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name).lineLimit(1)
                    if app.isAppStore { Tag(text: "App Store") }
                }
                Text(lastOpened)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 8)
            Text(app.size.map(CleanerController.format) ?? "—")
                .monospacedDigit()
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 64, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.secondaryText)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .help(app.url.path)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider).frame(height: 1)
        }
    }

    private var lastOpened: String {
        guard let date = app.lastUsed else { return "Not opened recently" }
        return "Opened \(date.formatted(.relative(presentation: .named)))"
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
