import Foundation
import SQLite3

/// Finds out whether installed apps have newer versions, from the App Store, the update feeds
/// Sparkle apps name in their Info.plist, or Homebrew's casks. It only reads: nothing is
/// downloaded or installed.
nonisolated enum AppUpdates {
    enum Source: Hashable, Sendable {
        case appStore(page: URL)
        /// A Sparkle appcast, which the app itself installs from.
        case feed
        case homebrew(cask: String)

        var name: String {
            switch self {
            case .appStore: "App Store"
            case .feed: "Update feed"
            case .homebrew: "Homebrew"
            }
        }
    }

    struct Found: Hashable, Sendable {
        let source: Source
        /// The newest version, as the source shows it.
        let latest: String
        /// The app's version when it was checked.
        let installed: String?
    }

    enum Status: Hashable, Sendable {
        case available(Found)
        case upToDate(Found)
        /// Why it couldn't be told.
        case unknown(String)
    }

    static let noSource = "No update feed to check"

    typealias Fetch = @Sendable (URL) async throws -> Data

    /// What's needed from an app's Info.plist, read when checking, as the app may have updated
    /// itself since it was listed.
    struct AppInfo: Sendable {
        /// What people see, compared with the App Store's and Homebrew's versions.
        let shortVersion: String?
        /// The build, which is what Sparkle feeds compare.
        let build: String?
        let feed: URL?
        /// The App Store release installed, which an update the App Store lists may already be.
        let storeVersionID: Int64?

        init(shortVersion: String?, build: String?, feed: URL?, storeVersionID: Int64? = nil) {
            self.shortVersion = shortVersion
            self.build = build
            self.feed = feed
            self.storeVersionID = storeVersionID
        }

        init(_ app: URL) {
            let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
            shortVersion = info?["CFBundleShortVersionString"] as? String
            build = info?["CFBundleVersion"] as? String
            feed = (info?["SUFeedURL"] as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
                .flatMap { ["https", "http"].contains($0.scheme?.lowercased()) ? $0 : nil }
            let item = MDItemCreateWithURL(nil, app as CFURL)
            let versionID = item.flatMap { MDItemCopyAttribute($0, "kMDItemAppStoreInstallerVersionID" as CFString) }
            storeVersionID = (versionID as? String).flatMap { Int64($0) } ?? (versionID as? NSNumber)?.int64Value
        }
    }

    /// An update the App Store has found for one of its apps.
    struct StoreUpdate: Equatable, Sendable {
        let version: String?
        let page: URL?
        /// The release it installs.
        var versionID: Int64?
    }

    /// Looked up once for all apps: the App Store's updates and versions, and Homebrew's casks.
    struct Catalog: Sendable {
        /// The App Store's own list of updates, by bundle ID lowercased; nil when it couldn't be read.
        var storeUpdates: [String: StoreUpdate]?
        /// The App Store hasn't checked for updates lately, as when signed out, so its list being
        /// empty says nothing.
        var storeListIsStale = false
        /// The App Store's public listing, used only without its own list.
        var appStore: [String: (version: String, page: URL)] = [:]
        /// Casks by the app bundle name they install, such as "Firefox.app", lowercased. Asked
        /// for only when an app has no feed to answer, as listing them can take a while.
        var casks: @Sendable () async -> [String: Cask] = { [:] }
    }

    /// A Homebrew cask: its version now, and the one Homebrew installed, written the same way.
    struct Cask: Equatable, Sendable {
        let token: String
        let version: String
        var installed: String?
    }

    // MARK: Checking

    /// The App Store for its apps, then the app's own feed, then Homebrew.
    static func status(of app: InstalledApp, info: AppInfo, catalog: Catalog, fetch: Fetch) async -> Status {
        if app.isAppStore {
            // What the App Store itself offers: its listing's version can be one this Mac isn't
            // offered, and an update can keep the same version and change only the build.
            if catalog.storeListIsStale { return .unknown(storeNotChecking) }
            if let updates = catalog.storeUpdates {
                // A listed release that's already installed isn't an update.
                let listed = updates[app.bundleID.lowercased()]
                guard let update = listed, update.versionID == nil || update.versionID != info.storeVersionID else {
                    let installed = info.shortVersion
                    return .upToDate(Found(source: .appStore(page: storeUpdatesPage), latest: installed ?? "", installed: installed))
                }
                return .available(
                    Found(
                        source: .appStore(page: update.page ?? storeUpdatesPage), latest: update.version ?? "",
                        installed: info.shortVersion))
            }
            guard let entry = catalog.appStore[app.bundleID.lowercased()] else { return .unknown("Not found in the App Store") }
            return compare(entry.version, with: info.shortVersion, source: .appStore(page: entry.page))
        }
        var problem: String?
        if let feed = info.feed {
            do {
                if let newest = newestItem(inAppcast: try await fetch(feed)) {
                    let found = Found(source: .feed, latest: newest.shortVersion ?? newest.version, installed: info.shortVersion)
                    if let build = info.build {
                        return compareVersions(newest.version, build) == .orderedDescending ? .available(found) : .upToDate(found)
                    }
                    problem = "No version in the app"
                } else {
                    problem = "Its update feed lists no versions"
                }
            } catch {
                problem = "Couldn't read its update feed"
            }
        }
        if let cask = await catalog.casks()[app.url.lastPathComponent.lowercased()] {
            // Homebrew's own record of what it installed is written like the cask's version, so
            // it's compared first; the app's version only counts once the app has moved on, as
            // one that updates itself does.
            if let installed = cask.installed, compareVersions(cask.version, installed, ignoringTrailingZeros: true) != .orderedDescending {
                let found = Found(source: .homebrew(cask: cask.token), latest: cask.version, installed: info.shortVersion)
                return .upToDate(found)
            }
            return compare(cask.version, with: info.shortVersion, source: .homebrew(cask: cask.token))
        }
        return .unknown(problem ?? noSource)
    }

    /// Compares versions people see, where 3.2.0 is the same as 3.2.
    private static func compare(_ latest: String, with installed: String?, source: Source) -> Status {
        let found = Found(source: source, latest: latest, installed: installed)
        guard let installed else { return .unknown("No version in the app") }
        return compareVersions(latest, installed, ignoringTrailingZeros: true) == .orderedDescending
            ? .available(found) : .upToDate(found)
    }

    // MARK: App Store

    static let storeUpdatesPage = URL(string: "macappstore://showUpdatesPage")!

    /// Where the App Store keeps the updates it has found, as it shows them in Updates.
    static func storeDatabase(home: URL) -> URL {
        home.appending(path: "Library/Caches/com.apple.appstoreagent/storeSystem.db")
    }

    /// The updates the App Store found at its last check and hasn't installed; nil when its list
    /// can't be read, such as when the App Store keeps it elsewhere. Its other table of updates,
    /// mapi_app_update, also keeps ones it has installed.
    static func storeUpdates(database: URL) -> [String: StoreUpdate]? {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard FileManager.default.fileExists(atPath: database.path),
            sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return nil }
        sqlite3_busy_timeout(connection, 2000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_prepare_v2(
                connection, "SELECT bundle_id, store_software_version_id, store_item_data FROM app_updates", -1, &statement, nil)
                == SQLITE_OK
        else { return nil }
        var updates: [String: StoreUpdate] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            let versionID = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 1)
            let length = Int(sqlite3_column_bytes(statement, 2))
            let data = sqlite3_column_blob(statement, 2).map { Data(bytes: $0, count: length) }
            var update = data.map(parseStoreUpdate) ?? StoreUpdate(version: nil, page: nil)
            update.versionID = versionID
            updates[id.lowercased()] = update
        }
        return updates
    }

    /// The new version and the app's page from the App Store's record of an update, wherever in
    /// it they are, as the record's layout isn't documented.
    static func parseStoreUpdate(_ data: Data) -> StoreUpdate {
        let json = try? JSONSerialization.jsonObject(with: data)
        let version = first(in: json) { key, value in key == "versionDisplay" ? value as? String : nil }
        // The app's own page, not its developer's, which the record can also link.
        let attributes = (json as? [String: Any])?["attributes"] as? [String: Any]
        let page =
            (attributes?["url"] as? String).flatMap(URL.init(string:))
            ?? first(in: json) { _, value in
                (value as? String).flatMap { $0.hasPrefix("https://apps.apple.com/") && $0.contains("/app/") ? URL(string: $0) : nil }
            }
        return StoreUpdate(version: version, page: page)
    }

    /// The first value `match` picks, searching depth first.
    private static func first<T>(in json: Any?, _ match: (String, Any) -> T?) -> T? {
        if let object = json as? [String: Any] {
            for key in object.keys.sorted() {
                if let found = match(key, object[key]!) ?? first(in: object[key], match) { return found }
            }
        } else if let array = json as? [Any] {
            for element in array {
                if let found = first(in: element, match) { return found }
            }
        }
        return nil
    }

    static let storeNotChecking = "The App Store hasn't checked lately. Open it to check."

    /// When the App Store last checked for updates; nil when it never has or it can't be read.
    static func storeLastCheck() -> Date? {
        CFPreferencesCopyAppValue("LastUpdatesCheck" as CFString, "com.apple.appstored" as CFString) as? Date
    }

    /// Whether the App Store checked recently enough for its list to be current. It checks about
    /// daily while signed in.
    static func isRecent(_ check: Date?, now: Date = .now) -> Bool {
        guard let check else { return false }
        return now.timeIntervalSince(check) < 7 * 24 * 60 * 60
    }

    /// The App Store's versions of these apps, asked 50 at a time, from the store of the Mac's region.
    static func appStoreVersions(
        _ bundleIDs: [String], region: String = Locale.current.region?.identifier ?? "US", fetch: Fetch
    ) async -> [String: (version: String, page: URL)] {
        var found: [String: (version: String, page: URL)] = [:]
        for start in stride(from: 0, to: bundleIDs.count, by: 50) {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [
                .init(name: "bundleId", value: bundleIDs[start..<min(start + 50, bundleIDs.count)].joined(separator: ",")),
                .init(name: "entity", value: "macSoftware"),
                .init(name: "country", value: region.lowercased()),
            ]
            guard let url = components.url, let data = try? await fetch(url) else { continue }
            found.merge(parseAppStore(data)) { first, _ in first }
        }
        return found
    }

    /// Versions by bundle ID, lowercased, from a lookup's JSON.
    static func parseAppStore(_ data: Data) -> [String: (version: String, page: URL)] {
        struct Response: Decodable {
            struct Result: Decodable {
                let bundleId: String?
                let version: String?
                let trackViewUrl: URL?
            }
            let results: [Result]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [:] }
        var found: [String: (version: String, page: URL)] = [:]
        for result in response.results {
            guard let id = result.bundleId, let version = result.version, let page = result.trackViewUrl else { continue }
            found[id.lowercased()] = (version, page)
        }
        return found
    }

    // MARK: Homebrew

    /// Where Homebrew puts `brew` on Apple silicon and Intel Macs.
    static func findBrew() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The installed casks, as Homebrew last downloaded their list; nothing when brew isn't there
    /// or fails.
    static func installedCasks(brew: String) async -> [String: Cask] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        guard
            let output = try? await Command.run(
                brew, ["info", "--cask", "--installed", "--json=v2"], environment: environment, timeout: .seconds(60)),
            output.status == 0
        else { return [:] }
        return parseCasks(Data(output.stdout.utf8))
    }

    /// Casks by the apps they install, from `brew info --json=v2`. A cask's version can carry a
    /// build after a comma, which is left off; "latest" casks have no version to compare.
    static func parseCasks(_ data: Data) -> [String: Cask] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let casks = json["casks"] as? [[String: Any]]
        else { return [:] }
        var found: [String: Cask] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String, let full = cask["version"] as? String, full != "latest",
                let version = full.split(separator: ",").first.map(String.init)
            else { continue }
            let installed = (cask["installed"] as? String)?.split(separator: ",").first.map(String.init)
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                // ["Foo.app"], or ["Foo.app", {"target": "Bar.app"}] when it's installed renamed.
                guard let app = artifact["app"] as? [Any], let source = app.first as? String else { continue }
                let target = app.dropFirst().compactMap { ($0 as? [String: Any])?["target"] as? String }.first ?? source
                found[(target as NSString).lastPathComponent.lowercased()] = Cask(token: token, version: version, installed: installed)
            }
        }
        return found
    }

    // MARK: Sparkle feeds

    struct AppcastItem: Equatable {
        let version: String
        let shortVersion: String?
    }

    /// The newest release in a Sparkle appcast that this Mac can run: items for other systems, in
    /// beta channels or needing a newer macOS are skipped.
    static func newestItem(
        inAppcast data: Data, system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> AppcastItem? {
        let parser = XMLParser(data: data)
        let reader = AppcastReader()
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        let running = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return reader.items
            .filter { item in
                item.channel == nil && (item.os == nil || item.os == "macos")
                    && item.minimumSystem.map { compareVersions($0, running) != .orderedDescending } ?? true
            }
            .compactMap { item in item.version.map { AppcastItem(version: $0, shortVersion: item.shortVersion) } }
            .max { compareVersions($0.version, $1.version) == .orderedAscending }
    }

    /// Reads each `<item>`'s version from its own elements or its main enclosure, leaving out the
    /// enclosures of delta updates.
    private final class AppcastReader: NSObject, XMLParserDelegate {
        struct Item {
            var version: String?
            var shortVersion: String?
            var minimumSystem: String?
            var channel: String?
            var os: String?
        }

        var items: [Item] = []
        private var item: Item?
        private var path: [String] = []
        private var text = ""

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            path.append(name)
            text = ""
            if name == "item" {
                item = Item()
            } else if name == "enclosure", path.dropLast().last == "item", var current = item {
                current.version = current.version ?? attributes["sparkle:version"]
                current.shortVersion = current.shortVersion ?? attributes["sparkle:shortVersionString"]
                current.os = attributes["sparkle:os"]?.lowercased()
                item = current
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast() }
            if name == "item" {
                if let item { items.append(item) }
                item = nil
                return
            }
            // Only the item's own elements, not ones inside its deltas.
            guard item != nil, path.dropLast().last == "item" else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            switch name {
            case "sparkle:version": item?.version = value
            case "sparkle:shortVersionString": item?.shortVersion = value
            case "sparkle:minimumSystemVersion": item?.minimumSystem = value
            case "sparkle:channel": item?.channel = value
            default: break
            }
        }
    }

    // MARK: Versions

    /// Compares versions as Sparkle does: numbers by value, letters as text, a number above
    /// letters, so 1.10 > 1.9 and 1.0 > 1.0b2, and a longer version above a shorter one unless
    /// what follows is letters, so 1.0.1 > 1.0 > 1.0rc.
    /// `ignoringTrailingZeros` makes 3.2.0 equal 3.2, as for versions people see; builds keep them.
    static func compareVersions(_ a: String, _ b: String, ignoringTrailingZeros: Bool = false) -> ComparisonResult {
        var left = parts(a)
        var right = parts(b)
        if ignoringTrailingZeros {
            while left.last == .number("0") { left.removeLast() }
            while right.last == .number("0") { right.removeLast() }
        }
        for (x, y) in zip(left, right) {
            switch (x, y) {
            // Digits without leading zeros: the longer is larger, so any length compares.
            case (.number(let x), .number(let y)) where x != y:
                return (x.count, x) < (y.count, y) ? .orderedAscending : .orderedDescending
            case (.text(let x), .text(let y)) where x != y: return x < y ? .orderedAscending : .orderedDescending
            case (.number, .text): return .orderedDescending
            case (.text, .number): return .orderedAscending
            default: continue
            }
        }
        guard left.count != right.count else { return .orderedSame }
        let longerIsLeft = left.count > right.count
        let next = longerIsLeft ? left[right.count] : right[left.count]
        let longerIsNewer: Bool
        if case .number = next { longerIsNewer = true } else { longerIsNewer = false }
        return longerIsLeft == longerIsNewer ? .orderedDescending : .orderedAscending
    }

    private enum Part: Equatable {
        case number(String)
        case text(String)
    }

    /// Runs of digits and of letters; anything else separates them.
    private static func parts(_ version: String) -> [Part] {
        var parts: [Part] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            if current.first?.isNumber == true {
                let digits = current.drop { $0 == "0" }
                parts.append(.number(digits.isEmpty ? "0" : String(digits)))
            } else {
                parts.append(.text(current.lowercased()))
            }
            current = ""
        }
        for character in version {
            if character.isNumber, character.isASCII {
                if let last = current.last, !last.isNumber { flush() }
                current.append(character)
            } else if character.isLetter {
                if let last = current.last, last.isNumber { flush() }
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return parts
    }
}
