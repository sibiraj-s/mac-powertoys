import Foundation
import Observation

/// The apps in Applications folders, listed once and shared by uninstalling and update checks.
@Observable
final class InstalledAppList {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    @ObservationIgnored private let folders: [URL]
    /// The listing under way, which a second caller waits for rather than finding no apps.
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let readsDetails: Bool

    init(folders: [URL], readsDetails: Bool = true) {
        self.folders = folders
        self.readsDetails = readsDetails
    }

    /// Lists the apps once; `refresh` lists them again, as Spotlight sizes and measuring take a while.
    /// While a listing is under way, waits for it, then lists again for a refresh, as that one may
    /// have started before what's being looked for changed. It finishes even if the caller is
    /// cancelled.
    func load(refresh: Bool = false) async {
        if let loading {
            await loading.value
            guard refresh else { return }
            return await load(refresh: true)
        }
        guard refresh || !hasLoaded else { return }
        let folders = folders
        let readsDetails = readsDetails
        let task = Task {
            let listed = await Self.list(folders, readsDetails: readsDetails)
            // An app uninstalled while listing may have been listed before it went.
            apps = listed.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            hasLoaded = true
        }
        loading = task
        isLoading = true
        await task.value
        loading = nil
        isLoading = false
    }

    /// Takes an app out once it's been uninstalled.
    func remove(_ app: InstalledApp) {
        apps.removeAll { $0.id == app.id }
    }

    @concurrent
    private nonisolated static func list(_ folders: [URL], readsDetails: Bool) async -> [InstalledApp] {
        AppUninstall.list(in: folders, excluding: Bundle.main.bundleIdentifier, withDetails: readsDetails)
    }
}
