import AppKit
import Observation

/// Lists installed apps and uninstalls one with what it keeps in ~/Library, or only that data,
/// moving everything to the Trash.
@Observable
final class AppUninstaller {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    /// The app being looked at, what it has and what's unticked.
    private(set) var inspected: InstalledApp?
    private(set) var footprint: [CleanupItem] = []
    /// Looks under way; several can overlap, as when another app is opened before one finishes.
    private(set) var inspections = 0
    var isInspecting: Bool { inspections > 0 }
    private(set) var unticked: Set<String> = []

    private(set) var isRemoving = false
    private(set) var isQuitting = false
    /// What the last removal did, and whether anything stayed.
    private(set) var result: String?
    private(set) var resultIsError = false

    @ObservationIgnored private let home: URL
    @ObservationIgnored private let appFolders: [URL]
    @ObservationIgnored private let readActivity: @Sendable () async -> ActivitySnapshot
    @ObservationIgnored private let fullDiskAccess: () -> Bool
    @ObservationIgnored private let remover: AppUninstall.Remover
    @ObservationIgnored private let readsDetails: Bool

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        appFolders: [URL]? = nil,
        readActivity: @escaping @Sendable () async -> ActivitySnapshot = { await ActivitySnapshot.read() },
        fullDiskAccess: @escaping () -> Bool = { FullDiskAccess.isGranted() },
        remover: AppUninstall.Remover = AppUninstall.Remover(),
        readsDetails: Bool = true
    ) {
        self.home = home
        self.appFolders = appFolders ?? AppUninstall.appFolders(home: home)
        self.readActivity = readActivity
        self.fullDiskAccess = fullDiskAccess
        self.remover = remover
        self.readsDetails = readsDetails
    }

    /// Lists the apps once; `refresh` lists them again, as Spotlight sizes and measuring take a while.
    func load(refresh: Bool = false) async {
        guard !isLoading, refresh || !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        apps = await Self.list(appFolders, readsDetails: readsDetails)
        hasLoaded = true
    }

    @concurrent
    private nonisolated static func list(_ folders: [URL], readsDetails: Bool) async -> [InstalledApp] {
        AppUninstall.list(in: folders, excluding: Bundle.main.bundleIdentifier, withDetails: readsDetails)
    }

    // MARK: One app

    /// Lists what the app has, everything removable ticked but folders only named like the app.
    func inspect(_ app: InstalledApp) async {
        guard !isRemoving, !isQuitting else { return }
        inspected = app
        result = nil
        footprint = []
        unticked = []
        await refreshFootprint()
    }

    /// Back to the list; not while removing or quitting, which act on the app shown.
    func close() {
        guard !isRemoving, !isQuitting else { return }
        inspected = nil
        footprint = []
        unticked = []
    }

    private func refreshFootprint() async {
        guard let app = inspected else { return }
        inspections += 1
        defer { inspections -= 1 }
        let context = await context(for: app)
        let items = await Self.footprint(app, context: context)
        // Another app may have been opened meanwhile.
        guard inspected == app else { return }
        // Folders only named like the app start unticked, also ones that appear later, such as
        // after the app quits.
        let known = Set(footprint.map(\.id))
        unticked.formUnion(items.filter { !known.contains($0.id) && AppUninstall.isNamedLikeApp($0, app) }.map(\.id))
        footprint = items
    }

    @concurrent
    private nonisolated static func footprint(_ app: InstalledApp, context: AppUninstall.Context) async -> [CleanupItem] {
        AppUninstall.footprint(of: app, context: context)
    }

    private func context(for app: InstalledApp) async -> AppUninstall.Context {
        AppUninstall.Context(
            home: home, activity: await readActivity(), canChangeAppContainers: fullDiskAccess(),
            otherApps: apps.filter { $0.id != app.id }, otherCopyIDs: otherCopies(of: app).isEmpty ? [] : [app.bundleID],
            bundleProcesses: await processes(app.url))
    }

    func willRemove(_ item: CleanupItem) -> Bool {
        item.skipReason == nil && !unticked.contains(item.id)
    }

    func setWillRemove(_ willRemove: Bool, _ item: CleanupItem) {
        guard item.skipReason == nil else { return }
        if willRemove { unticked.remove(item.id) } else { unticked.insert(item.id) }
    }

    /// What removing would take now.
    var chosen: [CleanupItem] { footprint.filter(willRemove) }
    var chosenSize: Int64 { chosen.reduce(0) { $0 + $1.size } }
    /// Whether the app itself goes, rather than only its data.
    var removesApp: Bool { footprint.first.map(willRemove) ?? false }

    /// Whether the app is open, so it has to quit first.
    var appIsOpen: Bool { footprint.first?.skipReason == AppUninstall.openReason }

    /// Quits the app: first stops this user's launch agents that would start it again, then asks
    /// the app to quit, as from its menu, so it can offer to save, and only once it has, stops
    /// what else runs from its bundle, such as extensions that run while it's closed. Then looks
    /// again.
    func quitInspectedApp() async {
        guard let app = inspected, !isQuitting else { return }
        isQuitting = true
        defer { isQuitting = false }
        for agent in await Self.launchAgents(runningFrom: app, home: home) { _ = await remover.unloadAgent(agent) }
        // This copy only, not another with the same ID.
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .filter { $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL }
        for instance in instances { instance.terminate() }
        // An app can stop to ask about saving, so it's waited for a while, not for good; its
        // helpers keep running meanwhile, as its windows may need them.
        for _ in 0..<20 where instances.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if instances.allSatisfy(\.isTerminated) {
            for process in await processes(app.url) where process.isMine { kill(process.pid, SIGTERM) }
            for _ in 0..<10 {
                if await !processes(app.url).contains(where: \.isMine) { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        await refreshFootprint()
    }

    private func processes(_ bundle: URL) async -> [AppUninstall.BundleProcess] {
        await Self.processes(runningFrom: bundle)
    }

    @concurrent
    private nonisolated static func processes(runningFrom bundle: URL) async -> [AppUninstall.BundleProcess] {
        AppUninstall.processes(runningFrom: bundle)
    }

    @concurrent
    private nonisolated static func launchAgents(runningFrom app: InstalledApp, home: URL) async -> [URL] {
        AppUninstall.launchAgents(runningFrom: app, home: home)
    }

    /// Other copies of the app Launch Services knows, wherever they are, leaving out ones in the
    /// Trash or deleted since.
    private func otherCopies(of app: InstalledApp) -> [URL] {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: app.bundleID).filter { url in
            let path = url.standardizedFileURL.path
            return path != app.url.standardizedFileURL.path && !path.contains("/.Trash/")
                && InstalledApps.isPresent(url)
        }
    }

    /// Moves what's ticked to the Trash. When the app went, it leaves the list and the view goes
    /// back to it.
    func remove() async {
        guard let app = inspected, !isRemoving else { return }
        let chosen = chosen
        guard !chosen.isEmpty else { return }
        isRemoving = true
        defer { isRemoving = false }
        let context = await context(for: app)
        let removal = await AppUninstall.remove(
            app, reviewed: Set(chosen.map(\.id)), sizes: Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0.size) }),
            context: context, remover: remover)
        result = Self.summary(removal, app: app)
        resultIsError = !removal.failures.isEmpty
        if removal.removedApp { apps.removeAll { $0.id == app.id } }
        // Going back and opening another app is blocked while removing, but checked anyway.
        guard inspected == app else { return }
        if removal.removedApp {
            inspected = nil
            footprint = []
            unticked = []
        } else {
            await refreshFootprint()
        }
    }

    func dismissResult() {
        result = nil
    }

    static func summary(_ removal: AppUninstall.Removal, app: InstalledApp) -> String {
        var parts: [String] = []
        let size = CleanerController.format(removal.trashed)
        let items = removal.removedItems == 1 ? "1 item" : "\(removal.removedItems) items"
        if removal.removedApp {
            parts.append(
                removal.removedItems > 0
                    ? "Moved \(app.name) and \(items) of its data, \(size), to the Trash."
                    : "Moved \(app.name), \(size), to the Trash.")
        } else if removal.removedItems > 0 {
            parts.append("Moved \(items) of \(app.name)'s data, \(size), to the Trash.")
        }
        if !removal.failures.isEmpty {
            if parts.isEmpty { parts.append("Nothing was removed.") }
            parts.append("Couldn't remove \(removal.failures.joined(separator: "; ")).")
        }
        return parts.joined(separator: " ")
    }
}
