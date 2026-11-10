import AppKit
import Synchronization

/// An app in an Applications folder, which can be uninstalled with what it keeps in ~/Library.
nonisolated struct InstalledApp: Identifiable, Hashable, Sendable {
    let url: URL
    let bundleID: String
    /// As Finder shows it: the bundle's name without ".app".
    let name: String
    let version: String?
    /// From the App Store, whose bundles belong to the system, so Finder asks for a password to
    /// remove one.
    let isAppStore: Bool
    var size: Int64?
    var lastUsed: Date?

    var id: String { url.path }
}

/// Finds installed apps and everything of theirs in ~/Library, and moves what's chosen to the
/// Trash, so an uninstall can be undone from there.
nonisolated enum AppUninstall {
    static func appFolders(home: URL) -> [URL] {
        [URL(filePath: "/Applications", directoryHint: .isDirectory), home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    // MARK: Listing

    /// Apps in the folders and in folders inside them, such as Utilities or a vendor's suite, by
    /// name. Links, parts of macOS and `excluding`, this app, are left out.
    static func list(in folders: [URL], excluding ownID: String?, withDetails: Bool = true) -> [InstalledApp] {
        let files = FileManager.default
        var urls: [URL] = []
        for folder in folders {
            for item in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if item.pathExtension == "app" {
                    urls.append(item)
                } else if !isLink(item) {
                    let inner = (try? files.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                    urls.append(contentsOf: inner.filter { $0.pathExtension == "app" })
                }
            }
        }
        var seen: Set<String> = []
        var apps = urls.compactMap { url -> InstalledApp? in
            guard !isLink(url), !isRestricted(url), seen.insert(url.standardizedFileURL.path).inserted,
                let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")),
                let id = info["CFBundleIdentifier"] as? String, !id.isEmpty, id != ownID
            else { return nil }
            return InstalledApp(
                url: url, bundleID: id, name: url.deletingPathExtension().lastPathComponent,
                version: info["CFBundleShortVersionString"] as? String,
                isAppStore: files.fileExists(atPath: url.appending(path: "Contents/_MASReceipt/receipt").path))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard withDetails else { return apps }
        // All at once, since an app Spotlight hasn't sized is measured file by file.
        let details = Mutex([(size: Int64?, lastUsed: Date?)](repeating: (nil, nil), count: apps.count))
        let bundles = apps.map(\.url)
        DispatchQueue.concurrentPerform(iterations: bundles.count) { index in
            let found = Self.details(bundles[index])
            details.withLock { $0[index] = found }
        }
        for (index, found) in details.withLock({ $0 }).enumerated() {
            apps[index].size = found.size
            apps[index].lastUsed = found.lastUsed
        }
        return apps
    }

    /// Spotlight's size and last-opened date, measured when Spotlight doesn't know the size.
    static func details(_ url: URL) -> (size: Int64?, lastUsed: Date?) {
        let item = MDItemCreateWithURL(nil, url as CFURL)
        let size = item.flatMap { MDItemCopyAttribute($0, "kMDItemPhysicalSize" as CFString) as? NSNumber }?.int64Value
        let lastUsed = item.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        return (size ?? Cleanup.measure(url, volume: Cleanup.volumeID(url)).size, lastUsed)
    }

    static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Whether System Integrity Protection guards it, as it does Safari in /Applications.
    static func isRestricted(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_RESTRICTED) != 0
    }

    // MARK: Footprint

    static let appKind = "App"
    static let openReason = "App is open"
    static let openForAnotherUserReason = "Open for another user"

    /// A process whose program is inside an app bundle, and whether it's this user's, which only
    /// this user can quit.
    struct BundleProcess: Sendable, Hashable {
        let pid: pid_t
        let isMine: Bool
    }

    /// Every user's processes whose program is inside the bundle: the app itself, its helpers and
    /// its extensions. The one check of whether an app runs, so what's shown as open is what
    /// quitting can stop.
    static func processes(runningFrom bundle: URL) -> [BundleProcess] {
        let prefix = bundle.standardizedFileURL.path.lowercased() + "/"
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(max(0, found))).compactMap { pid in
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard pid > 0, pid != getpid(), length > 0,
                String(decoding: path.prefix(Int(length)), as: UTF8.self).lowercased().hasPrefix(prefix)
            else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            // A process whose owner can't be read counts as someone else's, so it isn't signalled.
            let isMine = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == getuid()
            return BundleProcess(pid: pid, isMine: isMine)
        }
    }

    static let launchAgentKind = "Launch agent"

    /// Where an app keeps its data in ~/Library by its ID: what leftovers look in, plus caches and
    /// logs, which an uninstall takes too.
    static let places: [(kind: String, folder: String, suffix: String)] =
        AppLeftovers.places + [("Caches", "Caches", ""), ("Logs", "Logs", ""), ("Cookies", "Cookies", ".binarycookies")]

    /// Folders apps that aren't sandboxed often name after themselves rather than their ID.
    static let namedFolders: [(kind: String, folder: String)] = [
        ("App data", "Application Support"), ("Caches", "Caches"), ("Logs", "Logs"),
    ]

    /// Kinds macOS guards from other apps unless they have Full Disk Access.
    static let containerKinds: Set<String> = ["Container", "Shared container"]

    struct Context: Sendable {
        var home: URL
        var activity: ActivitySnapshot
        var canChangeAppContainers = true
        /// Names of the other installed apps, lowercased, whose folders named like this app's
        /// aren't taken.
        var otherAppNames: Set<String> = []
        /// IDs of the other installed apps, lowercased. Data named by an ID another copy has, such
        /// as Xcode-beta's, which Xcode shares, isn't taken.
        var otherAppIDs: Set<String> = []
        /// What runs from the app's bundle, from `processes(runningFrom:)`.
        var bundleProcesses: [BundleProcess] = []

        /// `otherCopyIDs` adds IDs of copies outside the listed folders, such as in Downloads or on
        /// another disk, which Launch Services knows.
        init(
            home: URL, activity: ActivitySnapshot, canChangeAppContainers: Bool = true, otherApps: [InstalledApp] = [],
            otherCopyIDs: [String] = [], bundleProcesses: [BundleProcess] = []
        ) {
            self.home = home
            self.activity = activity
            self.canChangeAppContainers = canChangeAppContainers
            otherAppNames = Set(otherApps.map { $0.name.lowercased() })
            otherAppIDs = Set((otherApps.map(\.bundleID) + otherCopyIDs).map { $0.lowercased() })
            self.bundleProcesses = bundleProcesses
        }
    }

    /// Whether the item is a folder named like the app rather than by its ID: likely the app's,
    /// but possibly another tool's of the same name, so it's left unticked.
    static func isNamedLikeApp(_ item: CleanupItem, _ app: InstalledApp) -> Bool {
        guard let url = item.url, url.lastPathComponent == app.name else { return false }
        let folder = url.deletingLastPathComponent().lastPathComponent
        return namedFolders.contains { $0.folder == folder }
    }

    /// The app's bundle first, then its data, largest first, each with why it's left alone, if it is.
    static func footprint(of app: InstalledApp, context: Context) -> [CleanupItem] {
        let activity = context.activity
        var appReason: String?
        // By where it runs from, not its ID: another copy with the same ID, or another app's
        // helper, doesn't make this one open. Its own extensions do, such as a notification
        // extension that runs while the app is closed.
        if context.bundleProcesses.contains(where: \.isMine) {
            appReason = openReason
        } else if !context.bundleProcesses.isEmpty {
            appReason = openForAnotherUserReason
        }

        var bundleReason = appReason
        if bundleReason == nil, isLink(app.url) { bundleReason = "Linked elsewhere" }
        if bundleReason == nil, isRestricted(app.url) { bundleReason = Cleanup.protectedByMacOS }
        if bundleReason == nil, !FileManager.default.fileExists(atPath: app.url.path) { bundleReason = "Already removed" }
        if bundleReason == nil { bundleReason = inUseReason(app.url, activity) }
        let bundle = CleanupItem(
            id: app.url.path, name: "\(appKind) · \(app.url.lastPathComponent)", url: app.url,
            size: app.size ?? Cleanup.measure(app.url, volume: Cleanup.volumeID(app.url)).size, skipReason: bundleReason)

        let mounts = Cleanup.mountPaths()
        var data: [CleanupItem] = []
        for (kind, url) in dataLocations(of: app, context: context) {
            let folderVolume = Cleanup.volumeID(url.deletingLastPathComponent())
            let measured = Cleanup.measure(url, volume: folderVolume)
            var reason = Cleanup.reason(toKeep: url.deletingLastPathComponent(), home: context.home) ?? appReason
            if reason == nil { reason = Cleanup.diskReason(url, folderVolume: folderVolume, mounts: mounts) }
            if reason == nil, !context.canChangeAppContainers, containerKinds.contains(kind) {
                reason = AppLeftovers.needsFullDiskAccess
            }
            if reason == nil, Cleanup.isProtectedByMacOS(url) { reason = Cleanup.protectedByMacOS }
            if reason == nil, measured.readOnly { reason = Cleanup.readOnlyReason }
            if reason == nil { reason = inUseReason(url, activity) }
            data.append(
                CleanupItem(
                    id: url.path, name: "\(kind) · \(url.lastPathComponent)", url: url, size: measured.size,
                    skipReason: reason))
        }
        return [bundle] + data.sorted { $0.size > $1.size }
    }

    private static func inUseReason(_ url: URL, _ activity: ActivitySnapshot) -> String? {
        switch activity.isOpen(url) {
        case true?: "In use"
        case nil: Cleanup.unknownUse
        case false?: nil
        }
    }

    /// What's in ~/Library for the app: folders named by its ID, shared containers named by it,
    /// folders named like the app, and launch agents with its ID or that run something in it.
    static func dataLocations(of app: InstalledApp, context: Context) -> [(kind: String, url: URL)] {
        let files = FileManager.default
        let library = context.home.appending(path: "Library", directoryHint: .isDirectory)
        let id = app.bundleID
        var found: [(kind: String, url: URL)] = []
        var seen: Set<String> = []
        func add(_ kind: String, _ url: URL) {
            guard files.fileExists(atPath: url.path) || isLink(url),
                seen.insert(url.standardizedFileURL.path.lowercased()).inserted
            else { return }
            found.append((kind, url))
        }

        // Another copy with the same ID uses the same folders, so only what runs from this one goes.
        let idIsShared = context.otherAppIDs.contains(id.lowercased())
        if !idIsShared {
            for place in places {
                add(place.kind, library.appending(path: "\(place.folder)/\(id)\(place.suffix)"))
            }
            // Shared containers are named group.<ID> or <team ID>.<ID>; only exact names are
            // taken, since another app of the developer's can share one under its own name.
            let groups = library.appending(path: "Group Containers")
            for name in (try? files.contentsOfDirectory(atPath: groups.path)) ?? [] where isSharedContainer(name, of: id) {
                add("Shared container", groups.appending(path: name))
            }
        }
        // Not when another app has the same name, or the name is too short to say much.
        if app.name.count >= 3, !context.otherAppNames.contains(app.name.lowercased()) {
            for place in namedFolders {
                add(place.kind, library.appending(path: "\(place.folder)/\(app.name)"))
            }
        }
        let agents = library.appending(path: "LaunchAgents")
        for name in (try? files.contentsOfDirectory(atPath: agents.path)) ?? [] where name.hasSuffix(".plist") {
            let url = agents.appending(path: name)
            if launchAgent(at: url, belongsTo: app, matchingID: !idIsShared) { add(launchAgentKind, url) }
        }
        return found
    }

    static func isSharedContainer(_ name: String, of id: String) -> Bool {
        let lowered = name.lowercased()
        let id = id.lowercased()
        if lowered == "group.\(id)" { return true }
        return AppLeftovers.startsWithTeamID(name) && lowered.dropFirst(11) == id
    }

    /// Whether the agent runs something inside the app, or its label is exactly the app's ID.
    /// Labels that only start with the ID aren't enough: com.google.Chrome.canary.* is another app's.
    static func launchAgent(at url: URL, belongsTo app: InstalledApp, matchingID: Bool = true) -> Bool {
        guard let plist = NSDictionary(contentsOf: url) else { return false }
        if matchingID, (plist["Label"] as? String)?.lowercased() == app.bundleID.lowercased() { return true }
        return launchAgent(plist, runsFrom: app)
    }

    /// Whether the agent's program or any of its arguments, such as `open <app>`, is in the app's
    /// bundle, ignoring case as Mac disks do.
    static func launchAgent(_ plist: NSDictionary, runsFrom app: InstalledApp) -> Bool {
        let bundle = app.url.standardizedFileURL.path.lowercased()
        let paths = [plist["Program"] as? String].compactMap(\.self) + ((plist["ProgramArguments"] as? [String]) ?? [])
        return paths.contains { path in
            let path = path.lowercased()
            return path == bundle || path.hasPrefix(bundle + "/")
        }
    }

    /// This user's launch agents that start something in the app, which launchd would start again
    /// after the app quits.
    static func launchAgents(runningFrom app: InstalledApp, home: URL) -> [URL] {
        let agents = home.appending(path: "Library/LaunchAgents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? []
        return names.filter { $0.hasSuffix(".plist") }.map { agents.appending(path: $0) }.filter { url in
            NSDictionary(contentsOf: url).map { launchAgent($0, runsFrom: app) } ?? false
        }
    }

    // MARK: Removing

    struct Removal: Sendable, Equatable {
        /// Space moved to the Trash.
        var trashed: Int64 = 0
        var removedApp = false
        var removedItems = 0
        /// Names of what stayed, with why.
        var failures: [String] = []
    }

    /// How items go: to the Trash, through Finder when the app is the system's, and launch agents
    /// stopped first. Tests swap these so they don't touch the real Trash, Finder or launchd.
    struct Remover: Sendable {
        var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        /// Asks Finder, which asks for an administrator's password when the bundle needs one.
        var trashWithFinder: @Sendable (URL) async throws -> Void = { try await finderDelete($0) }
        /// Stops the agent; true when it was running, so it can be started again if it stays.
        var unloadAgent: @Sendable (URL) async -> Bool = { url in
            let output = try? await Command.run(
                "/bin/launchctl", ["bootout", "gui/\(getuid())", url.path], timeout: .seconds(10))
            return output?.status == 0
        }
        var reloadAgent: @Sendable (URL) async -> Void = { url in
            _ = try? await Command.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", url.path], timeout: .seconds(10))
        }
    }

    /// Moves to the Trash what was reviewed and the rules still allow, looked at again now, since
    /// things change between reviewing and removing. The app goes first; if it can't, its data
    /// stays, so the app isn't left without it.
    @concurrent
    static func remove(
        _ app: InstalledApp, reviewed: Set<String>, sizes: [String: Int64], context: Context, remover: Remover
    ) async -> Removal {
        let items = footprint(of: app, context: context)
        var removal = Removal()
        for (index, item) in items.enumerated() where reviewed.contains(item.id) {
            guard let url = item.url else { continue }
            let isApp = index == 0
            if let reason = item.skipReason {
                removal.failures.append("\(item.name): \(reason)")
                if isApp { return removal }
                continue
            }
            let wasRunning = item.name.hasPrefix(launchAgentKind) ? await remover.unloadAgent(url) : false
            var failure: Error?
            do {
                try remover.trash(url)
            } catch {
                failure = error
                // App Store apps and others installed by the system need a password to move.
                if isApp, isDenied(error) {
                    do {
                        try await remover.trashWithFinder(url)
                        failure = nil
                    } catch {
                        failure = error
                    }
                }
            }
            let isGone = (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil
            guard isGone else {
                // An agent that stays is started again, so the app keeps working as before.
                if wasRunning { await remover.reloadAgent(url) }
                let reason =
                    (failure as? CommandError)?.errorDescription ?? Cleanup.failureReason(failure, trashing: true)
                removal.failures.append("\(item.name): \(reason)")
                if isApp { return removal }
                continue
            }
            removal.trashed += sizes[item.id] ?? item.size
            if isApp { removal.removedApp = true } else { removal.removedItems += 1 }
        }
        return removal
    }

    static func isDenied(_ error: Error) -> Bool {
        if Cleanup.isNotPermitted(error) { return true }
        return ([error as NSError] + (error as NSError).underlyingErrors.map { $0 as NSError }).contains {
            ($0.domain == NSPOSIXErrorDomain && $0.code == Int(EACCES))
                || ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteNoPermissionError)
        }
    }

    /// The path is passed as an argument, not written into the script, so no name can change it.
    static func finderDelete(_ url: URL) async throws {
        let output = try await Command.run(
            "/usr/bin/osascript",
            [
                "-e", "on run argv", "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
                "-e", "end run", url.path,
            ],
            // Long enough to type a password.
            timeout: .seconds(120))
        guard output.status == 0 else {
            // -128: the password prompt was cancelled.
            if output.stderr.contains("-128") { throw CommandError(errorDescription: "Cancelled") }
            throw LiveFinder.error(from: output.stderr)
        }
    }
}
