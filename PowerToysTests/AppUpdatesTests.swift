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
        _ = await AppUpdates.appStoreVersions((0..<120).map { "com.example.\($0)" }, region: "IN") { request in
            await asked.add(request.url!)
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

    @Test func parsesHomebrewsPublicListPreferringTheMainCask() {
        let data = Data(
            """
            [
              {"token": "ghostty@tip", "version": "18758,7117", "artifacts": [{"app": ["Ghostty.app"]}]},
              {"token": "ghostty", "version": "1.4.0", "artifacts": [{"app": ["Ghostty.app"]}]},
              {"token": "thunderbird", "version": "159.0", "artifacts": [{"app": ["Thunderbird.app"]}]},
              {"token": "thunderbird@esr", "version": "153.6.0esr", "artifacts": [{"app": ["Thunderbird.app"]}]},
              {"token": "zoom-for-it-admins", "version": "6.3.0", "artifacts": [{"app": ["zoom.us.app"]}]},
              {"token": "zoom", "version": "6.2.11", "artifacts": [{"app": ["zoom.us.app"]}]},
              {"token": "gone", "version": "1.0", "disabled": true, "artifacts": [{"app": ["Gone.app"]}]}
            ]
            """.utf8)
        let casks = AppUpdates.parseCasks(data, skippingDisabled: true)
        #expect(casks["ghostty.app"] == .init(token: "ghostty", version: "1.4.0"))
        #expect(casks["thunderbird.app"] == .init(token: "thunderbird", version: "159.0"))
        #expect(casks["zoom.us.app"]?.token == "zoom")
        #expect(casks["gone.app"] == nil)
        // A disabled cask Homebrew installed is still what Homebrew has.
        #expect(AppUpdates.parseCasks(data)["gone.app"]?.token == "gone")
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

    // MARK: Google Update

    private let chrome = AppUpdates.GoogleUpdate(
        product: "com.google.Chrome", server: URL(string: "https://tools.google.com/service/update2")!, channel: "universal")

    private func googleAnswer(_ check: String) -> Data {
        Data(
            """
            )]}'
            {"response":{"protocol":"3.1","app":[{"appid":"com.google.Chrome","status":"ok","updatecheck":\(check)}]}}
            """.utf8)
    }

    @Test func parsesGoogleUpdateAnswers() {
        func parse(_ data: Data) -> String? { AppUpdates.parseGoogleUpdate(data, installed: "157") }
        #expect(parse(googleAnswer(#"{"status":"ok","manifest":{"version":"158.0.1.2"}}"#)) == "158.0.1.2")
        #expect(parse(googleAnswer(#"{"status":"noupdate"}"#)) == "157")
        #expect(parse(googleAnswer(#"{"status":"error-unknownApplication"}"#)) == nil)
        #expect(parse(Data("<html>".utf8)) == nil)
    }

    @Test func readsGoogleUpdateKeysFromInfoPlist() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AppUpdatesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func info(_ plist: [String: String]) throws -> AppUpdates.AppInfo {
            let app = root.appending(path: "\(UUID().uuidString).app")
            let contents = app.appending(path: "Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (plist as NSDictionary).write(to: contents.appending(path: "Info.plist"))
            return AppUpdates.AppInfo(app)
        }
        let chrome = try info([
            "KSProductID": "com.google.Chrome", "KSUpdateURL": " https://tools.google.com/service/update2 ", "KSChannelID": "universal",
        ])
        // The channel and cohort can come from this Mac's own updater, so only the rest is compared.
        #expect(chrome.googleUpdate?.product == self.chrome.product)
        #expect(chrome.googleUpdate?.server == self.chrome.server)
        let noChannel = try info(["KSProductID": "com.brave.Browser", "KSUpdateURL": "https://updates.bravesoftware.com/json"])
        #expect(noChannel.googleUpdate?.channel == nil)
        #expect(try info(["KSProductID": "com.example", "KSUpdateURL": "http://example.com/update2"]).googleUpdate == nil)
        #expect(try info(["KSProductID": "com.example"]).googleUpdate == nil)
        #expect(try info(["KSUpdateURL": "https://example.com/update2"]).googleUpdate == nil)
    }

    @Test func asksGoogleUpdateForTheInstalledVersionOnItsChannel() throws {
        let request = AppUpdates.googleUpdateRequest(
            chrome, version: "157.0.8103.39", system: .init(majorVersion: 27, minorVersion: 2, patchVersion: 0))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://tools.google.com/service/update2/json")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let inner = try #require(body["request"] as? [String: Any])
        #expect(inner["acceptformat"] as? String != nil)
        let app = try #require((inner["app"] as? [[String: Any]])?.first)
        #expect(app["appid"] as? String == "com.google.Chrome")
        #expect(app["version"] as? String == "157.0.8103.39")
        #expect(app["ap"] as? String == "universal")
        #expect(app["cohort"] == nil)
        var grouped = chrome
        grouped.cohort = "1:1y5/23r:"
        grouped.brand = "GGRO"
        let groupedApp = try #require(
            ((try JSONSerialization.jsonObject(with: AppUpdates.googleUpdateRequest(grouped, version: "1").httpBody!) as? [String: Any])?[
                "request"] as? [String: Any])?["app"] as? [[String: Any]])
        #expect(groupedApp.first?["cohort"] as? String == "1:1y5/23r:")
        #expect(groupedApp.first?["brand"] as? String == "GGRO")
        let brave = AppUpdates.GoogleUpdate(
            product: "com.brave.Browser", server: URL(string: "https://updates.bravesoftware.com/prod/service/update2/json")!,
            channel: nil)
        let braveRequest = AppUpdates.googleUpdateRequest(brave, version: "1")
        #expect(braveRequest.url?.absoluteString == "https://updates.bravesoftware.com/prod/service/update2/json")
    }

    @Test func readsTheCohortGooglesUpdaterKeeps() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AppUpdatesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefs = folder.appending(path: "prefs.json")
        try Data(#"{"updateclientdata": {"apps": {"com.google.chrome": {"ap": "beta-arm64", "cohort": "1:1y5/23r:", "bc": "GGRO"}}}}"#.utf8)
            .write(to: prefs)
        let missing = folder.appending(path: "none.json")
        let stored = AppUpdates.GoogleUpdate.stored(product: "com.google.Chrome", prefs: [missing, prefs])
        #expect(stored.cohort == "1:1y5/23r:")
        #expect(stored.brand == "GGRO")
        #expect(stored.channel == "beta-arm64")
        #expect(AppUpdates.GoogleUpdate.stored(product: "com.brave.Browser", prefs: [prefs]).cohort == nil)
    }

    @Test func googleUpdateAppsAreCheckedWithTheService() async {
        let info = AppUpdates.AppInfo(shortVersion: "157.0.8103.39", build: "8103.39", feed: nil, googleUpdate: chrome)
        let browser = app("Google Chrome", id: "com.google.Chrome")
        let offered = googleAnswer(#"{"status":"ok","manifest":{"version":"157.0.8103.51"}}"#)
        let behind = await AppUpdates.status(of: browser, info: info, catalog: .init(), fetch: { _ in offered })
        #expect(behind == .available(.init(source: .googleUpdate, latest: "157.0.8103.51", installed: "157.0.8103.39")))
        let none = googleAnswer(#"{"status":"noupdate"}"#)
        let current = await AppUpdates.status(of: browser, info: info, catalog: .init(), fetch: { _ in none })
        #expect(current == .upToDate(.init(source: .googleUpdate, latest: "157.0.8103.39", installed: "157.0.8103.39")))
        // Unreachable, it falls back to Homebrew like a feed does.
        var catalog = AppUpdates.Catalog()
        catalog.casks = { ["google chrome.app": .init(token: "google-chrome", version: "158.0")] }
        let offline = await AppUpdates.status(
            of: browser, info: info, catalog: catalog, fetch: { _ in throw URLError(.notConnectedToInternet) })
        #expect(offline == .available(.init(source: .homebrew(cask: "google-chrome"), latest: "158.0", installed: "157.0.8103.39")))
        // A feed that fails still leaves the service to ask.
        let both = AppUpdates.AppInfo(shortVersion: "157.0.8103.39", build: "1", feed: feedURL, googleUpdate: chrome)
        let fallback = await AppUpdates.status(of: browser, info: both, catalog: .init()) { request in
            guard request.httpMethod == "POST" else { throw URLError(.badServerResponse) }
            return offered
        }
        #expect(fallback == .available(.init(source: .googleUpdate, latest: "157.0.8103.51", installed: "157.0.8103.39")))
    }

    // MARK: VS Code

    private let vsCode = AppUpdates.VSCodeUpdate(
        server: URL(string: "https://update.code.visualstudio.com")!, quality: "stable", commit: "c4453f8")

    @Test func readsVSCodesProductJSON() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AppUpdatesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func update(_ product: [String: String]) throws -> AppUpdates.VSCodeUpdate? {
            let app = root.appending(path: "\(UUID().uuidString).app")
            let resources = app.appending(path: "Contents/Resources/app")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: product).write(to: resources.appending(path: "product.json"))
            return AppUpdates.AppInfo(app).vsCodeUpdate
        }
        #expect(try update(["updateUrl": "https://update.code.visualstudio.com", "quality": "stable", "commit": "c4453f8"]) == vsCode)
        #expect(try update(["updateUrl": "http://example.com", "quality": "stable", "commit": "1"]) == nil)
        #expect(try update(["quality": "stable", "commit": "1"]) == nil)
        #expect(AppUpdates.AppInfo(root.appending(path: "None.app")).vsCodeUpdate == nil)
    }

    @Test func vsCodeIsCheckedWithItsService() async {
        let url = AppUpdates.vsCodeUpdateURL(vsCode).absoluteString
        #expect(url.hasPrefix("https://update.code.visualstudio.com/api/update/darwin"))
        #expect(url.hasSuffix("/stable/c4453f8"))
        let info = AppUpdates.AppInfo(shortVersion: "1.145.2", build: "1.145.2", feed: nil, vsCodeUpdate: vsCode)
        let code = app("Visual Studio Code", id: "com.microsoft.VSCode")
        let offered = Data(#"{"name":"1.146.0","productVersion":"1.146.0","version":"abc"}"#.utf8)
        let behind = await AppUpdates.status(of: code, info: info, catalog: .init(), fetch: { _ in offered })
        #expect(behind == .available(.init(source: .vsCodeUpdate, latest: "1.146.0", installed: "1.145.2")))
        // The service answers 204, with nothing, when there's no update.
        let current = await AppUpdates.status(
            of: code, info: info, catalog: .init(), fetch: { _ in throw URLError(.zeroByteResource) })
        #expect(current == .upToDate(.init(source: .vsCodeUpdate, latest: "1.145.2", installed: "1.145.2")))
        let broken = await AppUpdates.status(of: code, info: info, catalog: .init(), fetch: { _ in Data("<html>".utf8) })
        #expect(broken == .unknown("Couldn't read its update service"))
    }

    // MARK: Homebrew

    @Test func homebrewsPublicListIsAnEstimateUsedLast() async {
        var catalog = AppUpdates.Catalog()
        catalog.caskCatalog = { ["rancher desktop.app": .init(token: "rancher", version: "1.25.0")] }
        let rancher = app("Rancher Desktop", id: "io.rancherdesktop.app")
        let info = AppUpdates.AppInfo(shortVersion: "1.24.0", build: "1", feed: nil)
        let estimate = await AppUpdates.status(of: rancher, info: info, catalog: catalog, fetch: { _ in Data() })
        #expect(estimate == .available(.init(source: .homebrewCatalog(cask: "rancher"), latest: "1.25.0", installed: "1.24.0")))
        #expect(!AppUpdates.Source.homebrewCatalog(cask: "rancher").isExact)
        #expect(AppUpdates.Source.homebrew(cask: "rancher").isExact)
        // What Homebrew installed decides first.
        catalog.casks = { ["rancher desktop.app": .init(token: "rancher", version: "1.24.0", installed: "1.24.0")] }
        let installed = await AppUpdates.status(of: rancher, info: info, catalog: catalog, fetch: { _ in Data() })
        #expect(installed == .upToDate(.init(source: .homebrew(cask: "rancher"), latest: "1.24.0", installed: "1.24.0")))
        // As does the app's own updater.
        catalog.casks = { [:] }
        let vsInfo = AppUpdates.AppInfo(shortVersion: "1.24.0", build: "1", feed: nil, vsCodeUpdate: vsCode)
        let own = await AppUpdates.status(of: rancher, info: vsInfo, catalog: catalog, fetch: { _ in Data() })
        #expect(own == .upToDate(.init(source: .vsCodeUpdate, latest: "1.24.0", installed: "1.24.0")))
        // When the app's own source fails, that's said, not replaced by the list's version.
        let failed = await AppUpdates.status(
            of: rancher, info: vsInfo, catalog: catalog, fetch: { _ in throw URLError(.notConnectedToInternet) })
        #expect(failed == .unknown("Couldn't read its update service"))
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

    @MainActor
    @Test func homebrewsPublicListIsDownloadedOnceAndOnlyWhenNeeded() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AppUpdatesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["One", "Two", "Three"] {
            let contents = root.appending(path: "\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (["CFBundleIdentifier": "com.example.\(name)"] as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        }
        let list = Data(#"[{"token": "one", "version": "2", "artifacts": [{"app": ["One.app"]}]}]"#.utf8)
        let feed = feedURL
        let appcast = appcast("<item><sparkle:version>1</sparkle:version></item>")
        func checker(feeds: Bool, asked: AskedURLs) -> AppUpdateChecker {
            AppUpdateChecker(
                list: InstalledAppList(folders: [root], readsDetails: false),
                fetch: { request in
                    await asked.add(request.url!)
                    return request.url == AppUpdates.caskCatalogURL ? list : appcast
                },
                findBrew: { nil }, readInfo: { _ in .init(shortVersion: "1", build: "1", feed: feeds ? feed : nil) },
                readStoreUpdates: { [:] }, readStoreLastCheck: { .now })
        }
        let asked = AskedURLs()
        let estimating = checker(feeds: false, asked: asked)
        await estimating.check()
        #expect(await asked.urls.filter { $0 == AppUpdates.caskCatalogURL }.count == 1)
        #expect(estimating.available.map(\.name) == ["One"])
        let answered = AskedURLs()
        await checker(feeds: true, asked: answered).check()
        #expect(await answered.urls.contains(AppUpdates.caskCatalogURL) == false)
    }
}

private actor AskedURLs {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}
