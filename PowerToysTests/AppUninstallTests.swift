import Foundation
import Synchronization
import Testing

@testable import PowerToys

struct AppUninstallTests {
    /// A throwaway folder that stands in for the home folder, with an Apps folder beside it.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "AppUninstallTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeApp(_ path: String, id: String?, in root: URL, version: String = "1.0") throws -> URL {
        let url = root.appending(path: path)
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleShortVersionString": version]
        if let id { info["CFBundleIdentifier"] = id }
        try (info as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        try Data(count: 4096).write(to: contents.appending(path: "MacOS/app"))
        return url
    }

    private func makeFile(_ path: String, in root: URL, bytes: Int = 1000) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func app(_ url: URL, id: String) -> InstalledApp {
        InstalledApp(
            url: url, bundleID: id, name: url.deletingPathExtension().lastPathComponent, version: "1.0", isAppStore: false,
            size: 4096)
    }

    @Test func listsAppsInFoldersAndOneLevelDown() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appending(path: "Applications")
        try makeApp("Applications/Foo.app", id: "com.example.Foo", in: root, version: "2.1")
        try makeApp("Applications/Utilities/Bar.app", id: "com.example.Bar", in: root)
        try makeApp("Applications/NoID.app", id: nil, in: root)
        try makeApp("Applications/Own.app", id: "com.self.PowerToys", in: root)
        try makeFile("Applications/Foo.app/Contents/_MASReceipt/receipt", in: root)
        try FileManager.default.createSymbolicLink(
            at: apps.appending(path: "Linked.app"), withDestinationURL: apps.appending(path: "Foo.app"))

        let listed = AppUninstall.list(in: [apps], excluding: "com.self.PowerToys", withDetails: false)
        #expect(listed.map(\.name) == ["Bar", "Foo"])
        let foo = try #require(listed.last)
        #expect(foo.bundleID == "com.example.Foo")
        #expect(foo.version == "2.1")
        #expect(foo.isAppStore)
        #expect(listed.first?.isAppStore == false)
    }

    @Test func findsTheAppsDataInLibrary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp("Applications/Foo.app", id: "com.example.Foo", in: root)
        for path in [
            "Library/Containers/com.example.Foo/x", "Library/Preferences/com.example.Foo.plist",
            "Library/Caches/com.example.Foo/x", "Library/Logs/Foo/x", "Library/Application Support/Foo/x",
            "Library/Group Containers/group.com.example.Foo/x", "Library/Group Containers/ABCDE12345.com.example.Foo/x",
            // Another app's, from the same developer, and one that only starts like it.
            "Library/Containers/com.example.Other/x", "Library/Group Containers/ABCDE12345.com.example.Foo.Other/x",
            "Library/Application Support/Foobar/x",
        ] {
            try makeFile(path, in: root)
        }
        let agents = root.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try (["Label": "com.example.Foo"] as NSDictionary).write(to: agents.appending(path: "com.example.Foo.plist"))
        // Another app whose ID only starts with this one's, as Chrome Canary's does Chrome's.
        try (["Label": "com.example.Foo.canary.update"] as NSDictionary)
            .write(to: agents.appending(path: "com.example.Foo.canary.update.plist"))
        try (["Label": "org.updater", "ProgramArguments": [url.path + "/Contents/MacOS/updater", "--check"]] as NSDictionary)
            .write(to: agents.appending(path: "org.updater.plist"))
        try (["Label": "org.unrelated", "Program": "/usr/local/bin/thing"] as NSDictionary)
            .write(to: agents.appending(path: "org.unrelated.plist"))

        let context = AppUninstall.Context(home: root, activity: .idle())
        let items = AppUninstall.footprint(of: app(url, id: "com.example.Foo"), context: context)
        #expect(items.first?.name == "App · Foo.app")
        #expect(
            Set(items.dropFirst().map(\.name)) == [
                "Container · com.example.Foo", "Settings · com.example.Foo.plist", "Caches · com.example.Foo",
                "Logs · Foo", "App data · Foo", "Shared container · group.com.example.Foo",
                "Shared container · ABCDE12345.com.example.Foo", "Launch agent · com.example.Foo.plist",
                "Launch agent · org.updater.plist",
            ])
        #expect(items.allSatisfy { $0.skipReason == nil })
        #expect(items.dropFirst().allSatisfy { $0.size > 0 })

        // Folders named like the app aren't taken when another app has the same name.
        var shared = context
        shared.otherAppNames = ["foo"]
        let named = AppUninstall.footprint(of: app(url, id: "com.example.Foo"), context: shared)
        #expect(!named.contains { $0.name == "Logs · Foo" || $0.name == "App data · Foo" })
    }

    @Test func leavesEverythingWhileTheAppIsOpen() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp("Applications/Foo.app", id: "com.example.Foo", in: root)
        try makeFile("Library/Preferences/com.example.Foo.plist", in: root)
        // Anything of this user's running from the bundle, such as an extension that runs while the
        // app is closed, counts as the app being open.
        let open = AppUninstall.Context(
            home: root, activity: .idle(), bundleProcesses: [.init(pid: 42, isMine: true)])
        let items = AppUninstall.footprint(of: app(url, id: "com.example.Foo"), context: open)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.skipReason == AppUninstall.openReason })

        // Another user's copy can't be quit from here, so it's told apart.
        let theirs = AppUninstall.Context(home: root, activity: .idle(), bundleProcesses: [.init(pid: 42, isMine: false)])
        #expect(
            AppUninstall.footprint(of: app(url, id: "com.example.Foo"), context: theirs).allSatisfy {
                $0.skipReason == AppUninstall.openForAnotherUserReason
            })

        // Another copy with the same ID running, as the bundle ID shows, doesn't count.
        let other = AppUninstall.Context(home: root, activity: .idle(apps: ["com.example.foo"]))
        #expect(AppUninstall.footprint(of: app(url, id: "com.example.Foo"), context: other).allSatisfy { $0.skipReason == nil })
    }

    @Test func containersNeedFullDiskAccess() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp("Applications/Foo.app", id: "com.example.Foo", in: root)
        try makeFile("Library/Containers/com.example.Foo/x", in: root)
        try makeFile("Library/Group Containers/group.com.example.Foo/x", in: root)
        try makeFile("Library/Preferences/com.example.Foo.plist", in: root)
        let context = AppUninstall.Context(home: root, activity: .idle(), canChangeAppContainers: false)
        let reasons = Dictionary(
            uniqueKeysWithValues: AppUninstall.footprint(of: app(url, id: "com.example.Foo"), context: context).map {
                ($0.name, $0.skipReason)
            })
        #expect(reasons["Container · com.example.Foo"] == AppLeftovers.needsFullDiskAccess)
        #expect(reasons["Shared container · group.com.example.Foo"] == AppLeftovers.needsFullDiskAccess)
        #expect(reasons["Settings · com.example.Foo.plist"] == .some(nil))
        #expect(reasons["App · Foo.app"] == .some(nil))
    }

    /// Moves items into a folder of the test's own, and counts what each part was asked to do.
    private final class FakeRemoval: Sendable {
        let trashFolder: URL
        let failing: Set<String>
        let finderCalls = Mutex<[String]>([])
        let unloaded = Mutex<[String]>([])
        let reloaded = Mutex<[String]>([])

        init(trashFolder: URL, failing: Set<String> = []) {
            self.trashFolder = trashFolder
            self.failing = failing
        }

        var remover: AppUninstall.Remover {
            AppUninstall.Remover(
                trash: { [self] url in
                    if failing.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
                    try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: url, to: trashFolder.appending(path: UUID().uuidString))
                },
                trashWithFinder: { [self] url in
                    finderCalls.withLock { $0.append(url.lastPathComponent) }
                    throw CommandError(errorDescription: "Cancelled")
                },
                unloadAgent: { [self] url in
                    unloaded.withLock { $0.append(url.lastPathComponent) }
                    return true
                },
                reloadAgent: { [self] url in reloaded.withLock { $0.append(url.lastPathComponent) } })
        }
    }

    @Test func removesOnlyWhatWasReviewed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp("Applications/Foo.app", id: "com.example.Foo", in: root)
        try makeFile("Library/Preferences/com.example.Foo.plist", in: root)
        try makeFile("Library/Caches/com.example.Foo/x", in: root)
        let agents = root.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try (["Label": "com.example.Foo"] as NSDictionary).write(to: agents.appending(path: "com.example.Foo.plist"))
        let fake = FakeRemoval(trashFolder: root.appending(path: "Trash"))
        let foo = app(url, id: "com.example.Foo")
        let caches = root.appending(path: "Library/Caches/com.example.Foo")
        let agent = agents.appending(path: "com.example.Foo.plist")

        let removal = await AppUninstall.remove(
            foo, reviewed: [url.path, agent.path], sizes: [url.path: 10, agent.path: 5],
            context: AppUninstall.Context(home: root, activity: .idle()), remover: fake.remover)
        #expect(removal == AppUninstall.Removal(trashed: 15, removedApp: true, removedItems: 1))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: agent.path))
        #expect(FileManager.default.fileExists(atPath: caches.path))
        #expect(fake.unloaded.withLock { $0 } == ["com.example.Foo.plist"])
    }

    @Test func keepsTheDataWhenTheAppCantGo() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp("Applications/Foo.app", id: "com.example.Foo", in: root)
        try makeFile("Library/Preferences/com.example.Foo.plist", in: root)
        let prefs = root.appending(path: "Library/Preferences/com.example.Foo.plist")
        let fake = FakeRemoval(trashFolder: root.appending(path: "Trash"), failing: ["Foo.app"])

        let removal = await AppUninstall.remove(
            app(url, id: "com.example.Foo"), reviewed: [url.path, prefs.path], sizes: [:],
            context: AppUninstall.Context(home: root, activity: .idle()), remover: fake.remover)
        // Finder was asked, since the app needed more permission; it was cancelled.
        #expect(fake.finderCalls.withLock { $0 } == ["Foo.app"])
        #expect(!removal.removedApp)
        #expect(removal.removedItems == 0)
        #expect(removal.failures == ["App · Foo.app: Cancelled"])
        #expect(FileManager.default.fileExists(atPath: prefs.path))
    }

    @Test func removesOnlyTheDataWhenTheAppIsUnticked() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp("Applications/Foo.app", id: "com.example.Foo", in: root)
        try makeFile("Library/Preferences/com.example.Foo.plist", in: root)
        let prefs = root.appending(path: "Library/Preferences/com.example.Foo.plist")
        let fake = FakeRemoval(trashFolder: root.appending(path: "Trash"))

        let removal = await AppUninstall.remove(
            app(url, id: "com.example.Foo"), reviewed: [prefs.path], sizes: [prefs.path: 7],
            context: AppUninstall.Context(home: root, activity: .idle()), remover: fake.remover)
        #expect(removal == AppUninstall.Removal(trashed: 7, removedApp: false, removedItems: 1))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func matchesSharedContainersByExactName() {
        #expect(AppUninstall.isSharedContainer("group.com.example.Foo", of: "com.example.Foo"))
        #expect(AppUninstall.isSharedContainer("ABCDE12345.com.example.foo", of: "com.example.Foo"))
        #expect(!AppUninstall.isSharedContainer("ABCDE12345.com.example.Foo.Other", of: "com.example.Foo"))
        #expect(!AppUninstall.isSharedContainer("group.com.example", of: "com.example.Foo"))
        #expect(!AppUninstall.isSharedContainer("abcde12345.com.example.Foo", of: "com.example.Foo"))
    }

    @Test func leavesDataAnotherCopyWithTheSameIDUses() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp("Applications/Foo Beta.app", id: "com.example.Foo", in: root)
        try makeFile("Library/Preferences/com.example.Foo.plist", in: root)
        try makeFile("Library/Group Containers/group.com.example.Foo/x", in: root)
        let agents = root.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try (["Label": "com.example.Foo"] as NSDictionary).write(to: agents.appending(path: "com.example.Foo.plist"))
        try (["Label": "beta.updater", "Program": url.path + "/Contents/MacOS/updater"] as NSDictionary)
            .write(to: agents.appending(path: "beta.updater.plist"))
        let other = app(root.appending(path: "Applications/Foo.app"), id: "com.example.Foo")
        let context = AppUninstall.Context(home: root, activity: .idle(), otherApps: [other])
        let items = AppUninstall.footprint(of: app(url, id: "com.example.Foo"), context: context)
        // Only the bundle and what runs from it.
        #expect(items.map(\.name) == ["App · Foo Beta.app", "Launch agent · beta.updater.plist"])
        // The same for a copy outside the listed folders, which Launch Services knows.
        let elsewhere = AppUninstall.Context(home: root, activity: .idle(), otherCopyIDs: ["com.example.foo"])
        #expect(AppUninstall.footprint(of: app(url, id: "com.example.Foo"), context: elsewhere).count == 2)
    }

    @Test func findsAgentsThatRunTheAppWhateverTheCase() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp("Applications/Foo.app", id: "com.example.Foo", in: root)
        let agents = root.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try (["Label": "a", "Program": url.path.lowercased() + "/contents/macos/helper"] as NSDictionary)
            .write(to: agents.appending(path: "a.plist"))
        try (["Label": "b", "ProgramArguments": ["/usr/bin/open", "-g", url.path]] as NSDictionary)
            .write(to: agents.appending(path: "b.plist"))
        try (["Label": "c", "Program": url.path + "x/Contents/MacOS/other"] as NSDictionary)
            .write(to: agents.appending(path: "c.plist"))
        let found = AppUninstall.launchAgents(runningFrom: app(url, id: "com.example.Foo"), home: root)
        #expect(Set(found.map(\.lastPathComponent)) == ["a.plist", "b.plist"])
    }

    @Test func startsAnAgentAgainWhenItStays() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp("Applications/Foo.app", id: "com.example.Foo", in: root)
        let agents = root.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let agent = agents.appending(path: "com.example.Foo.plist")
        try (["Label": "com.example.Foo"] as NSDictionary).write(to: agent)
        let fake = FakeRemoval(trashFolder: root.appending(path: "Trash"), failing: ["com.example.Foo.plist"])

        let removal = await AppUninstall.remove(
            app(url, id: "com.example.Foo"), reviewed: [agent.path], sizes: [:],
            context: AppUninstall.Context(home: root, activity: .idle()), remover: fake.remover)
        #expect(removal.removedItems == 0)
        #expect(fake.unloaded.withLock { $0 } == ["com.example.Foo.plist"])
        #expect(fake.reloaded.withLock { $0 } == ["com.example.Foo.plist"])
    }

    @Test func summarisesWhatWent() {
        let foo = InstalledApp(
            url: URL(filePath: "/Applications/Foo.app"), bundleID: "com.example.Foo", name: "Foo", version: nil,
            isAppStore: false)
        #expect(
            AppUninstaller.summary(.init(trashed: 2_000_000, removedApp: true, removedItems: 2), app: foo)
                == "Moved Foo and 2 items of its data, \(CleanerController.format(2_000_000)), to the Trash.")
        #expect(
            AppUninstaller.summary(.init(trashed: 0, removedApp: false, removedItems: 0, failures: ["App · Foo.app: In use"]), app: foo)
                == "Nothing was removed. Couldn't remove App · Foo.app: In use.")
    }

    @MainActor
    @Test func uninstallLeavesTheListAndUnticksStick() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp("Applications/Foo.app", id: "com.example.Foo", in: root)
        try makeApp("Applications/Bar.app", id: "com.example.Bar", in: root)
        try makeFile("Library/Preferences/com.example.Foo.plist", in: root)
        let fake = FakeRemoval(trashFolder: root.appending(path: "Trash"))
        let list = InstalledAppList(folders: [root.appending(path: "Applications")], readsDetails: false)
        let uninstaller = AppUninstaller(
            list: list, home: root, readActivity: { .idle() }, fullDiskAccess: { true }, remover: fake.remover)

        try makeFile("Library/Application Support/Foo/x", in: root, bytes: 10)
        await uninstaller.list.load()
        #expect(uninstaller.apps.map(\.name) == ["Bar", "Foo"])
        // Listed once; a new app shows only after a refresh.
        try makeApp("Applications/Baz.app", id: "com.example.Baz", in: root)
        await uninstaller.list.load()
        #expect(uninstaller.apps.count == 2)
        await uninstaller.list.load(refresh: true)
        #expect(uninstaller.apps.map(\.name) == ["Bar", "Baz", "Foo"])
        let foo = try #require(uninstaller.apps.last)
        await uninstaller.inspect(foo)
        #expect(uninstaller.footprint.count == 3)
        #expect(uninstaller.removesApp)
        // A folder only named like the app starts unticked.
        let named = try #require(uninstaller.footprint.first { $0.name == "App data · Foo" })
        #expect(!uninstaller.willRemove(named))
        let prefs = try #require(uninstaller.footprint.first { $0.name == "Settings · com.example.Foo.plist" })
        uninstaller.setWillRemove(false, prefs)
        #expect(uninstaller.chosen.count == 1)

        await uninstaller.remove()
        #expect(uninstaller.apps.map(\.name) == ["Bar", "Baz"])
        #expect(uninstaller.inspected == nil)
        #expect(uninstaller.resultIsError == false)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Library/Preferences/com.example.Foo.plist").path))
    }
}
