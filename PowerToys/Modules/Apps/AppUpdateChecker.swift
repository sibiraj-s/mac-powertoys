import Foundation
import Observation

/// Checks the installed apps for newer versions when asked; nothing runs in the background, but a
/// check that has started finishes even if the page that asked closes.
@Observable
final class AppUpdateChecker {
    let list: InstalledAppList
    /// Each app's status by its ID. A new check replaces each as it finishes, so the last results
    /// stay until then.
    private(set) var statuses: [String: AppUpdates.Status] = [:]
    /// How many apps the check under way has done.
    private(set) var checkedCount = 0
    private(set) var isChecking = false
    private(set) var checkedAt: Date?

    @ObservationIgnored private let fetch: AppUpdates.Fetch
    @ObservationIgnored private let findBrew: @Sendable () -> String?
    @ObservationIgnored private let readInfo: @Sendable (URL) -> AppUpdates.AppInfo
    @ObservationIgnored private let readStoreUpdates: @Sendable () -> [String: AppUpdates.StoreUpdate]?
    @ObservationIgnored private let readStoreLastCheck: @Sendable () -> Date?
    @ObservationIgnored private var checking: Task<Void, Never>?

    /// Feeds are read this many at a time.
    static let parallelChecks = 8

    init(
        list: InstalledAppList,
        fetch: @escaping AppUpdates.Fetch = AppUpdateChecker.download,
        findBrew: @escaping @Sendable () -> String? = { AppUpdates.findBrew() },
        readInfo: @escaping @Sendable (URL) -> AppUpdates.AppInfo = { AppUpdates.AppInfo($0) },
        readStoreUpdates: @escaping @Sendable () -> [String: AppUpdates.StoreUpdate]? = {
            AppUpdates.storeUpdates(database: AppUpdates.storeDatabase(home: FileManager.default.homeDirectoryForCurrentUser))
        },
        readStoreLastCheck: @escaping @Sendable () -> Date? = { AppUpdates.storeLastCheck() }
    ) {
        self.list = list
        self.fetch = fetch
        self.findBrew = findBrew
        self.readInfo = readInfo
        self.readStoreUpdates = readStoreUpdates
        self.readStoreLastCheck = readStoreLastCheck
    }

    /// The newer version found for the app, if any.
    func update(for app: InstalledApp) -> AppUpdates.Found? {
        if case .available(let found) = statuses[app.id] { found } else { nil }
    }

    /// The apps with a newer version.
    var available: [InstalledApp] {
        list.apps.filter { update(for: $0) != nil }
    }

    /// Checks every app, or waits for the check under way. The check runs on its own task, so a
    /// caller that's cancelled, such as a page that closed, doesn't leave failed results behind.
    func check() async {
        if let checking { return await checking.value }
        let task = Task { await run() }
        checking = task
        isChecking = true
        await task.value
        checking = nil
        isChecking = false
    }

    private func run() async {
        checkedCount = 0
        await list.load()
        let apps = list.apps
        let catalog = await Self.catalog(
            for: apps, fetch: fetch, brew: findBrew(), storeUpdates: readStoreUpdates, storeLastCheck: readStoreLastCheck)
        let fetch = fetch
        let readInfo = readInfo
        var fresh: [String: AppUpdates.Status] = [:]
        await withTaskGroup(of: (String, AppUpdates.Status).self) { group in
            var pending = apps[...]
            func next() {
                guard let app = pending.popFirst() else { return }
                group.addTask { (app.id, await Self.status(of: app, catalog: catalog, fetch: fetch, readInfo: readInfo)) }
            }
            for _ in 0..<Self.parallelChecks { next() }
            for await (id, status) in group {
                fresh[id] = status
                statuses[id] = status
                checkedCount += 1
                next()
            }
        }
        // Apps gone since the last check drop out.
        statuses = fresh
        checkedAt = .now
    }

    @concurrent
    private nonisolated static func catalog(
        for apps: [InstalledApp], fetch: @escaping AppUpdates.Fetch, brew: String?,
        storeUpdates: @Sendable () -> [String: AppUpdates.StoreUpdate]?, storeLastCheck: @Sendable () -> Date?
    ) async -> AppUpdates.Catalog {
        // Listing casks runs beside the feed checks, which don't need it, and is waited for only
        // by apps without a feed that answers.
        let casks = Task { () -> [String: AppUpdates.Cask] in
            guard let brew else { return [:] }
            return await AppUpdates.installedCasks(brew: brew)
        }
        // The App Store's own list when it can be read, its public listing only otherwise.
        let pending = storeUpdates()
        let storeIDs = pending == nil ? apps.filter(\.isAppStore).map(\.bundleID) : []
        let store = storeIDs.isEmpty ? [:] : await AppUpdates.appStoreVersions(storeIDs, fetch: fetch)
        // Started only when an app needs it, then shared.
        let caskCatalog = Shared { await AppUpdates.caskCatalog(fetch: fetch) }
        var catalog = AppUpdates.Catalog(
            storeUpdates: pending, appStore: store, casks: { await casks.value }, caskCatalog: { await caskCatalog.value() })
        // The App Store fills its list only when it checks, which it can't while signed out.
        catalog.storeListIsStale = pending != nil && !AppUpdates.isRecent(storeLastCheck())
        return catalog
    }

    @concurrent
    private nonisolated static func status(
        of app: InstalledApp, catalog: AppUpdates.Catalog, fetch: AppUpdates.Fetch,
        readInfo: @Sendable (URL) -> AppUpdates.AppInfo
    ) async -> AppUpdates.Status {
        await AppUpdates.status(of: app, info: readInfo(app.url), catalog: catalog, fetch: fetch)
    }

    /// Reads a feed or lookup, failing on anything but a 200; a 204 fails as `.zeroByteResource`,
    /// which a service that answers no update with nothing can tell apart.
    @Sendable
    nonisolated static func download(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return data
        case 204: throw URLError(.zeroByteResource)
        default: throw URLError(.badServerResponse)
        }
    }
}

/// A value worked out once, the first time it's asked for, and shared by everyone who asks.
private actor Shared<Value: Sendable> {
    private let make: @Sendable () async -> Value
    private var task: Task<Value, Never>?

    init(_ make: @escaping @Sendable () async -> Value) {
        self.make = make
    }

    func value() async -> Value {
        if let task { return await task.value }
        let task = Task { await make() }
        self.task = task
        return await task.value
    }
}
