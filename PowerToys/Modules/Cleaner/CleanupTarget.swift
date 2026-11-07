import Foundation

/// Folders of files that apps and tools make again when they need them, so emptying them frees
/// space without losing anything. The folders themselves stay; what's directly in them goes,
/// unless a rule protects it.
nonisolated enum CleanupTarget: String, CaseIterable, Identifiable, Sendable {
    case caches, logs, xcode, developerCaches, docker, leftovers

    var id: Self { self }

    var title: String {
        switch self {
        case .caches: "App caches"
        case .logs: "Logs"
        case .xcode: "Xcode build data"
        case .developerCaches: "Package caches"
        case .docker: "Docker"
        case .leftovers: "Uninstalled app leftovers"
        }
    }

    var hint: String {
        switch self {
        case .caches:
            "Files apps keep to open things faster, in ~/Library/Caches. Caches of open apps, and ones macOS needs, are left alone."
        case .logs: "Diagnostic logs apps write, in ~/Library/Logs and crash reports."
        case .xcode: "DerivedData and simulator caches. Left alone while Xcode or Simulator is open."
        case .developerCaches: "Downloads npm and build tools keep in ~/.npm and ~/.cache. Fetched again when needed."
        case .docker: "Build cache and images no container uses, removed by Docker itself. Containers and volumes are left to you."
        case .leftovers:
            "Data apps you removed left in ~/Library, found by their sandbox folder. Moved to the Trash, so it can be put back."
        }
    }

    /// Off until it's ticked, since a guess about what's uninstalled can be wrong.
    static let selectedByDefault = Set(allCases).subtracting([.leftovers])

    /// Whether it's no use without Full Disk Access, which macOS requires to change other apps'
    /// containers.
    var needsFullDiskAccess: Bool { self == .leftovers }

    /// Whether cleaning lists it again first, and so tells what it leaves alone itself. Docker
    /// asks Docker to prune instead.
    var listsAgainWhenCleaning: Bool { self != .docker }

    /// Whether it moves items to the Trash rather than deleting them for good.
    var movesToTrash: Bool { self == .leftovers }

    /// Tool caches in ~/.cache that are downloads or build output, fetched or built again when
    /// needed. The folder also holds downloaded models and runtimes, so only these are cleaned.
    static let toolCaches: [String] = [
        "typescript", "electron", "node-gyp", "vite", "webpack", "eslint", "prettier", "prisma", "poetry",
        "ruff", "mypy", "pre-commit", "swift-package-manager", "zig", "terraform", "curl", "wget",
    ]

    func folders(in home: URL) -> [URL] {
        var paths: [String] = []
        switch self {
        case .caches: paths = ["Library/Caches"]
        // Crash reports are cleaned inside, so the folder macOS writes them to stays.
        case .logs: paths = ["Library/Logs", "Library/Logs/DiagnosticReports"]
        case .xcode: paths = ["Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator/Caches"]
        // ~/.npm/_npx holds packages `npx` may be running, so only npm's caches go.
        case .developerCaches:
            paths = [".npm/_cacache", ".npm/_logs", ".npm/_prebuilds"]
            for name in Self.toolCaches { paths.append(".cache/" + name) }
        // Docker's files are its disk image, which only Docker may change; leftovers are found
        // app by app, across many folders.
        case .docker, .leftovers: break
        }
        return paths.map { (path: String) -> URL in home.appending(path: path, directoryHint: .isDirectory) }
    }

    /// Apps that use these files while they're open, so the whole target waits until they quit.
    /// By the app's own program, not its bundle, since tools run from inside Xcode.app, such as
    /// the language server an editor starts, don't mean Xcode is open.
    var blockingApps: [(executable: String, name: String)] {
        switch self {
        case .xcode: [("Xcode", "Xcode"), ("Simulator", "Simulator")]
        default: []
        }
    }

    /// Command-line tools that use these files while they run, such as a build in Terminal, so
    /// the whole target waits for them too.
    var blockingTools: [(program: String, name: String)] {
        switch self {
        case .xcode: [("xcodebuild", "xcodebuild"), ("XCBBuildService", "An Xcode build")]
        default: []
        }
    }

    /// Names in the folder that are never deleted, matched ignoring case; a trailing `*` matches
    /// any ending.
    var protectedNames: [String] {
        switch self {
        case .caches:
            [
                // macOS breaks rather than rebuilds without these: fonts, search and iCloud sync.
                "com.apple.FontRegistry*", "com.apple.Spotlight*", "CloudKit*", "com.apple.finder",
                // Live data kept in a cache folder: virtual environments, `pnpm dlx` packages,
                // downloaded models, R packages projects link to and browsers Playwright runs.
                "pypoetry", "pnpm", "llama.cpp", "org.R-project.R", "ms-playwright*", "kitty",
                // Deno's whole cache root, tldr pages and Surge's rules are kept by their tools.
                "deno", "tealdeer", "com.nssurge.surge-mac",
                // Large indexes that are slow to rebuild, and Chrome's live cache.
                "JetBrains*", "com.jetbrains.toolbox*", "Google",
            ]
        default: []
        }
    }

    func protects(_ name: String) -> Bool {
        protectedNames.contains { pattern in
            pattern.hasSuffix("*")
                ? name.lowercased().hasPrefix(pattern.dropLast().lowercased())
                : name.caseInsensitiveCompare(pattern) == .orderedSame
        }
    }
}

/// Something a cleanup removes: a file or folder directly in a cleanup folder, or a kind of
/// data Docker keeps.
nonisolated struct CleanupItem: Identifiable, Hashable, Sendable {
    /// The path, or a name for Docker data; unticked items are remembered by it.
    let id: String
    let name: String
    /// Where it is on disk, for files and folders.
    let url: URL?
    let size: Int64
    /// Why it's left alone, or nil when it's deleted.
    let skipReason: String?

    init(url: URL, size: Int64, skipReason: String?) {
        self.init(id: url.path, name: url.lastPathComponent, url: url, size: size, skipReason: skipReason)
    }

    init(id: String, name: String, url: URL? = nil, size: Int64, skipReason: String?) {
        self.id = id
        self.name = name
        self.url = url
        self.size = size
        self.skipReason = skipReason
    }
}

/// Something that happened while cleaning, for the progress shown as it runs.
nonisolated struct CleanupEvent: Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case started
        /// An item went, freeing this much.
        case deleted(Int64)
        /// An item went to the Trash; it frees space only once the Trash is emptied.
        case trashed(Int64)
        /// An item stayed, and why.
        case failed(String)
        /// An item a rule keeps, and which; it was never tried.
        case skipped(String)
        /// The target is done, having freed this much.
        case finished(Int64)
        /// The target ran out of time; it stops after the item it's on, and the log has the rest.
        case timedOut
    }

    let id = UUID()
    let date = Date.now
    let target: CleanupTarget
    let kind: Kind
    /// The path, or what Docker removed.
    var detail = ""
}

/// What a cleanup target holds, largest first.
nonisolated struct CleanupScan: Hashable, Sendable {
    var items: [CleanupItem]
    /// Why the target can't be cleaned at all, such as Docker not being installed.
    var unavailable: String?

    var cleanable: [CleanupItem] { items.filter { $0.skipReason == nil } }

    /// The space cleaning frees, leaving out `kept` items.
    func size(keeping kept: Set<String> = []) -> Int64 {
        cleanable.filter { !kept.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
}

/// Measures and empties cleanup folders off the main thread, checking every item against the
/// safety rules both when it's listed and again right before it's deleted.
nonisolated enum Cleanup {
    /// The home folder everything must be inside, what's running, the IDs of items the person
    /// chose to keep, the IDs of items they saw in the list they confirmed, and Docker.
    struct Context: Sendable {
        var home: URL
        var activity: ActivitySnapshot
        var kept: Set<String> = []
        /// Only these are deleted, so nothing that appeared after the review goes; nil for none.
        var reviewed: Set<String>?
        /// Sizes the reviewed list measured, so cleaning doesn't walk every folder again.
        var sizes: [String: Int64] = [:]
        var docker: DockerCLI?
        /// npm, when installed, which empties its own cache.
        var npm: NpmCLI?
        /// Whether Docker also removes tagged images no container uses.
        var dockerPrunesTagged = false
        /// What's installed, for telling leftovers apart; nil when it couldn't be read.
        var apps: InstalledApps?
        /// Whether other apps' containers can be changed, which macOS allows only with Full Disk
        /// Access.
        var canChangeAppContainers = true
        /// Moves an item to the Trash; tests use a folder of their own.
        var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

        func mayDelete(_ id: String) -> Bool {
            !kept.contains(id) && (reviewed?.contains(id) ?? false)
        }

    }

    static let unknownUse = "Couldn't check if it's in use"

    /// Lists what a target holds and which rule, if any, keeps each item. Without `measures`, sizes
    /// are left at zero, for checking the rules quickly. Stops early when the task is cancelled.
    @concurrent
    static func scan(_ target: CleanupTarget, context: Context, measures: Bool = true) async -> CleanupScan {
        if target == .docker { return await DockerCleanup.scan(context.docker, prunesTagged: context.dockerPrunesTagged) }
        if target == .leftovers { return AppLeftovers.scan(context: context, measures: measures) }
        let files = FileManager.default
        let folders = target.folders(in: context.home)
        let activity = context.activity
        let blocker =
            target.blockingApps.first { activity.isAppRunning(executable: $0.executable) == true }.map { "\($0.name) is open" }
            ?? target.blockingTools.first { activity.isRunning(program: $0.program) == true }.map { "\($0.name) is running" }
        // Without the process list, an app that blocks the target could be open.
        let blockerUnknown = !(target.blockingApps.isEmpty && target.blockingTools.isEmpty) && activity.commandLines == nil
        let mounts = mountPaths()
        var items: [CleanupItem] = []
        for folder in folders {
            guard !Task.isCancelled,
                let contents = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.volumeIdentifierKey])
            else { continue }
            let folderReason = reason(toKeep: folder, home: context.home)
            let volume = volumeID(folder)
            for item in contents where !folders.contains(where: { $0.standardizedFileURL == item.standardizedFileURL }) {
                let name = item.lastPathComponent
                var reason = folderReason ?? blocker ?? (blockerUnknown ? unknownUse : nil)
                if reason == nil, target.protects(name) { reason = "Protected" }
                // Background parts of macOS keep live state in their caches, such as downloads in
                // progress, and aren't reliably seen as running.
                if reason == nil, target == .caches, name.lowercased().hasPrefix("com.apple.") { reason = "Part of macOS" }
                // Parts of macOS whose names don't say so, such as familycircled's caches, can't
                // even be looked into; deleting them would be refused too.
                if reason == nil, isProtectedByMacOS(item) { reason = protectedByMacOS }
                // Another disk mounted at the item or anywhere inside it, which deleting the folder
                // would reach into.
                if reason == nil { reason = diskReason(item, folderVolume: volume, mounts: mounts) }
                if reason == nil {
                    switch activity.ownerIsRunning(name) {
                    case true?: reason = "App is open"
                    case nil: reason = unknownUse
                    case false?: break
                    }
                }
                if reason == nil, item.path.contains("/.npm/") {
                    switch activity.npmIsRunning {
                    case true?: reason = "npm is running"
                    case nil: reason = unknownUse
                    case false?: break
                    }
                }
                if reason == nil {
                    switch activity.isOpen(item) {
                    case true?: reason = "In use"
                    case nil: reason = unknownUse
                    case false?: break
                    }
                }
                let measured = measures ? measure(item, volume: volume) : nil
                // Only cleanable items are reviewed, so one kept here isn't tried at clean time.
                if reason == nil, measured?.readOnly == true { reason = readOnlyReason }
                items.append(CleanupItem(url: item, size: measured?.size ?? 0, skipReason: reason))
            }
        }
        return CleanupScan(items: items.sorted { $0.size > $1.size })
    }

    /// Deletes for good, or for a target that `movesToTrash` moves to the Trash, what was reviewed,
    /// the rules allow right now and isn't kept, and returns the space it took. Items that can't
    /// go, such as ones macOS protects, stay where they are. Each is added to `log` when there is
    /// one.
    @concurrent
    static func clean(
        _ target: CleanupTarget, context: Context, log: URL?, report: @escaping @Sendable (CleanupEvent) -> Void = { _ in }
    ) async -> Int64 {
        if target == .docker {
            var lines: [String] = []
            let freed = await DockerCleanup.clean(
                context.docker, mayDelete: context.mayDelete, prunesTagged: context.dockerPrunesTagged
            ) { kind, name in
                if case .deleted(let bytes) = kind { lines.append("\(Date.now.ISO8601Format())\t\(bytes)\tDocker: \(name)") }
                report(CleanupEvent(target: target, kind: kind, detail: name))
            }
            if let log, !lines.isEmpty { append(lines, to: log) }
            return freed
        }
        let files = FileManager.default
        // The rules are checked again here, since things change between listing and deleting.
        let scan = await scan(target, context: context, measures: false)
        var freed: Int64 = 0
        var lines: [String] = []
        var handled: Set<String> = []
        if target == .developerCaches, let npm = context.npm {
            let cache = context.home.appending(path: ".npm/_cacache").standardizedFileURL.path
            let inCache = scan.items.filter { $0.url?.deletingLastPathComponent().standardizedFileURL.path == cache }
            // npm empties the whole folder, so it's asked only when everything in it is to go.
            // npm cleans the cache its settings name, which must be the folder that was listed.
            let npmCache = try? await npm.run(["config", "get", "cache"], .seconds(30))
            let usesListedCache =
                npmCache.map {
                    $0.status == 0
                        && URL(filePath: $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path
                            == context.home.appending(path: ".npm").standardizedFileURL.path
                } ?? false
            if usesListedCache, !inCache.isEmpty, inCache.allSatisfy({ $0.skipReason == nil && context.mayDelete($0.id) }) {
                // Whatever it exits with, what npm removed before stopping is counted.
                _ = try? await npm.run(["cache", "clean", "--force"], .seconds(300))
                for item in inCache where (try? files.attributesOfItem(atPath: item.url?.path ?? "")) == nil {
                    let gone = context.sizes[item.id] ?? 0
                    report(CleanupEvent(target: target, kind: .deleted(gone), detail: item.url?.path ?? item.name))
                    freed += gone
                    lines.append("\(Date.now.ISO8601Format())\t\(gone)\t\(item.url?.path ?? item.name)\t(npm cache clean)")
                    handled.insert(item.id)
                }
            }
        }
        // What npm didn't empty, or everything when it isn't installed, is deleted here.
        // What's left alone is told, with the reason it has now, which can be new since the review,
        // such as an app opened meanwhile.
        for item in scan.items where item.skipReason != nil {
            report(CleanupEvent(target: target, kind: .skipped(item.skipReason ?? ""), detail: item.url?.path ?? item.name))
        }
        for item in scan.cleanable where context.mayDelete(item.id) && !handled.contains(item.id) {
            // A clean that took too long stops between items.
            if Task.isCancelled { break }
            guard let url = item.url else { continue }
            if let reason = reason(toKeep: url.deletingLastPathComponent(), home: context.home) {
                report(CleanupEvent(target: target, kind: .failed(reason), detail: url.path))
                continue
            }
            // Only reviewed items get here, and the review measured each one.
            let gone = context.sizes[item.id] ?? 0
            var failure: Error?
            do {
                if target.movesToTrash { try context.trash(url) } else { try files.removeItem(at: url) }
            } catch {
                failure = error
            }
            // The item itself is checked, not what a link in it points to.
            let isGone = (try? files.attributesOfItem(atPath: url.path)) == nil
            // Gone before this reached it, so nothing was freed here.
            if let failure, Self.isMissing(failure), isGone { continue }
            // Still there, perhaps partly deleted; its size then is unknown, so nothing is claimed.
            guard isGone else {
                report(CleanupEvent(target: target, kind: .failed(failureReason(failure, trashing: target.movesToTrash)), detail: url.path))
                continue
            }
            report(CleanupEvent(target: target, kind: target.movesToTrash ? .trashed(gone) : .deleted(gone), detail: url.path))
            freed += gone
            lines.append("\(Date.now.ISO8601Format())\t\(gone)\t\(url.path)\(target.movesToTrash ? "\t(to Trash)" : "")")
        }
        if let log, !lines.isEmpty { append(lines, to: log) }
        return freed
    }

    static let protectedByMacOS = "Protected by macOS"

    /// Whether macOS refuses to let this app look into a folder: "Operation not permitted", not
    /// a matter of the folder's own permissions.
    static func isProtectedByMacOS(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
        // Opened, not listed, so a large folder isn't read just for this.
        guard let folder = opendir(url.path) else { return errno == EPERM }
        closedir(folder)
        return false
    }

    /// The error and the ones it wraps.
    private static func chain(_ error: Error) -> [NSError] {
        [error as NSError] + (error as NSError).underlyingErrors.map { $0 as NSError }
    }

    static func isNotPermitted(_ error: Error) -> Bool {
        chain(error).contains { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EPERM) }
    }

    static func isMissing(_ error: Error) -> Bool {
        chain(error).contains { error in
            (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
        }
    }

    /// Why an item is still there after deleting it: macOS refused, or some of it couldn't go.
    static func failureReason(_ error: Error?, trashing: Bool) -> String {
        // "Operation not permitted": macOS's own protection, such as for app containers, rather
        // than the file's permissions.
        if let error, isNotPermitted(error) { return "macOS didn't allow it" }
        let denied = error.map {
            chain($0).contains { error in
                (error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES))
                    || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError)
            }
        }
        if denied == true { return "No permission" }
        return trashing ? "Couldn't move to the Trash" : "Couldn't be fully deleted"
    }

    /// Why a folder mustn't be cleaned: it's outside the home folder, or it or a folder above it
    /// is a symbolic link that could send the cleanup somewhere else.
    static func reason(toKeep folder: URL, home: URL) -> String? {
        let home = home.standardizedFileURL.path
        var url = folder.standardizedFileURL
        guard url.path.hasPrefix(home + "/"), !url.pathComponents.contains("..") else { return "Outside your home folder" }
        while url.path.count > home.count {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return "Linked elsewhere" }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func mountPaths() -> [String] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.standardizedFileURL.path }
    }

    /// Why an item reaches another disk: it's on one, or one is mounted inside it, so deleting it
    /// would reach into that disk. Nil when it's all on its folder's disk.
    static func diskReason(_ item: URL, folderVolume: NSObject?, mounts: [String]) -> String? {
        if volumeID(item).map({ !$0.isEqual(folderVolume) }) == true { return "On another disk" }
        if hasMount(inside: item, mounts: mounts) { return "Another disk is inside" }
        return nil
    }

    static func hasMount(inside item: URL, mounts: [String]) -> Bool {
        let path = item.standardizedFileURL.path
        return mounts.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    static func volumeID(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    static let readOnlyReason = "Read-only; its tool keeps it so"

    /// The space an item takes, with symbolic links counted as themselves and not followed, nor
    /// folders on another disk than `volume`, stopping when the task is cancelled; when anything in it, however
    /// deep, last changed; and whether a folder in it is read-only, as tools such as DotSlash and
    /// Go make what they download so it isn't changed. Deleting one would need its permissions
    /// changed first, which is the tool's call, not a cleaner's.
    static func measure(_ url: URL, volume: NSObject?) -> (size: Int64, newest: Date?, readOnly: Bool) {
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .volumeIdentifierKey,
            .contentModificationDateKey, .isWritableKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return (0, nil, false) }
        var newest = values.contentModificationDate
        if values.isRegularFile == true { return (Int64(values.totalFileAllocatedSize ?? 0), newest, false) }
        var readOnly = values.isWritable == false
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return (0, newest, readOnly) }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? child.resourceValues(forKeys: keys) else { continue }
            if let date = values.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
            if values.isDirectory == true, let volume, (values.volumeIdentifier as? NSObject)?.isEqual(volume) == false {
                enumerator.skipDescendants()
            } else if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            } else if values.isDirectory == true, values.isSymbolicLink != true, values.isWritable == false {
                readOnly = true
            }
        }
        return (total, newest, readOnly)
    }

    private static func append(_ lines: [String], to log: URL) {
        let text = Data((lines.joined(separator: "\n") + "\n").utf8)
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Opened for appending, so targets cleaned at the same time don't write over each other.
        let descriptor = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try? handle.write(contentsOf: text)
    }
}
