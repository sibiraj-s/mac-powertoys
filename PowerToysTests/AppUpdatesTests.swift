import Foundation
import SQLite3
import Testing

@testable import PowerToys

struct AppUpdatesTests {
    private func app(_ name: String, id: String, appStore: Bool = false) -> InstalledApp {
        InstalledApp(
            url: URL(filePath: "/Applications/\(name).app"), bundleID: id, name: name, version: "1.0", isAppStore: appStore)
    }

    private let feedURL = URL(string: "https://example.com/appcast.xml")!

    private func appcast(_ items: String) -> Data {
        Data(
            """
            <?xml version="1.0"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
            \(items)
            </channel></rss>
            """.utf8)
    }

    // MARK: Versions

    @Test(arguments: [
        ("1.10", "1.9", ComparisonResult.orderedDescending),
        ("1.0", "1.0", .orderedSame),
        ("1.0.1", "1.0", .orderedDescending),
        ("1.0", "1.0b2", .orderedDescending),
        ("1.0b3", "1.0b2", .orderedDescending),
        ("1.0rc1", "1.0", .orderedAscending),
        ("2026.10.4", "2026.9.30", .orderedDescending),
        ("183", "182", .orderedDescending),
        ("v2.0", "V2.0", .orderedSame),
        // Longer than Int holds.
        ("202410151230451234568", "202410151230451234567", .orderedDescending),
        ("202410151230451234567", "1500", .orderedDescending),
        ("1.05", "1.5", .orderedSame),
    ])
    func comparesVersionsLikeSparkle(a: String, b: String, expected: ComparisonResult) {
        #expect(AppUpdates.compareVersions(a, b) == expected)
    }

    @Test func versionsPeopleSeeIgnoreTrailingZeros() {
        #expect(AppUpdates.compareVersions("3.2.0", "3.2", ignoringTrailingZeros: true) == .orderedSame)
        #expect(AppUpdates.compareVersions("3.2.0.1", "3.2", ignoringTrailingZeros: true) == .orderedDescending)
        #expect(AppUpdates.compareVersions("3.2.0", "3.2") == .orderedDescending)
    }

    @Test func theAppStoreCountsAsCheckingForAWeek() {
        let now = Date.now
        #expect(AppUpdates.isRecent(now.addingTimeInterval(-24 * 60 * 60), now: now))
        #expect(!AppUpdates.isRecent(now.addingTimeInterval(-8 * 24 * 60 * 60), now: now))
        #expect(!AppUpdates.isRecent(nil, now: now))
    }

    // MARK: Appcasts

    @Test func picksTheNewestReleaseThisMacCanRun() throws {
        let data = appcast(
            """
            <item><sparkle:version>180</sparkle:version><sparkle:shortVersionString>1.5.0</sparkle:shortVersionString>
              <enclosure url="https://x/a.dmg"/></item>
            <item><sparkle:version>183</sparkle:version><sparkle:shortVersionString>1.5.1</sparkle:shortVersionString>
              <sparkle:deltas><enclosure url="https://x/d" sparkle:version="999" sparkle:deltaFrom="180"/></sparkle:deltas>
              <enclosure url="https://x/b.dmg"/></item>
            <item><sparkle:version>190</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
            <item><sparkle:version>191</sparkle:version><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion></item>
            <item><enclosure url="https://x/w.exe" sparkle:version="200" sparkle:os="windows"/></item>
            """)
        let newest = try #require(
            AppUpdates.newestItem(inAppcast: data, system: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
        #expect(newest == .init(version: "183", shortVersion: "1.5.1"))
    }

    @Test func readsVersionsFromOlderEnclosureAttributes() {
        let data = appcast(
            """
            <item><enclosure url="https://x/a.zip" sparkle:version="42" sparkle:shortVersionString="4.2"/></item>
            """)
        #expect(AppUpdates.newestItem(inAppcast: data) == .init(version: "42", shortVersion: "4.2"))
    }

    @Test func emptyOrBrokenFeedsHaveNoRelease() {
        #expect(AppUpdates.newestItem(inAppcast: appcast("")) == nil)
        #expect(AppUpdates.newestItem(inAppcast: Data("not xml".utf8)) == nil)
    }

    // MARK: App Store and Homebrew

    @Test func parsesAppStoreLookups() throws {
        let data = Data(
            """
            {"resultCount": 2, "results": [
              {"bundleId": "net.shinyfrog.bear", "version": "3.0.4", "trackViewUrl": "https://apps.apple.com/app/id1"},
              {"bundleId": "com.example.NoVersion"}
            ]}
            """.utf8)
        let found = AppUpdates.parseAppStore(data)
        #expect(found.count == 1)
        #expect(found["net.shinyfrog.bear"]?.version == "3.0.4")
    }

    @Test func asksTheAppStoreFiftyAppsAtATime() async {
        let asked = AskedURLs()
        _ = await AppUpdates.appStoreVersions((0..<120).map { "com.example.\($0)" }, region: "IN") { url in
            await asked.add(url)
            return Data(#"{"results": []}"#.utf8)
        }
        let urls = await asked.urls
        #expect(urls.count == 3)
        #expect(urls.allSatisfy { $0.query?.contains("country=in") == true })
    }

    @Test func parsesCasksByTheAppsTheyInstall() {
        let data = Data(
            """
            {"casks": [
              {"token": "firefox", "version": "133.0", "installed": "132.0", "artifacts": [{"app": ["Firefox.app"]}]},
              {"token": "renamed", "version": "2.1,345", "artifacts": [{"app": ["Old.app", {"target": "New.app"}]}]},
              {"token": "nightly", "version": "latest", "artifacts": [{"app": ["Nightly.app"]}]},
              {"token": "cli", "version": "1.0", "artifacts": [{"binary": ["tool"]}]}
            ]}
            """.utf8)
        let casks = AppUpdates.parseCasks(data)
        #expect(casks.count == 2)
        #expect(casks["firefox.app"] == .init(token: "firefox", version: "133.0", installed: "132.0"))
        #expect(casks["new.app"]?.token == "renamed")
        #expect(casks["new.app"]?.version == "2.1")
    }

    // MARK: Status

    @Test func appStoreAppsAreComparedWithTheStore() async {
        let page = URL(string: "https://apps.apple.com/app/id1")!
        var catalog = AppUpdates.Catalog()
        catalog.appStore["com.example.bear"] = ("3.0.4", page)
        let bear = app("Bear", id: "com.example.Bear", appStore: true)
        let status = await AppUpdates.status(
            of: bear, info: .init(shortVersion: "3.0.3", build: "1", feed: nil), catalog: catalog, fetch: { _ in Data() })
        #expect(status == .available(.init(source: .appStore(page: page), latest: "3.0.4", installed: "3.0.3")))
        let missing = await AppUpdates.status(
            of: app("Gone", id: "com.example.Gone", appStore: true), info: .init(shortVersion: "1", build: "1", feed: nil),
            catalog: catalog, fetch: { _ in Data() })
        #expect(missing == .unknown("Not found in the App Store"))
    }

    @Test func readsTheAppStoresOwnUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AppUpdatesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "storeSystem.db")
        #expect(AppUpdates.storeUpdates(database: database) == nil)

        var connection: OpaquePointer?
        #expect(sqlite3_open(database.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        let item =
            #"{"attributes": {"url": "https://apps.apple.com/app/id1", "platformAttributes": {"osx": {"latestVersionInfo": {"versionDisplay": "2026.10.5"}}}}}"#
        let sql = """
            CREATE TABLE app_updates (pid INTEGER PRIMARY KEY, bundle_id TEXT, store_software_version_id INTEGER, store_item_data JSON);
            INSERT INTO app_updates (bundle_id, store_software_version_id, store_item_data)
              VALUES ('com.bitwarden.desktop', 894156683, '\(item)');
            INSERT INTO app_updates (bundle_id, store_software_version_id, store_item_data) VALUES ('net.whatsapp.WhatsApp', NULL, NULL);
            """
        #expect(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)

        let updates = try #require(AppUpdates.storeUpdates(database: database))
        #expect(
            updates["com.bitwarden.desktop"]
                == .init(version: "2026.10.5", page: URL(string: "https://apps.apple.com/app/id1"), versionID: 894_156_683))
        #expect(updates["net.whatsapp.whatsapp"] == .init(version: nil, page: nil))
    }

    @Test func theAppStoresOwnListDecidesOverItsListing() async {
        let page = URL(string: "https://apps.apple.com/app/id1")!
        var catalog = AppUpdates.Catalog()
        catalog.storeUpdates = [
            "com.bitwarden.desktop": .init(version: "2026.10.4", page: page, versionID: 2),
            "net.whatsapp.whatsapp": .init(version: "26.1", page: page, versionID: 7),
        ]
        // The listing says newer, but the App Store doesn't offer it.
        catalog.appStore["com.apple.keynote"] = ("15.4.2", page)
        func status(_ id: String, _ info: AppUpdates.AppInfo) async -> AppUpdates.Status {
            await AppUpdates.status(of: app(id, id: id, appStore: true), info: info, catalog: catalog, fetch: { _ in Data() })
        }
        // A new build with the same version is still an update.
        let bitwarden = await status("com.bitwarden.desktop", .init(shortVersion: "2026.10.4", build: "1", feed: nil, storeVersionID: 1))
        #expect(bitwarden == .available(.init(source: .appStore(page: page), latest: "2026.10.4", installed: "2026.10.4")))
        // Listed, but that release is what's installed.
        let whatsapp = await status("net.whatsapp.WhatsApp", .init(shortVersion: "26.1", build: "1", feed: nil, storeVersionID: 7))
        #expect(isUpToDate(whatsapp))
        let keynote = await status("com.apple.Keynote", .init(shortVersion: "15.4", build: "1", feed: nil))
        #expect(isUpToDate(keynote))

        // Without a recent App Store check, as when signed out, an empty list says nothing.
        catalog.storeUpdates = [:]
        catalog.storeListIsStale = true
        #expect(
            await status("com.apple.Keynote", .init(shortVersion: "15.4", build: "1", feed: nil)) == .unknown(AppUpdates.storeNotChecking))
    }

    private func isUpToDate(_ status: AppUpdates.Status) -> Bool {
        if case .upToDate = status { true } else { false }
    }

    @Test func feedsCompareBuildsAndShowShortVersions() async {
        let data = appcast(
            "<item><sparkle:version>183</sparkle:version><sparkle:shortVersionString>1.5.1</sparkle:shortVersionString></item>")
        let iina = app("IINA", id: "com.colliderli.iina")
        let behind = await AppUpdates.status(
            of: iina, info: .init(shortVersion: "1.5.0", build: "180", feed: feedURL), catalog: .init(), fetch: { _ in data })
        #expect(behind == .available(.init(source: .feed, latest: "1.5.1", installed: "1.5.0")))
        let current = await AppUpdates.status(
            of: iina, info: .init(shortVersion: "1.5.1", build: "183", feed: feedURL), catalog: .init(), fetch: { _ in data })
        #expect(current == .upToDate(.init(source: .feed, latest: "1.5.1", installed: "1.5.1")))
    }

    @Test func aFeedThatFailsFallsBackToHomebrew() async {
        var catalog = AppUpdates.Catalog()
        catalog.casks = { ["firefox.app": .init(token: "firefox", version: "133.0")] }
        let firefox = app("Firefox", id: "org.mozilla.firefox")
        let status = await AppUpdates.status(
            of: firefox, info: .init(shortVersion: "132.0", build: "1", feed: feedURL), catalog: catalog,
            fetch: { _ in throw URLError(.notConnectedToInternet) })
        #expect(status == .available(.init(source: .homebrew(cask: "firefox"), latest: "133.0", installed: "132.0")))
        let other = await AppUpdates.status(
            of: app("Other", id: "com.example.Other"), info: .init(shortVersion: "1", build: "1", feed: feedURL),
            catalog: catalog, fetch: { _ in throw URLError(.notConnectedToInternet) })
        #expect(other == .unknown("Couldn't read its update feed"))
        let none = await AppUpdates.status(
            of: app("Other", id: "com.example.Other"), info: .init(shortVersion: "1", build: "1", feed: nil),
            catalog: catalog, fetch: { _ in Data() })
        #expect(none == .unknown(AppUpdates.noSource))
    }

    @Test func homebrewVersionsIgnoreTrailingZerosAndBackFeedsWithoutBuilds() async {
        var catalog = AppUpdates.Catalog()
        catalog.casks = { ["foo.app": .init(token: "foo", version: "3.2.0")] }
        let foo = app("Foo", id: "com.example.Foo")
        let same = await AppUpdates.status(
            of: foo, info: .init(shortVersion: "3.2", build: "1", feed: nil), catalog: catalog, fetch: { _ in Data() })
        #expect(same == .upToDate(.init(source: .homebrew(cask: "foo"), latest: "3.2.0", installed: "3.2")))
        // The feed is read but the app has no build to compare, so Homebrew decides.
        let data = appcast("<item><sparkle:version>9</sparkle:version></item>")
        let noBuild = await AppUpdates.status(
            of: foo, info: .init(shortVersion: "3.1", build: nil, feed: feedURL), catalog: catalog, fetch: { _ in data })
        #expect(noBuild == .available(.init(source: .homebrew(cask: "foo"), latest: "3.2.0", installed: "3.1")))
    }

    @Test func homebrewsOwnRecordDecidesWhenItsCurrent() async {
        var catalog = AppUpdates.Catalog()
        // The cask writes versions unlike the app, so only Homebrew's record can tell it's current.
        catalog.casks = { ["foo.app": .init(token: "foo", version: "1.2.3-456", installed: "1.2.3-456")] }
        let foo = app("Foo", id: "com.example.Foo")
        let current = await AppUpdates.status(
            of: foo, info: .init(shortVersion: "1.2.3", build: "1", feed: nil), catalog: catalog, fetch: { _ in Data() })
        #expect(current == .upToDate(.init(source: .homebrew(cask: "foo"), latest: "1.2.3-456", installed: "1.2.3")))
        catalog.casks = { ["foo.app": .init(token: "foo", version: "1.3", installed: "1.2")] }
        let behind = await AppUpdates.status(
            of: foo, info: .init(shortVersion: "1.2", build: "1", feed: nil), catalog: catalog, fetch: { _ in Data() })
        #expect(behind == .available(.init(source: .homebrew(cask: "foo"), latest: "1.3", installed: "1.2")))
    }

    @Test func storeUpdatesLinkTheAppsPageNotItsDevelopers() {
        let data = Data(
            #"{"attributes": {"artistUrl": "https://apps.apple.com/us/developer/x/id9", "url": "https://apps.apple.com/us/app/x/id1"}}"#
                .utf8)
        #expect(AppUpdates.parseStoreUpdate(data).page == URL(string: "https://apps.apple.com/us/app/x/id1"))
        let nested = Data(
            #"{"a": {"artistViewUrl": "https://apps.apple.com/us/developer/x/id9", "z": "https://apps.apple.com/us/app/x/id1"}}"#.utf8)
        #expect(AppUpdates.parseStoreUpdate(nested).page == URL(string: "https://apps.apple.com/us/app/x/id1"))
    }

    @MainActor
    @Test func listingLeavesOutAppsUninstalledMeanwhileAndRefreshesAfterALoad() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AppUpdatesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Foo", "Bar"] {
            let contents = root.appending(path: "\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (["CFBundleIdentifier": "com.example.\(name)"] as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        }
        let list = InstalledAppList(folders: [root], readsDetails: false)
        let first = Task { await list.load() }
        // Asked to refresh while the first listing runs, and Bar goes meanwhile.
        try FileManager.default.removeItem(at: root.appending(path: "Bar.app"))
        await list.load(refresh: true)
        await first.value
        #expect(list.apps.map(\.name) == ["Foo"])
    }

    @MainActor
    @Test func aCheckFinishesWhenItsCallerIsCancelledAndKeepsOldResultsMeanwhile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AppUpdatesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appending(path: "Feedy.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.example.Feedy"] as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        let feed = feedURL
        let data = appcast("<item><sparkle:version>2</sparkle:version></item>")
        let list = InstalledAppList(folders: [root], readsDetails: false)
        let checker = AppUpdateChecker(
            list: list,
            fetch: { _ in
                // A cancelled fetch fails, as URLSession's does.
                try await Task.sleep(for: .milliseconds(50))
                return data
            },
            findBrew: { nil }, readInfo: { _ in .init(shortVersion: "1", build: "1", feed: feed) },
            readStoreUpdates: { [:] }, readStoreLastCheck: { .now })

        // Asked before the list has loaded: the check waits for it rather than checking nothing.
        let first = Task { await checker.check() }
        first.cancel()
        await checker.check()
        #expect(checker.available.map(\.name) == ["Feedy"])

        // A second check keeps the first's results until its own come in.
        let second = Task { await checker.check() }
        await Task.yield()
        #expect(checker.isChecking)
        #expect(checker.available.map(\.name) == ["Feedy"])
        await second.value
        #expect(checker.available.map(\.name) == ["Feedy"])
    }

    @MainActor
    @Test func checkerFindsEachAppsStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AppUpdatesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, id) in [("Feedy", "com.example.Feedy"), ("Plain", "com.example.Plain")] {
            let contents = root.appending(path: "\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (["CFBundleIdentifier": id] as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        }
        let feed = feedURL
        let data = appcast("<item><sparkle:version>2</sparkle:version></item>")
        let checker = AppUpdateChecker(
            list: InstalledAppList(folders: [root], readsDetails: false), fetch: { _ in data }, findBrew: { nil },
            readInfo: { url in
                .init(shortVersion: "1", build: "1", feed: url.lastPathComponent == "Feedy.app" ? feed : nil)
            },
            readStoreUpdates: { [:] }, readStoreLastCheck: { .now })
        await checker.check()
        #expect(checker.available.map(\.name) == ["Feedy"])
        let feedy = try #require(checker.available.first)
        #expect(checker.update(for: feedy) == .init(source: .feed, latest: "2", installed: "1"))
        let plain = try #require(checker.list.apps.first { $0.name == "Plain" })
        #expect(checker.update(for: plain) == nil)
        #expect(checker.statuses[plain.id] == .unknown(AppUpdates.noSource))
        #expect(checker.checkedAt != nil)
    }
}

private actor AskedURLs {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}
