import AppKit

/// The apps on this Mac, for telling which app data has lost its app.
nonisolated struct InstalledApps: Sendable {
    /// Whether an app with exactly this ID is installed.
    var isInstalled: @Sendable (String) -> Bool
    /// The first two parts of every installed app's ID, such as com.adobe, lowercased.
    var vendors: Set<String>

    /// Whether the ID is an installed app's, one of its helpers' or extensions', such as
    /// net.whatsapp.WhatsApp.Intents, or its vendor's, who may share data between apps.
    func owns(_ id: String) -> Bool {
        if vendors.contains(Self.vendor(id)) { return true }
        var parts = id.split(separator: ".")
        while parts.count >= 2 {
            if isInstalled(parts.joined(separator: ".")) { return true }
            parts.removeLast()
        }
        return false
    }

    /// Whether an app Launch Services knows is there, or on a disk that isn't connected now.
    static func isPresent(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if FileManager.default.fileExists(atPath: path) { return true }
        let parts = path.split(separator: "/")
        guard parts.first == "Volumes", parts.count >= 2 else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])")
    }

    static func vendor(_ id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Launch Services answers for each ID; Spotlight's app index, plus the app folders in case
    /// it's off, gives the vendors. Nil when no apps could be found at all.
    @concurrent
    static func read() async -> InstalledApps? {
        var paths: [String] = []
        if let output = try? await Command.run(
            "/usr/bin/mdfind", ["-0", "kMDItemContentType == 'com.apple.application-bundle'"], timeout: .seconds(20)),
            output.status == 0
        {
            paths = output.stdout.split(separator: "\0").map(String.init)
        }
        let files = FileManager.default
        let folders = ["/Applications", "/System/Applications", files.homeDirectoryForCurrentUser.path + "/Applications"]
        for folder in folders {
            for name in (try? files.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = folder + "/" + name
                if name.hasSuffix(".app") {
                    paths.append(path)
                } else {
                    // Apps in a folder of their own, such as Utilities or a vendor's suite.
                    for inner in (try? files.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                        paths.append(path + "/" + inner)
                    }
                }
            }
        }
        // Folders named like apps, such as HTTPStorages/io.example.app, have no bundle ID.
        let ids = Set(paths).compactMap(AppBundle.identifier(atPath:))
        guard !ids.isEmpty else { return nil }
        return InstalledApps(
            isInstalled: { id in
                // Launch Services can remember an app that's since been deleted, but one on a disk
                // that isn't plugged in is still installed.
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map(isPresent) ?? false
            },
            vendors: Set(ids.map(vendor)))
    }
}

/// Data left in ~/Library by sandboxed apps that are no longer installed. macOS makes a
/// ~/Library/Containers folder only for apps and their extensions, never for command-line tools,
/// so each one whose app is gone proves an app was there; its other folders are found by its ID.
nonisolated enum AppLeftovers {
    /// Anything changed this recently may belong to an app that's still about, such as one
    /// being built in Xcode or kept on a disk Launch Services forgot, so it's left alone.
    static let recentDays = 30

    /// Where an app keeps its data in ~/Library, by kind: a folder and what follows the ID. Caches
    /// and logs are left to their own targets, so no folder is in two.
    static let places: [(kind: String, folder: String, suffix: String)] = [
        ("Container", "Containers", ""),
        ("App data", "Application Support", ""),
        ("Settings", "Preferences", ".plist"),
        ("Window state", "Saved Application State", ".savedState"),
        ("Web data", "HTTPStorages", ""),
        ("Cookies", "HTTPStorages", ".binarycookies"),
        ("Web data", "WebKit", ""),
    ]

    /// Every folder is walked, even when sizes aren't wanted, since the newest file inside is
    /// what tells whether the app is still about. Shared group containers aren't listed: another
    /// app from the same developer can use one under a different ID.
    static func scan(context: Cleanup.Context, measures: Bool, now: Date = .now) -> CleanupScan {
        guard let apps = context.apps else { return CleanupScan(items: [], unavailable: "Couldn't check installed apps") }
        let files = FileManager.default
        let library = context.home.appending(path: "Library", directoryHint: .isDirectory)
        guard let names = try? files.contentsOfDirectory(atPath: library.appending(path: "Containers").path) else {
            return CleanupScan(items: [])
        }
        let activity = context.activity
        let cutoff = now.addingTimeInterval(-Double(recentDays) * 86_400)
        let mounts = Cleanup.mountPaths()
        var items: [CleanupItem] = []
        // Containers named after a developer's team ID, such as UBF8T346G9.OfficeOsfWebHost, can't
        // be tied to an app by name, so they're never offered.
        for id in names
        where looksLikeAppID(id) && !id.lowercased().hasPrefix("com.apple.") && !startsWithTeamID(id) && !apps.owns(id) {
            if Task.isCancelled { break }
            let found: [(kind: String, url: URL)] = places.compactMap { place in
                let url = library.appending(path: "\(place.folder)/\(id)\(place.suffix)")
                return files.fileExists(atPath: url.path) ? (place.kind, url) : nil
            }
            let measured = found.map { Cleanup.measure($0.url, volume: Cleanup.volumeID($0.url.deletingLastPathComponent())) }
            var appReason: String?
            // The exact ID too, since short ones such as foo.app aren't matched by name.
            switch activity.bundleIDs.contains(id.lowercased()) ? true : activity.ownerIsRunning(id) {
            case true?: appReason = "App is open"
            case nil: appReason = Cleanup.unknownUse
            case false?: break
            }
            // Anything of the app's changed lately, however deep, means it may still be about.
            if appReason == nil, measured.compactMap(\.newest).max().map({ $0 > cutoff }) == true {
                appReason = recentReason
            }
            for ((kind, url), measure) in zip(found, measured) {
                var reason = Cleanup.reason(toKeep: url.deletingLastPathComponent(), home: context.home) ?? appReason
                if reason == nil {
                    reason = Cleanup.diskReason(
                        url, folderVolume: Cleanup.volumeID(url.deletingLastPathComponent()), mounts: mounts)
                }
                // macOS stops other apps changing an app's containers, without asking.
                if reason == nil, !context.canChangeAppContainers, kind == "Container" { reason = needsFullDiskAccess }
                if reason == nil, Cleanup.isProtectedByMacOS(url) { reason = Cleanup.protectedByMacOS }
                if reason == nil, measure.readOnly { reason = Cleanup.readOnlyReason }
                if reason == nil {
                    switch activity.isOpen(url) {
                    case true?: reason = "In use"
                    case nil: reason = Cleanup.unknownUse
                    case false?: break
                    }
                }
                items.append(
                    CleanupItem(
                        id: url.path, name: "\(id) · \(kind)", url: url, size: measures ? measure.size : 0, skipReason: reason))
            }
        }
        return CleanupScan(items: items.sorted { $0.size > $1.size })
    }

    static let needsFullDiskAccess = "Needs Full Disk Access"
    static let recentReason = "Changed in the last month"

    /// Whether the name's first part is a team ID: ten capitals and digits.
    static func startsWithTeamID(_ name: String) -> Bool {
        let first = name.prefix { $0 != "." }
        return first.count == 10 && first.allSatisfy { ($0.isUppercase || $0.isNumber) && $0.isASCII }
    }

    /// Reverse-DNS names such as com.example.App, not dot files.
    static func looksLikeAppID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
    }
}
