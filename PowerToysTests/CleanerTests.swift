import Darwin
import Foundation
import Synchronization
import Testing

@testable import PowerToys

struct SystemUsageTests {
    @Test func cpuUsageIsTheBusyShareBetweenReads() {
        let earlier = CPUTicks(busy: 100, total: 1000)
        #expect(CPUTicks(busy: 350, total: 2000).usage(since: earlier) == 0.25)
        // Counters that went backwards, as after they wrap, give nothing rather than nonsense.
        #expect(CPUTicks(busy: 50, total: 900).usage(since: earlier) == nil)
        #expect(earlier.usage(since: earlier) == nil)
    }

    @Test func memoryCountsAppWiredAndCompressedPages() {
        var stats = vm_statistics64()
        stats.internal_page_count = 100
        stats.purgeable_count = 20
        stats.wire_count = 30
        stats.compressor_page_count = 10
        stats.free_count = 500
        let memory = MemoryUsage(stats: stats, pageSize: 16384, total: 16384 * 1000)
        #expect(memory.used == 120 * 16384)
        #expect(memory.fraction == 0.12)
    }

    @Test func storageUsedIsWhatIsntAvailable() {
        let storage = StorageUsage(total: 500, available: 125)
        #expect(storage.used == 375)
        #expect(storage.fraction == 0.75)
        #expect(StorageUsage.read() != nil)
    }

    @Test func parsesPsOutput() {
        let output = """
                1     0   0.0  13456 /sbin/launchd
              612   501  42.5 204800 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
              392     0   0.1   2048 autofsd
            bogus line

            """
        let processes = ProcessUsage.parse(ps: output)
        #expect(processes.count == 3)
        #expect(processes[1].uid == 501)
        #expect(processes[1].pid == 612)
        #expect(processes[1].cpu == 42.5)
        #expect(processes[1].memory == 204800 * 1024)
        #expect(processes[1].name == "Electron")
        #expect(processes[1].path.hasSuffix("Visual Studio Code.app/Contents/MacOS/Electron"))
    }
}

/// A throwaway home folder with a file of the given size at each path.
private func makeHome(_ files: [String: Int]) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "CleanerTests-\(UUID().uuidString)")
    for (path, bytes) in files {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }
    return home
}

extension Cleanup.Context {
    /// The same, with everything the target lists now reviewed and measured, as a confirmed clean
    /// has.
    func reviewing(_ target: CleanupTarget) async -> Cleanup.Context {
        var context = self
        let items = await Cleanup.scan(target, context: self).items
        context.reviewed = Set(items.map(\.id))
        context.sizes = Dictionary(items.map { ($0.id, $0.size) }) { first, _ in first }
        return context
    }
}

private func exists(_ home: URL, _ path: String) -> Bool {
    FileManager.default.fileExists(atPath: home.appending(path: path).path)
}

struct CleanupTests {
    @Test func cleansWhatsInTheFolderButKeepsIt() async throws {
        let home = try makeHome([
            "Library/Caches/com.example.app/blob": 200_000,
            "Library/Caches/loose": 50_000,
            "Library/Preferences/keep.plist": 10_000,
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let context = Cleanup.Context(home: home, activity: .idle())
        let scan = await Cleanup.scan(.caches, context: context)
        #expect(scan.items.map { $0.name } == ["com.example.app", "loose"])
        #expect(scan.size() >= 250_000)

        let log = home.appending(path: "log/cleaner.log")
        let freed = await Cleanup.clean(.caches, context: await context.reviewing(.caches), log: log)
        #expect(freed == scan.size())
        #expect(exists(home, "Library/Caches"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.appending(path: "Library/Caches").path).isEmpty)
        #expect(exists(home, "Library/Preferences/keep.plist"))
        let logged = try String(contentsOf: log, encoding: .utf8)
        #expect(logged.contains("Library/Caches/loose"))
        #expect(logged.contains("Library/Caches/com.example.app"))
    }

    @Test func claimsNothingForWhatCouldntBeDeleted() async throws {
        let home = try makeHome(["Library/Caches/a/x": 1000])
        let folder = home.appending(path: "Library/Caches/a")
        defer {
            chmod(folder.path, 0o755)
            try? FileManager.default.removeItem(at: home)
        }
        var context = Cleanup.Context(home: home, activity: .idle())
        let item = try #require(await Cleanup.scan(.caches, context: context).items.first)
        context.sizes = [item.id: 1000]
        // x can't be removed from a folder that can't be written to, so the folder stays.
        chmod(folder.path, 0o555)
        let events = Mutex<[CleanupEvent.Kind]>([])
        let freed = await Cleanup.clean(.caches, context: await context.reviewing(.caches), log: nil) { event in
            events.withLock { $0.append(event.kind) }
        }
        #expect(freed == 0)
        #expect(events.withLock { $0 } == [.failed("No permission")])
    }

    @Test func knowsWhenSomethingWasAlreadyGone() {
        #expect(Cleanup.isMissing(CocoaError(.fileNoSuchFile)))
        #expect(Cleanup.isMissing(POSIXError(.ENOENT)))
        #expect(!Cleanup.isMissing(POSIXError(.EPERM)))
        // EINTR shares the number of Cocoa's "no such file", in another domain.
        #expect(!Cleanup.isMissing(POSIXError(.EINTR)))
    }

    @Test func knowsWhenMacOSRefuses() throws {
        #expect(Cleanup.isNotPermitted(POSIXError(.EPERM)))
        #expect(
            Cleanup.isNotPermitted(NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)])))
        // A folder's own permissions are another matter.
        #expect(!Cleanup.isNotPermitted(POSIXError(.EACCES)))
        let home = try makeHome(["Library/Caches/a/x": 10])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!Cleanup.isProtectedByMacOS(home.appending(path: "Library/Caches/a")))
    }

    @Test func keepsWhatReachesAnotherDisk() throws {
        let home = try makeHome(["Library/Application Support/com.gone.App/x": 10])
        defer { try? FileManager.default.removeItem(at: home) }
        let item = home.appending(path: "Library/Application Support/com.gone.App")
        let folderVolume = Cleanup.volumeID(item.deletingLastPathComponent())
        #expect(Cleanup.diskReason(item, folderVolume: folderVolume, mounts: []) == nil)
        #expect(
            Cleanup.diskReason(item, folderVolume: folderVolume, mounts: [item.standardizedFileURL.path + "/Disk"])
                == "Another disk is inside")
    }

    @Test func leavesReadOnlyToolDownloadsAlone() async throws {
        // As DotSlash keeps a downloaded tool: a folder inside made read-only.
        let home = try makeHome(["Library/Caches/dotslash/bd/abc/Tool.app/x": 100, "Library/Caches/other/x": 100])
        let locked = home.appending(path: "Library/Caches/dotslash/bd/abc")
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: home)
        }
        chmod(locked.path, 0o555)
        let scan = await Cleanup.scan(.caches, context: Cleanup.Context(home: home, activity: .idle()))
        #expect(scan.items.first { $0.name == "dotslash" }?.skipReason == Cleanup.readOnlyReason)
        #expect(scan.cleanable.map(\.name) == ["other"])
    }

    @Test func letsNpmEmptyItsOwnCache() async throws {
        let home = try makeHome([".npm/_cacache/index-v5/x": 100, ".npm/_cacache/content-v2/x": 100, ".npm/_logs/a.log": 10])
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appending(path: ".npm/_cacache")
        let asked = Mutex<[[String]]>([])
        let npm = NpmCLI(path: "/opt/homebrew/bin/npm") { arguments, _ in
            asked.withLock { $0.append(arguments) }
            if arguments.first == "config" {
                return Command.Output(status: 0, stdout: home.appending(path: ".npm").path + "\n", stderr: "")
            }
            try FileManager.default.removeItem(at: cache)
            return Command.Output(status: 0, stdout: "", stderr: "")
        }
        var context = await Cleanup.Context(home: home, activity: .idle(), npm: npm).reviewing(.developerCaches)
        context.sizes = Dictionary(uniqueKeysWithValues: (context.reviewed ?? []).map { ($0, 100) })
        let events = Mutex<[CleanupEvent.Kind]>([])
        let freed = await Cleanup.clean(.developerCaches, context: context, log: nil) { event in
            events.withLock { $0.append(event.kind) }
        }
        #expect(asked.withLock { $0 } == [["config", "get", "cache"], ["cache", "clean", "--force"]])
        #expect(!exists(home, ".npm/_cacache"))
        // Logs aren't npm's cache, so they're deleted directly.
        #expect(!exists(home, ".npm/_logs/a.log"))
        #expect(freed == 300)
        #expect(!events.withLock { $0 }.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func deletesTheCacheItselfWhenNpmFailsOrSomethingIsKept() async throws {
        let home = try makeHome([".npm/_cacache/index-v5/x": 100, ".npm/_cacache/content-v2/x": 100])
        defer { try? FileManager.default.removeItem(at: home) }
        let asked = Mutex(0)
        let failing = NpmCLI(path: "/opt/homebrew/bin/npm") { arguments, _ in
            if arguments.first == "config" { return Command.Output(status: 0, stdout: NSHomeDirectory() + "/never\n", stderr: "") }
            asked.withLock { $0 += 1 }
            return Command.Output(status: 1, stdout: "", stderr: "npm ERR!")
        }
        var context = await Cleanup.Context(home: home, activity: .idle(), npm: failing).reviewing(.developerCaches)
        _ = await Cleanup.clean(.developerCaches, context: context, log: nil)
        // npm's cache is elsewhere, so npm isn't asked and the listed folder is deleted directly.
        #expect(asked.withLock { $0 } == 0)
        #expect(!exists(home, ".npm/_cacache/index-v5"))

        // With one part unticked, npm, which empties everything, isn't asked.
        let again = try makeHome([".npm/_cacache/index-v5/x": 100, ".npm/_cacache/content-v2/x": 100])
        defer { try? FileManager.default.removeItem(at: again) }
        context = await Cleanup.Context(home: again, activity: .idle(), npm: failing).reviewing(.developerCaches)
        context.kept = Set((context.reviewed ?? []).filter { $0.hasSuffix("/index-v5") })
        #expect(context.kept.count == 1)
        _ = await Cleanup.clean(.developerCaches, context: context, log: nil)
        #expect(asked.withLock { $0 } == 0)
        #expect(exists(again, ".npm/_cacache/index-v5/x"))
        #expect(!exists(again, ".npm/_cacache/content-v2"))
    }

    @Test func findsNpmWithNodeBesideIt() {
        let home = URL(filePath: "/Users/someone")
        let found = NpmCLI.find(home: home) { $0 == "/opt/homebrew/bin/npm" || $0 == "/opt/homebrew/bin/node" }
        #expect(found?.path == "/opt/homebrew/bin/npm")
        // npm without node beside it can't run.
        #expect(NpmCLI.find(home: home) { $0 == "/usr/local/bin/npm" } == nil)
    }

    @Test func npmThatFailsLeavesTheDeleteToTheCleaner() async throws {
        let home = try makeHome([".npm/_cacache/index-v5/x": 100])
        defer { try? FileManager.default.removeItem(at: home) }
        let failing = NpmCLI(path: "/opt/homebrew/bin/npm") { arguments, _ in
            if arguments.first == "config" { return Command.Output(status: 0, stdout: home.appending(path: ".npm").path, stderr: "") }
            return Command.Output(status: 1, stdout: "", stderr: "npm ERR!")
        }
        let context = await Cleanup.Context(home: home, activity: .idle(), npm: failing).reviewing(.developerCaches)
        _ = await Cleanup.clean(.developerCaches, context: context, log: nil)
        #expect(!exists(home, ".npm/_cacache/index-v5"))
    }

    @Test func countsWhatNpmRemovedBeforeFailing() async throws {
        let home = try makeHome([".npm/_cacache/index-v5/x": 100, ".npm/_cacache/content-v2/x": 100])
        defer { try? FileManager.default.removeItem(at: home) }
        let partial = NpmCLI(path: "/opt/homebrew/bin/npm") { arguments, _ in
            if arguments.first == "config" { return Command.Output(status: 0, stdout: home.appending(path: ".npm").path, stderr: "") }
            try FileManager.default.removeItem(at: home.appending(path: ".npm/_cacache/index-v5"))
            return Command.Output(status: 1, stdout: "", stderr: "npm ERR!")
        }
        var context = await Cleanup.Context(home: home, activity: .idle(), npm: partial).reviewing(.developerCaches)
        context.sizes = Dictionary(uniqueKeysWithValues: (context.reviewed ?? []).map { ($0, 100) })
        let deleted = Mutex<[String]>([])
        let freed = await Cleanup.clean(.developerCaches, context: context, log: nil) { event in
            if case .deleted = event.kind { deleted.withLock { $0.append(event.detail) } }
        }
        // What npm removed before failing is counted, and the cleaner deletes the rest.
        #expect(freed == 200)
        #expect(deleted.withLock { $0 }.count == 2)
        #expect(!exists(home, ".npm/_cacache/content-v2"))
    }

    @Test func waitsForCommandLineXcodeBuilds() async throws {
        let home = try makeHome(["Library/Developer/Xcode/DerivedData/App-abc/x": 100])
        defer { try? FileManager.default.removeItem(at: home) }
        let building = Cleanup.Context(
            home: home, activity: .idle(lines: ["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme App"]))
        #expect(await Cleanup.scan(.xcode, context: building).items.first?.skipReason == "xcodebuild is running")
    }

    @Test func deletesNothingThatWasntReviewed() async throws {
        let home = try makeHome(["Library/Caches/a/x": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        let context = Cleanup.Context(home: home, activity: .idle())
        #expect(await Cleanup.clean(.caches, context: context, log: nil) == 0)
        #expect(exists(home, "Library/Caches/a/x"))
    }

    @Test func leavesMacOSCachesAlone() async throws {
        let home = try makeHome(["Library/Caches/com.apple.nsurlsessiond/x": 1000, "Library/Caches/com.example.App/x": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        let scan = await Cleanup.scan(.caches, context: Cleanup.Context(home: home, activity: .idle()))
        #expect(scan.items.first { $0.name == "com.apple.nsurlsessiond" }?.skipReason == "Part of macOS")
        #expect(scan.cleanable.map(\.name) == ["com.example.App"])
    }

    @Test func leavesXcodeDataAloneWhenItCantTellIfXcodeIsOpen() async throws {
        let home = try makeHome(["Library/Developer/Xcode/DerivedData/App-abc/x": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        // Open files could be listed, but not the processes.
        let context = Cleanup.Context(home: home, activity: ActivitySnapshot(commandLines: nil, bundleIDs: [], openFiles: []))
        #expect(await Cleanup.scan(.xcode, context: context).items.first?.skipReason == Cleanup.unknownUse)
    }

    @Test func usesTheSizeTheListMeasured() async throws {
        let home = try makeHome(["Library/Caches/a/x": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        var context = await Cleanup.Context(home: home, activity: .idle()).reviewing(.caches)
        let item = try #require(context.reviewed?.first)
        context.sizes = [item: 12_345]
        #expect(await Cleanup.clean(.caches, context: context, log: nil) == 12_345)
        #expect(!exists(home, "Library/Caches/a"))
    }

    @Test func logsWhatDockerRemoved() async throws {
        let home = try makeHome([:])
        defer { try? FileManager.default.removeItem(at: home) }
        let docker = FakeDocker(["image prune": ok("Total reclaimed space: 1GB\n")])
        let context = Cleanup.Context(
            home: home, activity: .idle(), reviewed: [DockerCleanup.imagesID, DockerCleanup.buildCacheID], docker: docker.cli)
        let log = home.appending(path: "cleaner.log")
        _ = await Cleanup.clean(.docker, context: context, log: log)
        let logged = try String(contentsOf: log, encoding: .utf8)
        #expect(logged.contains("1000000000\tDocker: Untagged images"))
        #expect(!logged.contains("Build cache"))
    }

    @Test func leavesWhatMacOSAndToolsNeed() async throws {
        let home = try makeHome([
            "Library/Caches/com.apple.FontRegistry/fonts": 1000,
            "Library/Caches/CloudKit/db": 1000,
            "Library/Caches/pypoetry/virtualenvs/env": 1000,
            "Library/Caches/ms-playwright/chromium": 1000,
            "Library/Caches/old": 1000,
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let context = Cleanup.Context(home: home, activity: .idle())
        let scan = await Cleanup.scan(.caches, context: context)
        #expect(scan.cleanable.map { $0.name } == ["old"])
        #expect(scan.items.filter { $0.skipReason == "Protected" }.count == 4)
        _ = await Cleanup.clean(.caches, context: await context.reviewing(.caches), log: nil)
        #expect(exists(home, "Library/Caches/com.apple.FontRegistry/fonts"))
        #expect(exists(home, "Library/Caches/pypoetry/virtualenvs/env"))
        #expect(!exists(home, "Library/Caches/old"))
    }

    @Test func leavesCachesOfOpenApps() async throws {
        let home = try makeHome([
            "Library/Caches/com.example.Editor/a": 1000,
            "Library/Caches/com.example.Editor.ShipIt/b": 1000,
            "Library/Caches/com.other.App/c": 1000,
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let context = Cleanup.Context(home: home, activity: .idle(apps: ["com.example.Editor"]))
        let scan = await Cleanup.scan(.caches, context: context)
        #expect(scan.cleanable.map { $0.name } == ["com.other.App"])
        #expect(scan.items.filter { $0.skipReason == "App is open" }.count == 2)
        #expect(ActivitySnapshot.idle(apps: ["com.example.Editor.Helper"]).ownerIsRunning("com.example.Editor") == true)
        #expect(ActivitySnapshot.idle(lines: ["/opt/homebrew/bin/brew"]).ownerIsRunning("Homebrew") == false)
    }

    @Test func waitsForXcodeToQuit() async throws {
        let home = try makeHome(["Library/Developer/Xcode/DerivedData/App-abc/Build": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        let open = Cleanup.Context(home: home, activity: .idle(lines: ["/Applications/Xcode.app/Contents/MacOS/Xcode"]))
        #expect(await Cleanup.scan(.xcode, context: open).items.first?.skipReason == "Xcode is open")
        #expect(await Cleanup.clean(.xcode, context: await open.reviewing(.xcode), log: nil) == 0)
        #expect(exists(home, "Library/Developer/Xcode/DerivedData/App-abc/Build"))
        let closed = Cleanup.Context(home: home, activity: .idle())
        #expect(await Cleanup.clean(.xcode, context: await closed.reviewing(.xcode), log: nil) > 0)
    }

    @Test func cleansOnlyNamedDeveloperCaches() async throws {
        let home = try makeHome([
            ".npm/_cacache/index": 1000,
            ".npm/_npx/abc/package.json": 1000,
            ".cache/vite/deps": 1000,
            ".cache/huggingface/model.bin": 1000,
            ".gradle/caches/jars": 1000,
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        _ = await Cleanup.clean(
            .developerCaches, context: await Cleanup.Context(home: home, activity: .idle()).reviewing(.developerCaches), log: nil)
        #expect(!exists(home, ".npm/_cacache/index"))
        #expect(!exists(home, ".cache/vite/deps"))
        #expect(exists(home, ".npm/_npx/abc/package.json"))
        #expect(exists(home, ".cache/huggingface/model.bin"))
        #expect(exists(home, ".gradle/caches/jars"))
    }

    @Test func keepsTheCrashReportsFolder() async throws {
        let home = try makeHome(["Library/Logs/app.log": 1000, "Library/Logs/DiagnosticReports/App.ips": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        _ = await Cleanup.clean(.logs, context: await Cleanup.Context(home: home, activity: .idle()).reviewing(.logs), log: nil)
        #expect(!exists(home, "Library/Logs/app.log"))
        #expect(!exists(home, "Library/Logs/DiagnosticReports/App.ips"))
        #expect(exists(home, "Library/Logs/DiagnosticReports"))
    }

    @Test func doesntFollowLinks() async throws {
        let home = try makeHome(["Elsewhere/precious": 100_000, "Library/Logs/old.log": 1000, "Real/Caches/x": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = FileManager.default
        try files.createSymbolicLink(at: home.appending(path: "Library/Logs/link"), withDestinationURL: home.appending(path: "Elsewhere"))
        // A cache folder that is itself a link is left alone entirely.
        try files.createSymbolicLink(at: home.appending(path: "Library/Caches"), withDestinationURL: home.appending(path: "Real/Caches"))
        let context = Cleanup.Context(home: home, activity: .idle())
        #expect(await Cleanup.scan(.logs, context: context).size() < 100_000)
        _ = await Cleanup.clean(.logs, context: await context.reviewing(.logs), log: nil)
        #expect(exists(home, "Elsewhere/precious"))
        #expect(await Cleanup.scan(.caches, context: context).items.allSatisfy { $0.skipReason == "Linked elsewhere" })
        #expect(await Cleanup.clean(.caches, context: await context.reviewing(.caches), log: nil) == 0)
        #expect(exists(home, "Real/Caches/x"))
    }

    @Test func refusesFoldersOutsideHome() {
        let home = URL(filePath: "/Users/someone")
        #expect(Cleanup.reason(toKeep: URL(filePath: "/Library/Caches"), home: home) != nil)
        #expect(Cleanup.reason(toKeep: URL(filePath: "/Users/someone/../other/Library"), home: home) != nil)
        #expect(Cleanup.reason(toKeep: URL(filePath: "/Users/someoneelse/Library"), home: home) != nil)
    }

    @Test func missingFoldersHoldNothing() async {
        let context = Cleanup.Context(home: URL(filePath: "/nonexistent-\(UUID().uuidString)"), activity: .idle())
        #expect(await Cleanup.scan(.xcode, context: context).items.isEmpty)
        #expect(await Cleanup.clean(.xcode, context: await context.reviewing(.xcode), log: nil) == 0)
    }

    @Test(arguments: CleanupTarget.allCases)
    func targetsStayInsideHome(target: CleanupTarget) {
        let home = URL(filePath: "/Users/someone")
        for folder in target.folders(in: home) {
            #expect(folder.path.hasPrefix("/Users/someone/"))
            #expect(folder.path != "/Users/someone/Library")
        }
    }
}

/// Records docker commands and answers them with canned output.
private final class FakeDocker: Sendable {
    let calls = Mutex<[[String]]>([])
    let answers: [String: Command.Output]

    /// Docker on this Mac, unless the answers say otherwise.
    init(_ answers: [String: Command.Output]) {
        self.answers = answers.merging(["context inspect": ok("unix:///var/run/docker.sock\n")]) { given, _ in given }
    }

    var cli: DockerCLI {
        DockerCLI(path: "/usr/local/bin/docker") { arguments, _ in
            self.calls.withLock { $0.append(arguments) }
            let answer = self.answers[arguments.joined(separator: " ")] ?? self.answers[arguments.prefix(2).joined(separator: " ")]
            guard let answer else { throw CancellationError() }
            return answer
        }
    }
}

private func ok(_ stdout: String) -> Command.Output {
    Command.Output(status: 0, stdout: stdout, stderr: "")
}

struct DockerCleanupTests {
    static let df = """
        {"Active":"1","Reclaimable":"1.5GB (60%)","Size":"2.5GB","TotalCount":"4","Type":"Images"}
        {"Active":"1","Reclaimable":"20MB (10%)","Size":"200MB","TotalCount":"3","Type":"Containers"}
        {"Active":"0","Reclaimable":"3GB (100%)","Size":"3GB","TotalCount":"2","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"512kB","Size":"512kB","TotalCount":"9","Type":"Build Cache"}

        """

    @Test func readsSizesTheWayDockerWritesThem() {
        #expect(DockerCleanup.parseSize("1.5GB (60%)") == 1_500_000_000)
        #expect(DockerCleanup.parseSize("512kB") == 512_000)
        #expect(DockerCleanup.parseSize("0B") == 0)
        #expect(DockerCleanup.parseSize("nonsense") == 0)
        #expect(DockerCleanup.reclaimed(fromPrune: "Deleted Images:\nuntagged: x\n\nTotal reclaimed space: 1.2GB\n") == 1_200_000_000)
        #expect(DockerCleanup.reclaimed(fromPrune: "ID\tRECLAIMABLE\nabc\t1MB\nTotal:\t340.5MB\n") == 340_500_000)
    }

    @Test func cleansCachesAndUntaggedImagesButNeverContainersOrVolumes() async {
        let items = DockerCleanup.items(fromDF: Self.df)
        #expect(items.first { $0.id == "docker:volumes" }?.skipReason == "Holds data")
        #expect(items.first { $0.id == "docker:containers" }?.skipReason != nil)

        let docker = FakeDocker([
            "system df": ok(Self.df),
            DockerCleanup.imagesArguments.joined(separator: " "): ok(
                #"[{"Containers":"0","Repository":"<none>","Size":"1.5GB","UniqueSize":"1.5GB"}]"#),
            "builder prune": ok("Total:\t512kB\n"),
            "image prune": ok("Total reclaimed space: 1.5GB\n"),
        ])
        let scan = await DockerCleanup.scan(docker.cli)
        #expect(scan.unavailable == nil)
        #expect(scan.size() == 1_500_512_000)
        let freed = await DockerCleanup.clean(docker.cli) { $0 != DockerCleanup.buildCacheID }
        #expect(freed == 1_500_000_000)
        let commands = docker.calls.withLock { $0 }
        // Without --all, only untagged images go.
        #expect(commands.contains(["image", "prune", "--force"]))
        #expect(!commands.contains { $0.contains("--all") })
        #expect(!commands.contains { $0.first == "builder" })
        #expect(!commands.contains { $0.contains("volume") || $0.contains("--volumes") || $0.first == "container" })
    }

    static let images = """
        [{"Containers":"3","Repository":"app","Size":"4.31GB","UniqueSize":"4.314GB"},\
        {"Containers":"0","Repository":"<none>","Size":"221MB","UniqueSize":"211.3MB"},\
        {"Containers":"0","Repository":"mine/built-here","Size":"90MB","UniqueSize":"90MB"},\
        {"Containers":"2","Repository":"<none>","Size":"26.7MB","UniqueSize":"0B"}]
        """

    @Test func keepsTaggedImagesAndOnesContainersUse() async {
        // Docker's summary says every image can go, but stopped containers still use two of them.
        let docker = FakeDocker([
            "system df": ok(#"{"Active":"3","Reclaimable":"4.65GB (100%)","Size":"4.65GB","TotalCount":"4","Type":"Images"}"#),
            DockerCleanup.imagesArguments.joined(separator: " "): ok(Self.images),
        ])
        let items = await DockerCleanup.scan(docker.cli).items
        #expect(items.first { $0.id == DockerCleanup.imagesID }?.size == 211_300_000)
        let tagged = items.first { $0.id == DockerCleanup.taggedImagesID }
        #expect(tagged?.size == 90_000_000)
        #expect(tagged?.skipReason == DockerCleanup.taggedReason)
        let used = items.first { $0.id == DockerCleanup.usedImagesID }
        // The one whose layers are all shared counts as 0B, as Docker says.
        #expect(used?.size == 4_314_000_000)
        #expect(used?.skipReason != nil)
        #expect(DockerCleanup.imageItems(fromImages: "not json") == nil)
    }

    @Test func prunesAllUnusedBuildCache() async {
        let docker = FakeDocker(["builder prune": ok("Total:\t1GB\n")])
        _ = await DockerCleanup.clean(docker.cli) { $0 == DockerCleanup.buildCacheID }
        // The size shown is all unused build cache, so all of it goes, not just orphaned pieces.
        #expect(docker.calls.withLock { $0 }.contains(["builder", "prune", "--all", "--force"]))
    }

    @Test func removesTaggedImagesOnlyWhenTurnedOn() async {
        let docker = FakeDocker([
            "system df": ok(Self.df),
            DockerCleanup.imagesArguments.joined(separator: " "): ok(Self.images),
            "image prune": ok("Total reclaimed space: 301MB\n"),
        ])
        let scan = await DockerCleanup.scan(docker.cli, prunesTagged: true)
        #expect(scan.items.first { $0.id == DockerCleanup.taggedImagesID }?.skipReason == nil)
        _ = await DockerCleanup.clean(docker.cli, mayDelete: { _ in true }, prunesTagged: true)
        #expect(docker.calls.withLock { $0 }.contains(["image", "prune", "--all", "--force"]))
    }

    @Test func leavesDockerOnAnotherMachineAlone() async {
        let remote = FakeDocker(["context inspect": ok("ssh://deploy@prod-server\n"), "image prune": ok("")])
        #expect(await DockerCleanup.scan(remote.cli).unavailable == "Docker points at another machine")
        var events: [CleanupEvent.Kind] = []
        _ = await DockerCleanup.clean(remote.cli, mayDelete: { _ in true }, report: { kind, _ in events.append(kind) })
        #expect(events == [.failed("Docker points at another machine")])
        #expect(!remote.calls.withLock { $0 }.contains { $0.first == "image" || $0.first == "builder" })
        let unknown = FakeDocker(["context inspect": Command.Output(status: 1, stdout: "", stderr: "")])
        #expect(await DockerCleanup.scan(unknown.cli).unavailable == "Couldn't check where Docker runs")
    }

    @Test func saysWhenDockerIsMissingOrStopped() async {
        #expect(await DockerCleanup.scan(nil).unavailable == "Not installed")
        let stopped = FakeDocker(["system df": Command.Output(status: 1, stdout: "", stderr: "Cannot connect to the Docker daemon")])
        #expect(await DockerCleanup.scan(stopped.cli).unavailable == "Not running")
        #expect(await DockerCleanup.clean(nil) { _ in true } == 0)
    }

    @Test func findsDockerWhereItsInstalled() {
        let home = URL(filePath: "/Users/someone")
        #expect(DockerCLI.find(home: home, isExecutable: { _ in false }) == nil)
        let rancher = DockerCLI.find(home: home, isExecutable: { $0 == "/Users/someone/.rd/bin/docker" })
        #expect(rancher?.path == "/Users/someone/.rd/bin/docker")
    }

    @Test func controllerSkipsDockerWhenItsMissing() async {
        let controller = CleanerController.testing()
        await controller.scan()
        #expect(controller.scans[.docker]?.unavailable == "Not installed")
        #expect(controller.sizes[.docker] == 0)
    }
}

private final class FakeUsageSampler: UsageSampling, Sendable {
    let samples: Mutex<[UsageSample]>
    /// Whether each reading asked for disk space.
    let storageAsked = Mutex<[Bool]>([])

    init(_ samples: [UsageSample]) {
        self.samples = Mutex(samples)
    }

    func sample(includesStorage: Bool) async throws -> UsageSample {
        storageAsked.withLock { $0.append(includesStorage) }
        guard let sample = samples.withLock({ $0.count > 1 ? $0.removeFirst() : $0.first }) else { throw CancellationError() }
        return sample
    }
}

/// Fails its first reading, as when ps times out, then gives `sample` every time.
private final class FlakySampler: UsageSampling, Sendable {
    let sample: UsageSample
    let failed = Mutex(false)

    init(then sample: UsageSample) {
        self.sample = sample
    }

    func sample(includesStorage: Bool) async throws -> UsageSample {
        if failed.withLock({ failed in
            defer { failed = true }
            return !failed
        }) {
            throw CommandError(errorDescription: "It took too long to respond.")
        }
        return sample
    }
}

private final class FakeCleanerSignaling: ProcessSignaling {
    var sent: [(Int32, pid_t)] = []
    var result: Int32 = 0

    func send(_ signal: Int32, to pid: pid_t) -> Int32 {
        sent.append((signal, pid))
        return result
    }

    func isRunning(_ pid: pid_t) -> Bool { true }
}

struct CleanerControllerTests {
    private static let busy = ProcessUsage(
        pid: 900_001, cpu: 80, memory: 1_000, path: "/opt/tools/busy", started: Date(timeIntervalSince1970: 1))
    private static let big = ProcessUsage(pid: 900_002, cpu: 1, memory: 9_000_000, path: "/opt/tools/big")

    private static func sample(ticks: CPUTicks, used: UInt64 = 4, processes: [ProcessUsage] = [busy, big]) -> UsageSample {
        UsageSample(
            cpuTicks: ticks, memory: MemoryUsage(used: used, total: 16), storage: StorageUsage(total: 100, available: 40),
            processes: processes)
    }

    @Test func refreshWorksOutCPUFromTwoReadings() async {
        let sampler = FakeUsageSampler([
            Self.sample(ticks: CPUTicks(busy: 0, total: 0)), Self.sample(ticks: CPUTicks(busy: 30, total: 100)),
        ])
        let controller = CleanerController.testing(home: URL(filePath: "/nonexistent"), sampler: sampler, signaling: FakeCleanerSignaling())
        await controller.refresh()
        #expect(controller.cpu == nil)
        #expect(controller.memory?.fraction == 0.25)
        #expect(controller.storage?.used == 60)
        await controller.refresh()
        #expect(controller.cpu == 0.3)
        #expect(controller.topByCPU.first?.pid == Self.busy.pid)
        #expect(controller.topByMemory.first?.pid == Self.big.pid)
    }

    @Test func keepsTwoMinutesOfHistoryForTheGraphs() async {
        let samples = (0...CleanerController.historyLength + 5).map {
            Self.sample(ticks: CPUTicks(busy: UInt64($0 * 10), total: UInt64($0 * 100)), used: 8)
        }
        let controller = CleanerController.testing(
            home: URL(filePath: "/nonexistent"), sampler: FakeUsageSampler(samples), signaling: FakeCleanerSignaling())
        await controller.refresh()
        #expect(controller.cpuHistory.isEmpty)
        #expect(controller.memoryHistory == [0.5])
        for _ in 0..<CleanerController.historyLength + 5 { await controller.refresh() }
        #expect(controller.cpuHistory.count == CleanerController.historyLength)
        #expect(controller.memoryHistory.count == CleanerController.historyLength)
        #expect(controller.cpuHistory.allSatisfy { $0 == 0.1 })
    }

    @Test func quittingSendsTermAndClearsOnceGone() async {
        let signaling = FakeCleanerSignaling()
        let sampler = FakeUsageSampler([
            Self.sample(ticks: CPUTicks(busy: 0, total: 0)), Self.sample(ticks: .init(busy: 1, total: 2), processes: [Self.big]),
        ])
        let controller = CleanerController.testing(home: URL(filePath: "/nonexistent"), sampler: sampler, signaling: signaling)
        await controller.refresh()
        controller.quit(Self.busy)
        #expect(signaling.sent.map { $0.0 } == [SIGTERM])
        #expect(signaling.sent.map { $0.1 } == [Self.busy.pid])
        #expect(controller.quitting == [Self.busy.pid])
        controller.quit(Self.busy)
        #expect(signaling.sent.count == 1)
        await controller.refresh()
        #expect(controller.quitting.isEmpty)
    }

    @Test func quittingAnotherUsersProcessExplainsWhy() {
        let signaling = FakeCleanerSignaling()
        signaling.result = EPERM
        let controller = CleanerController.testing(home: URL(filePath: "/nonexistent"), sampler: FakeUsageSampler([]), signaling: signaling)
        controller.quit(Self.busy)
        #expect(controller.error?.contains("another user") == true)
        #expect(controller.quitting.isEmpty)
    }

    @Test func wontQuitLaunchdOrItself() {
        let signaling = FakeCleanerSignaling()
        let controller = CleanerController.testing(home: URL(filePath: "/nonexistent"), sampler: FakeUsageSampler([]), signaling: signaling)
        for pid in [0, 1, getpid()] {
            let process = ProcessUsage(pid: pid, cpu: 0, memory: 0, path: "/x")
            #expect(!controller.canQuit(process))
            controller.quit(process)
        }
        #expect(signaling.sent.isEmpty)
    }

    @Test func freeingMemoryReportsWhatWasFreed() async {
        let sampler = FakeUsageSampler([
            Self.sample(ticks: .init(busy: 0, total: 0), used: 10_000_000_000),
            Self.sample(ticks: .init(busy: 1, total: 2), used: 8_000_000_000),
        ])
        var purged = 0
        let controller = CleanerController.testing(
            home: URL(filePath: "/nonexistent"), sampler: sampler, signaling: FakeCleanerSignaling(), purgeMemory: { purged += 1 })
        await controller.refresh()
        await controller.freeMemory()
        #expect(purged == 1)
        #expect(controller.result == "Freed inactive memory.")
    }

    @Test func cancellingThePasswordPromptChangesNothing() async {
        let controller = CleanerController.testing(
            home: URL(filePath: "/nonexistent"), sampler: FakeUsageSampler([]), signaling: FakeCleanerSignaling(),
            purgeMemory: { throw CancellationError() })
        await controller.freeMemory()
        #expect(controller.error == nil)
        #expect(controller.result == nil)
        #expect(!controller.isFreeingMemory)
    }

    @Test func aCancelledQuitCanBeTriedAgain() async {
        // The app stays running, as when its save prompt is cancelled.
        let sampler = FakeUsageSampler([Self.sample(ticks: CPUTicks(busy: 0, total: 0))])
        let signaling = FakeCleanerSignaling()
        let controller = CleanerController.testing(sampler: sampler, signaling: signaling, quitTimeout: .zero)
        controller.quit(Self.busy)
        #expect(controller.quitting == [Self.busy.pid])
        await controller.refresh()
        #expect(controller.quitting.isEmpty)
        controller.quit(Self.busy)
        #expect(signaling.sent.count == 2)
    }

    @Test func aReadingThatWorksClearsTheOldError() async {
        let sampler = FlakySampler(then: Self.sample(ticks: .init(busy: 0, total: 0)))
        let controller = CleanerController.testing(sampler: sampler)
        await controller.refresh()
        #expect(controller.error?.hasPrefix("Couldn't read usage") == true)
        await controller.refresh()
        #expect(controller.error == nil)
    }

    @Test func cleaningReplacesAnOldError() async {
        let signaling = FakeCleanerSignaling()
        signaling.result = EPERM
        let controller = CleanerController.testing(signaling: signaling)
        controller.quit(Self.busy)
        #expect(controller.error != nil)
        await controller.clean()
        #expect(controller.error == nil)
        #expect(controller.result == "Nothing could be deleted.")
    }

    @Test func dismissingClearsTheResultAndQuitErrorButNotUsageProblems() async {
        let signaling = FakeCleanerSignaling()
        signaling.result = EPERM
        let controller = CleanerController.testing(
            sampler: FlakySampler(then: Self.sample(ticks: .init(busy: 0, total: 0))), signaling: signaling)
        await controller.clean()
        controller.quit(Self.busy)
        await controller.refresh()
        #expect(controller.result != nil)
        #expect(controller.actionError != nil)
        controller.dismissMessage()
        #expect(controller.result == nil)
        #expect(controller.actionError == nil)
        #expect(controller.error?.hasPrefix("Couldn't read usage") == true)
    }

    @Test func showsWhatACleanDidAsItGoes() async throws {
        let home = try makeHome(["Library/Caches/a/x": 1000, "Library/Logs/b.log": 500])
        let controller = CleanerController.testing(home: home)
        await controller.scan()
        controller.selected = [.caches]
        #expect(controller.cleanProgress(of: .caches) == .waiting)
        await controller.clean()
        #expect(controller.cleanedTargets == [.caches])
        #expect(controller.cleanEvents.first?.kind == .started)
        let deleted = controller.cleanEvents.filter { if case .deleted = $0.kind { true } else { false } }
        #expect(deleted.map { URL(filePath: $0.detail).lastPathComponent } == ["a"])
        #expect(controller.cleanFreed > 0)
        #expect(controller.cleanProgress(of: .caches) == .done(controller.cleanFreed))
        #expect(!controller.cleanEvents.contains { $0.target == .logs })
    }

    @Test func dockerSaysWhatItRemovedAndWhatFailed() async {
        let docker = FakeDocker(["image prune": ok("Total reclaimed space: 1GB\n")])
        var events: [(CleanupEvent.Kind, String)] = []
        _ = await DockerCleanup.clean(docker.cli, mayDelete: { _ in true }, report: { events.append(($0, $1)) })
        #expect(events.map(\.1) == ["Build cache", "Untagged images"])
        #expect(events.map(\.0) == [.failed("Docker couldn't remove it"), .deleted(1_000_000_000)])
    }

    @Test func totalsOutlastTrimmedEvents() async throws {
        let count = CleanerController.eventLimit + CleanerController.eventTrimBatch + 10
        var files: [String: Int] = [:]
        for index in 0..<count { files["Library/Caches/c\(index)"] = 10 }
        let home = try makeHome(files)
        defer { try? FileManager.default.removeItem(at: home) }
        let controller = CleanerController.testing(home: home)
        await controller.scan()
        controller.selected = [.caches]
        let listed = controller.nextReview.deleteSize
        await controller.clean()
        #expect(controller.cleanEvents.count < count)
        #expect(controller.cleanEvents.first?.kind != .started)
        #expect(controller.cleanFreed == listed)
        #expect(controller.cleanProgress(of: .caches) == .done(listed))
    }

    @Test func leavesUnavailableTargetsOutOfAClean() async {
        let controller = CleanerController.testing()
        await controller.scan()
        await controller.clean()
        #expect(controller.cleanedTargets.contains(.caches))
        #expect(!controller.cleanedTargets.contains(.docker))
    }

    @Test func cleansOnlyWhatTheConfirmationListed() async throws {
        let home = try makeHome(["Library/Caches/seen/x": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        let controller = CleanerController.testing(home: home)
        await controller.scan()
        controller.selected = [.caches]
        let review = controller.nextReview
        // A rescan after the confirmation opened finds something new.
        try Data(count: 1000).write(to: home.appending(path: "Library/Caches/new"))
        await controller.scan()
        await controller.clean(review)
        #expect(!exists(home, "Library/Caches/seen"))
        #expect(exists(home, "Library/Caches/new"))
    }

    @Test func saysWhatWasKeptAndWhy() async throws {
        let home = try makeHome(["Library/Caches/com.apple.thing/x": 100, "Library/Caches/other/x": 100])
        defer { try? FileManager.default.removeItem(at: home) }
        let controller = CleanerController.testing(home: home)
        await controller.scan()
        controller.selected = [.caches]
        await controller.clean()
        let kept = controller.cleanEvents.filter { if case .skipped = $0.kind { true } else { false } }
        #expect(kept.map { URL(filePath: $0.detail).lastPathComponent } == ["com.apple.thing"])
        #expect(kept.first?.kind == .skipped("Part of macOS"))
        // Kept items aren't failures.
        #expect(controller.cleanFailed == 0)
    }

    @Test func saysWhatBecameInUseAfterTheReview() async throws {
        let home = try makeHome(["Library/Caches/com.example.App/x": 100])
        defer { try? FileManager.default.removeItem(at: home) }
        // Listed while the app was closed, then cleaned once it's open.
        var context = await Cleanup.Context(home: home, activity: .idle()).reviewing(.caches)
        context.activity = .idle(apps: ["com.example.App"])
        let events = Mutex<[CleanupEvent.Kind]>([])
        _ = await Cleanup.clean(.caches, context: context, log: nil) { event in events.withLock { $0.append(event.kind) } }
        #expect(events.withLock { $0 } == [.skipped("App is open")])
        #expect(exists(home, "Library/Caches/com.example.App/x"))
    }

    @Test func opensTheLogItWrites() {
        let log = URL(filePath: "/tmp/elsewhere.log")
        let controller = CleanerController(
            defaults: TestDefaults().defaults, home: URL(filePath: "/nonexistent"), sampler: FakeUsageSampler([]),
            cleanupLog: log, docker: nil, npm: nil)
        #expect(controller.logFile == log)
    }

    @Test func tellsTheTrashApartFromFreedSpace() {
        #expect(
            CleanerController.summary(freed: 2_000_000_000, trashed: 300_000_000, failed: 0, cantCheck: false)
                == "Freed 2 GB. Moved 300 MB to the Trash.")
        #expect(
            CleanerController.summary(freed: 0, trashed: 300_000_000, failed: 1, cantCheck: false)
                == "Moved 300 MB to the Trash. 1 item couldn't be removed.")
        #expect(CleanerController.summary(freed: 0, trashed: 0, failed: 0, cantCheck: true) == "Nothing was deleted, to be safe.")
    }

    @Test func theTaggedImagesSwitchTakesAndRescansAfterTheScan() async throws {
        let lookups = Mutex(0)
        let slow = DockerCLI(path: "/usr/local/bin/docker") { _, _ in
            usleep(300_000)
            return Command.Output(status: 1, stdout: "", stderr: "")
        }
        let controller = CleanerController.testing(
            docker: lookups.withLock {
                $0 += 1
                return slow
            })
        let scanning = Task { await controller.scan() }
        while !controller.isScanning { await Task.yield() }
        await controller.setDockerPrunesTagged(true)
        #expect(controller.dockerPrunesTagged)
        await scanning.value
        // Docker was listed again after the first scan, with the new setting.
        #expect(lookups.withLock { $0 } == 2)
    }

    @Test func emptyTickedItemsCanStillBeCleaned() {
        #expect(!CleanReview(targets: [.logs], sizes: ["/x": 0]).isEmpty)
        #expect(CleanReview(targets: [.logs]).isEmpty)
    }

    @Test func onlyXcodeItselfBlocksItsBuildData() async throws {
        let home = try makeHome(["Library/Developer/Xcode/DerivedData/App-abc/x": 100])
        defer { try? FileManager.default.removeItem(at: home) }
        // An editor's language server runs from inside Xcode.app.
        let editor = Cleanup.Context(
            home: home,
            activity: .idle(lines: ["/applications/xcode.app/contents/developer/toolchains/x.xctoolchain/usr/bin/sourcekit-lsp"]))
        #expect(await Cleanup.scan(.xcode, context: editor).items.first?.skipReason == nil)
        let xcode = Cleanup.Context(home: home, activity: .idle(lines: ["/Applications/Xcode.app/Contents/MacOS/Xcode"]))
        #expect(await Cleanup.scan(.xcode, context: xcode).items.first?.skipReason == "Xcode is open")
    }

    @Test func aStuckCleanStopsAndSaysSo() async throws {
        // Docker lists fine, then hangs on pruning, not noticing it was cancelled.
        let stuck = DockerCLI(path: "/usr/local/bin/docker") { arguments, _ in
            switch arguments.first {
            case "context": return Command.Output(status: 0, stdout: "unix:///var/run/docker.sock\n", stderr: "")
            case "image", "builder":
                usleep(3_000_000)
                return Command.Output(status: 0, stdout: "", stderr: "")
            default:
                let images = #"[{"Containers":"0","Repository":"<none>","Size":"1GB","UniqueSize":"1GB"}]"#
                return Command.Output(status: 0, stdout: arguments.contains("-v") ? images : "", stderr: "")
            }
        }
        let controller = CleanerController.testing(docker: stuck, cleanTimeout: .milliseconds(200))
        await controller.scan()
        controller.selected = [.docker]
        let started = ContinuousClock.now
        await controller.clean()
        #expect(ContinuousClock.now - started < .seconds(2))
        // Still deleting unseen, so it's neither done nor counted as a failure.
        #expect(controller.cleanEvents.contains { $0.kind == .timedOut })
        #expect(controller.cleanProgress(of: .docker) == .stillDeleting)
        #expect(controller.cleanFailed == 0)
        #expect(controller.result?.contains("Docker took too long and may still be deleting") == true)
        #expect(!controller.isCleaning)
    }

    @Test func aScanAskedForMidScanFollowsIt() async throws {
        let lookups = Mutex(0)
        let slow = DockerCLI(path: "/usr/local/bin/docker") { _, _ in
            usleep(200_000)
            return Command.Output(status: 1, stdout: "", stderr: "")
        }
        let controller = CleanerController.testing(
            docker: lookups.withLock {
                $0 += 1
                return slow
            })
        let first = Task { await controller.scan() }
        while !controller.isScanning { await Task.yield() }
        await controller.scan([.docker])
        await first.value
        // The second request ran after the first scan, rather than being dropped.
        #expect(lookups.withLock { $0 } == 2)
    }

    @Test func aScanQueuedBehindACancelledOneRunsOnTheNextVisit() async throws {
        let home = try makeHome(["Library/Caches/a/x": 100])
        defer { try? FileManager.default.removeItem(at: home) }
        let slow = DockerCLI(path: "/usr/local/bin/docker") { _, _ in
            usleep(300_000)
            return Command.Output(status: 1, stdout: "", stderr: "")
        }
        let controller = CleanerController.testing(home: home, docker: slow)
        await controller.scan()
        try Data(count: 50).write(to: home.appending(path: "Library/Caches/b"))
        let first = Task { await controller.scan([.docker]) }
        while !controller.isScanning { await Task.yield() }
        await controller.scan([.caches])
        first.cancel()
        await first.value
        let listsB = { controller.scans[.caches]?.items.contains { $0.name == "b" } == true }
        #expect(!listsB())
        let visit = Task { await controller.watchAndScan() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !listsB(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        visit.cancel()
        #expect(listsB())
    }

    @Test func looksUpOnlyWhatTheScannedTargetsUse() async throws {
        let lookups = Mutex<[String]>([])
        let controller = CleanerController.testing(
            docker: lookups.withLock {
                $0.append("docker")
                return nil
            },
            npm: lookups.withLock {
                $0.append("npm")
                return nil
            },
            fullDiskAccess: {
                lookups.withLock { $0.append("access") }
                return true
            })
        await controller.scan([.caches, .logs])
        #expect(lookups.withLock { $0 }.isEmpty)
        await controller.scan([.docker])
        #expect(lookups.withLock { $0 } == ["docker"])
    }

    @Test func aScanAskedForMidCleanRunsAfterIt() async throws {
        let home = try makeHome(["Library/Caches/a/x": 100])
        defer { try? FileManager.default.removeItem(at: home) }
        let lookups = Mutex(0)
        let controller = CleanerController.testing(
            home: home,
            docker: lookups.withLock {
                $0 += 1
                return nil
            })
        await controller.scan()
        controller.selected = [.caches]
        let before = lookups.withLock { $0 }
        let cleaning = Task { await controller.clean() }
        while !controller.isCleaning { await Task.yield() }
        await controller.scan([.docker])
        await cleaning.value
        // Docker wasn't cleaned, so only the asked-for scan looked for it again.
        #expect(lookups.withLock { $0 } > before)
    }

    @Test func aTimedOutCleanIsntRescannedStraightAway() async throws {
        let scans = Mutex(0)
        let stuck = DockerCLI(path: "/usr/local/bin/docker") { arguments, _ in
            switch arguments.first {
            case "context": return Command.Output(status: 0, stdout: "unix:///var/run/docker.sock\n", stderr: "")
            case "image", "builder":
                usleep(1_000_000)
                return Command.Output(status: 0, stdout: "", stderr: "")
            default:
                if arguments.contains("-v") { scans.withLock { $0 += 1 } }
                let images = #"[{"Containers":"0","Repository":"<none>","Size":"1GB","UniqueSize":"1GB"}]"#
                return Command.Output(status: 0, stdout: arguments.contains("-v") ? images : "", stderr: "")
            }
        }
        let controller = CleanerController.testing(docker: stuck, cleanTimeout: .milliseconds(100))
        await controller.scan()
        controller.selected = [.docker]
        await controller.clean()
        #expect(scans.withLock { $0 } == 1)
        // Still deleting in the background, so it's left out of another clean until it stops.
        #expect(!controller.nextReview.targets.contains(.docker))
        // Nor is it scanned, even when asked, while it may be half deleted.
        await controller.scan([.docker])
        #expect(scans.withLock { $0 } == 1)
        for _ in 0..<100 where controller.stillDeleting.contains(.docker) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.nextReview.targets.contains(.docker))
    }

    @Test func dockerSaysWhyTaggedImagesAloneCantGo() async {
        let docker = FakeDocker([:])
        var events: [(CleanupEvent.Kind, String)] = []
        _ = await DockerCleanup.clean(
            docker.cli, mayDelete: { $0 == DockerCleanup.taggedImagesID }, prunesTagged: true,
            report: { events.append(($0, $1)) })
        #expect(events.map(\.0) == [.failed("Tagged images go only together with untagged ones")])
    }

    @Test func remembersWhenTheLastScanFinished() async {
        let controller = CleanerController.testing()
        #expect(controller.scannedAt == nil)
        let before = Date.now
        await controller.scan()
        #expect(controller.scannedAt.map { $0 >= before } == true)
    }

    @Test func remembersKeptPathsWhileTheyreGone() async throws {
        // An app can empty its cache and make it again; the choice to keep it still holds.
        let home = try makeHome(["Library/Caches/a/x": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        let controller = CleanerController.testing(home: home)
        await controller.scan()
        let item = try #require(controller.scans[.caches]?.items.first)
        controller.setWillClean(false, item)
        let folder = home.appending(path: "Library/Caches/a")
        try FileManager.default.removeItem(at: folder)
        await controller.scan()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await controller.scan()
        let again = try #require(controller.scans[.caches]?.items.first)
        #expect(!controller.willClean(again))
    }

    @Test func leavingThePageStopsTheFirstScan() async throws {
        let stuck = DockerCLI(path: "/usr/local/bin/docker") { _, _ in
            usleep(3_000_000)
            return Command.Output(status: 0, stdout: "", stderr: "")
        }
        let controller = CleanerController.testing(docker: stuck)
        let started = ContinuousClock.now
        let watching = Task { await controller.watchAndScan() }
        try await Task.sleep(for: .milliseconds(200))
        watching.cancel()
        await watching.value
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!controller.isScanning)
        #expect(controller.scans[.docker] == nil)
    }

    @Test func comingBackRescansWhatWasUnavailable() async throws {
        let lookups = Mutex(0)
        let controller = CleanerController.testing(
            docker: lookups.withLock {
                $0 += 1
                return nil
            })
        await controller.scan()
        #expect(controller.scans[.docker]?.unavailable == "Not installed")
        let visit = Task { await controller.watchAndScan() }
        for _ in 0..<50 where lookups.withLock({ $0 }) < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        visit.cancel()
        await visit.value
        #expect(lookups.withLock { $0 } >= 2)
    }

    @Test func comingBackFinishesAPartScanAndFindsDockerAgain() async throws {
        let stuck = DockerCLI(path: "/usr/local/bin/docker") { _, _ in
            usleep(3_000_000)
            return Command.Output(status: 0, stdout: "", stderr: "")
        }
        // Docker is looked for at each scan: stuck the first time, then uninstalled.
        let lookups = Mutex(0)
        let controller = CleanerController.testing(
            docker: lookups.withLock {
                $0 += 1
                return $0 == 1 ? stuck : nil
            })
        let first = Task { await controller.watchAndScan() }
        try await Task.sleep(for: .milliseconds(200))
        first.cancel()
        await first.value
        #expect(controller.scans[.docker] == nil)

        let second = Task { await controller.watchAndScan() }
        for _ in 0..<50 where controller.scans[.docker] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        second.cancel()
        await second.value
        #expect(controller.scans[.docker]?.unavailable == "Not installed")
    }

    @Test func aQuitErrorOutlastsOtherProblems() async throws {
        let signaling = FakeCleanerSignaling()
        signaling.result = EPERM
        let controller = CleanerController.testing(
            signaling: signaling, activity: ActivitySnapshot(commandLines: [], bundleIDs: [], openFiles: nil))
        controller.quit(Self.busy)
        await controller.scan()
        #expect(controller.error?.contains("another user") == true)
        #expect(controller.cantCheckActivity)
    }

    @Test func wontQuitAProcessWhoseIDWentToAnother() {
        var busy = Self.busy
        busy.started = Date(timeIntervalSince1970: 100)
        let signaling = FakeCleanerSignaling()
        // Another process started later with the same ID.
        let reused = CleanerController.testing(signaling: signaling, startTime: { _ in Date(timeIntervalSince1970: 200) })
        reused.quit(busy)
        #expect(reused.error == "busy has already quit.")
        // Nothing has the ID any more.
        let gone = CleanerController.testing(signaling: signaling, startTime: { _ in nil })
        gone.quit(busy)
        #expect(gone.error == "busy has already quit.")
        #expect(signaling.sent.isEmpty)
        // A row whose start time couldn't be read can't be told from a later process.
        var unknown = busy
        unknown.started = nil
        do {
            let controller = CleanerController.testing(signaling: signaling, startTime: { _ in Date(timeIntervalSince1970: 100) })
            controller.quit(unknown)
            #expect(controller.error == "busy has already quit.")
            #expect(signaling.sent.isEmpty)
        }
        let same = CleanerController.testing(signaling: signaling, startTime: { _ in Date(timeIntervalSince1970: 100) })
        same.quit(busy)
        #expect(signaling.sent.count == 1)
    }

    @Test func readsStartTimesOnlyForTheRowsShown() async {
        let many = (0..<20).map { ProcessUsage(pid: pid_t(900_200 + $0), cpu: Double($0), memory: Int64($0), path: "/opt/p\($0)") }
        let asked = Mutex<Set<pid_t>>([])
        let controller = CleanerController.testing(
            sampler: FakeUsageSampler([Self.sample(ticks: .init(busy: 0, total: 0), processes: many)]),
            startTime: { pid in
                asked.withLock { _ = $0.insert(pid) }
                return .now
            })
        await controller.refresh()
        let shown = Set((controller.topByCPU + controller.topByMemory).map(\.pid))
        #expect(asked.withLock { $0 } == shown)
        #expect(controller.topByCPU.allSatisfy { $0.started != nil })
    }

    @Test func wontCleanWhileScanning() async throws {
        let stuck = DockerCLI(path: "/usr/local/bin/docker") { _, _ in
            usleep(500_000)
            return Command.Output(status: 1, stdout: "", stderr: "")
        }
        let controller = CleanerController.testing(docker: stuck)
        let scanning = Task { await controller.scan() }
        while !controller.isScanning { await Task.yield() }
        await controller.clean()
        #expect(controller.error?.hasPrefix("Couldn't clean while scanning") == true)
        await scanning.value
    }

    @Test func aScanThatTakesTooLongKeepsTheOldListAndTriesAgain() async throws {
        let stuck = DockerCLI(path: "/usr/local/bin/docker") { _, _ in
            usleep(1_000_000)
            return Command.Output(status: 0, stdout: "", stderr: "")
        }
        // Not installed, then stuck, then not installed again.
        let lookups = Mutex(0)
        let controller = CleanerController.testing(
            docker: lookups.withLock {
                $0 += 1
                return $0 == 2 ? stuck : nil
            }, scanTimeout: .milliseconds(100))
        await controller.scan()
        await controller.scan()
        #expect(controller.scans[.docker]?.unavailable == "Not installed")
        // Every target has a list, but the slow one is scanned again on the next visit.
        let visit = Task { await controller.watchAndScan() }
        for _ in 0..<50 where lookups.withLock({ $0 }) < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        visit.cancel()
        await visit.value
        #expect(lookups.withLock { $0 } >= 3)
    }

    @Test func readsWhenAnyProcessStarted() {
        // Root's launchd too, which proc_pidinfo won't describe to other users.
        #expect(ProcessStart.read(1) != nil)
        #expect(ProcessStart.read(getpid()).map { $0 <= Date.now } == true)
        #expect(ProcessStart.read(-5) == nil)
    }

    @Test func wontQuitPartsOfMacOS() {
        let signaling = FakeCleanerSignaling()
        let controller = CleanerController.testing(signaling: signaling)
        for path in ["/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow", "/usr/libexec/logd"] {
            let process = ProcessUsage(pid: 900_100, cpu: 0, memory: 0, path: path)
            #expect(process.isSystem)
            #expect(!controller.canQuit(process))
            controller.quit(process)
        }
        #expect(signaling.sent.isEmpty)
        #expect(controller.canQuit(Self.busy))
        // Other users' processes, such as root daemons ps shows only by name.
        var daemon = ProcessUsage(pid: 900_100, cpu: 0, memory: 0, path: "autofsd")
        daemon.uid = 0
        #expect(!controller.canQuit(daemon))
        // Things you install, even under /usr/local, can be quit.
        #expect(controller.canQuit(ProcessUsage(pid: 900_100, cpu: 0, memory: 0, path: "/usr/local/bin/node")))
    }

    @Test func readsDiskSpaceEveryHalfMinute() async {
        let sampler = FakeUsageSampler([Self.sample(ticks: .init(busy: 0, total: 0))])
        let controller = CleanerController.testing(sampler: sampler)
        await controller.refresh()
        await controller.refresh()
        #expect(sampler.storageAsked.withLock { $0 } == [true, false])
    }

    @Test func deletesOnlyWhatWasListed() async throws {
        let home = try makeHome(["Library/Caches/old": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        let controller = CleanerController.testing(home: home)
        await controller.scan()
        // Appears after the list was reviewed.
        try Data(repeating: 1, count: 1000).write(to: home.appending(path: "Library/Caches/new"))
        controller.selected = [.caches]
        await controller.clean()
        #expect(!exists(home, "Library/Caches/old"))
        #expect(exists(home, "Library/Caches/new"))
    }

    @Test func saysWhyNothingWasDeletedWhenItCantCheck() async throws {
        let home = try makeHome(["Library/Caches/old": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        let controller = CleanerController.testing(
            home: home, activity: ActivitySnapshot(commandLines: [], bundleIDs: [], openFiles: nil))
        await controller.scan()
        #expect(controller.error == CleanerController.unknownActivityError)
        controller.selected = [.caches]
        await controller.clean()
        #expect(exists(home, "Library/Caches/old"))
        #expect(controller.result == "Nothing was deleted, to be safe.")
    }

    @Test func aStuckScanDoesntHoldUpTheRest() async throws {
        // A Docker that blocks without noticing it's been cancelled, like a stalled disk.
        let stuck = DockerCLI(path: "/usr/local/bin/docker") { _, _ in
            usleep(3_000_000)
            return Command.Output(status: 0, stdout: "", stderr: "")
        }
        let controller = CleanerController.testing(docker: stuck, scanTimeout: .milliseconds(200))
        let started = ContinuousClock.now
        await controller.scan()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(controller.scans[.docker]?.unavailable == CleanerController.tookTooLong)
        #expect(controller.scans[.caches] != nil)
    }

    @Test func untickedItemsAreKeptFromNowOn() async throws {
        let home = try makeHome(["Library/Caches/a/x": 100_000, "Library/Caches/b/y": 100_000, "Library/Logs/l": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TestDefaults()
        let controller = CleanerController.testing(defaults: store.defaults, home: home)
        await controller.scan()
        let items = try #require(controller.scans[.caches]?.items)
        let a = try #require(items.first { $0.name == "a" })
        let total = controller.sizes[.caches] ?? 0
        controller.setWillClean(false, a)
        #expect(!controller.willClean(a))
        #expect(controller.sizes[.caches] == total - a.size)

        // Remembered across launches.
        let reloaded = CleanerController.testing(defaults: store.defaults, home: home)
        #expect(!reloaded.willClean(a))

        controller.selected = [.caches]
        await controller.clean()
        #expect(exists(home, "Library/Caches/a/x"))
        #expect(!exists(home, "Library/Caches/b/y"))
        #expect(exists(home, "Library/Logs/l"))

        controller.setWillCleanAll(true, in: .caches)
        #expect(controller.willClean(a))
        controller.setWillCleanAll(false, in: .caches)
        #expect(controller.sizes[.caches] == 0)
    }

    @Test func cleansOnlyTheSelectedTargets() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "CleanerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for path in ["Library/Caches/a", "Library/Logs/b"] {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100_000).write(to: url)
        }
        let controller = CleanerController.testing(home: home, sampler: FakeUsageSampler([]), signaling: FakeCleanerSignaling())
        await controller.scan()
        #expect((controller.sizes[.caches] ?? 0) > 0)
        #expect((controller.sizes[.logs] ?? 0) > 0)
        #expect(controller.sizes[.xcode] == 0)

        controller.selected = [.logs]
        #expect(controller.nextReview.deleteSize == controller.sizes[.logs])
        await controller.clean()
        #expect(controller.sizes[.logs] == 0)
        #expect((controller.sizes[.caches] ?? 0) > 0)
        #expect(controller.result?.hasPrefix("Freed ") == true)
    }
}

extension CleanerController {
    /// A controller that reads, quits and deletes only what each test gives it.
    fileprivate static func testing(
        defaults: UserDefaults = TestDefaults().defaults,
        home: URL = URL(filePath: "/nonexistent"),
        sampler: any UsageSampling = FakeUsageSampler([]),
        signaling: any ProcessSignaling = FakeCleanerSignaling(),
        purgeMemory: @escaping () async throws -> Void = {},
        docker: @escaping @autoclosure () -> DockerCLI? = nil,
        npm: @escaping @autoclosure () -> NpmCLI? = nil,
        quitTimeout: Duration = .seconds(5),
        activity: ActivitySnapshot = .idle(),
        scanTimeout: Duration = .seconds(60),
        cleanTimeout: Duration = .seconds(60),
        startTime: @escaping (pid_t) -> Date? = { _ in Date(timeIntervalSince1970: 1) },
        installedApps: @escaping @Sendable () async -> InstalledApps? = { InstalledApps(isInstalled: { _ in false }, vendors: []) },
        fullDiskAccess: @escaping () -> Bool = { true }
    ) -> CleanerController {
        CleanerController(
            defaults: defaults, home: home, sampler: sampler, signaling: signaling, purgeMemory: purgeMemory, readActivity: { activity },
            quitTimeout: quitTimeout,
            cleanupLog: nil, docker: docker(), npm: npm(), scanTimeout: scanTimeout, cleanTimeout: cleanTimeout,
            startTime: startTime, installedApps: installedApps, fullDiskAccess: fullDiskAccess)
    }
}

extension ActivitySnapshot {
    /// Nothing running and nothing open, unless given.
    nonisolated static func idle(apps: Set<String> = [], lines: [String] = [], open: [String] = []) -> ActivitySnapshot {
        ActivitySnapshot(commandLines: lines, bundleIDs: apps, openFiles: open)
    }
}

struct InUseTests {
    @Test func recognisesDaemonsByTheirCommandLine() {
        let activity = ActivitySnapshot.idle(lines: [
            "/System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Support/bird",
            "/usr/libexec/nsurlsessiond",
            "/Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt com.anthropic.claude",
        ])
        // A whole ID in a command line.
        #expect(activity.ownerIsRunning("com.anthropic.claude") == true)
        // The last part as a word, with another part to back it up.
        #expect(activity.ownerIsRunning("com.apple.nsurlsessiond") == false)
        #expect(ActivitySnapshot.idle(lines: ["/usr/libexec/nsurlsessiond --apple"]).ownerIsRunning("com.apple.nsurlsessiond") == true)
        #expect(ActivitySnapshot.idle(lines: ["/usr/libexec/syncdefaultsd"]).ownerIsRunning("com.apple.syncdefaults") == false)
        // A shared helper name inside another app's bundle doesn't count.
        #expect(activity.ownerIsRunning("com.microsoft.VSCode.ShipIt") == false)
        // Names that aren't bundle IDs aren't checked.
        #expect(activity.ownerIsRunning("Homebrew") == false)
    }

    @Test func spotsNpmRunThroughNode() {
        let viaNode = ActivitySnapshot(commandLines: ["node /opt/homebrew/bin/npm install"], bundleIDs: [], openFiles: [])
        #expect(viaNode.npmIsRunning == true)
        let other = ActivitySnapshot(commandLines: ["node server.js --npmrc x"], bundleIDs: [], openFiles: [])
        #expect(other.npmIsRunning == false)
    }

    @Test func cantSayAnythingIsIdleWithoutTheProcessList() {
        let unknown = ActivitySnapshot(commandLines: nil, bundleIDs: [], openFiles: [])
        // Short names too, which used to count as not running.
        #expect(unknown.ownerIsRunning("Firefox") == nil)
        #expect(unknown.ownerIsRunning("foo.app") == nil)
    }

    @Test func openFilesMatchOnlyInsideTheFolder() {
        let activity = ActivitySnapshot(
            commandLines: [], bundleIDs: [], openFiles: ["/c/app-old/x", "/c/app.bak", "/c/app/deep/db", "/c/z"])
        #expect(activity.isOpen(URL(filePath: "/c/app")) == true)
        #expect(activity.isOpen(URL(filePath: "/c/app.bak")) == true)
        #expect(activity.isOpen(URL(filePath: "/c/ap")) == false)
        #expect(activity.isOpen(URL(filePath: "/c/b")) == false)
    }

    @Test func openFilesMatchWhateverTheCapitals() {
        let activity = ActivitySnapshot(commandLines: [], bundleIDs: [], openFiles: ["/Users/a/Library/Caches/com.Foo.App/db"])
        #expect(activity.isOpen(URL(filePath: "/Users/a/Library/Caches/com.foo.app")) == true)
        #expect(activity.isOpen(URL(filePath: "/Users/a/Library/Caches/com.foo.other")) == false)
    }

    @Test func notKnowingKeepsTheItem() {
        let unknown = ActivitySnapshot(commandLines: nil, bundleIDs: [], openFiles: nil)
        #expect(unknown.ownerIsRunning("com.example.App") == nil)
        #expect(unknown.npmIsRunning == nil)
        #expect(unknown.isOpen(URL(filePath: "/tmp/x")) == nil)
    }

    @Test func spotsNpm() {
        #expect(ActivitySnapshot.idle(lines: ["npm exec vite --port 5179"]).npmIsRunning == true)
        #expect(ActivitySnapshot.idle(lines: ["node /usr/local/lib/node_modules/npm/bin/npm-cli.js install"]).npmIsRunning == true)
        #expect(ActivitySnapshot.idle(lines: ["/usr/local/bin/node server.js --npm-config"]).npmIsRunning == false)
    }

    @Test func findsBundleIDsOfRunningApps() {
        let ids = ActivitySnapshot.bundleIDs(in: ["/System/Applications/TextEdit.app/Contents/MacOS/TextEdit -psn"])
        #expect(ids.contains("com.apple.TextEdit"))
    }

    @Test func leavesOpenFilesAndBusyToolsAlone() async throws {
        let home = try makeHome([
            "Library/Caches/open/db.sqlite": 1000,
            "Library/Caches/closed/db.sqlite": 1000,
            ".npm/_cacache/index": 1000,
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let openFile = home.appending(path: "Library/Caches/open/db.sqlite").standardizedFileURL.path
        let busy = Cleanup.Context(home: home, activity: .idle(lines: ["npm install"], open: [openFile]))
        let caches = await Cleanup.scan(.caches, context: busy)
        #expect(caches.items.first { $0.name == "open" }?.skipReason == "In use")
        #expect(caches.cleanable.map { $0.name } == ["closed"])
        #expect(await Cleanup.scan(.developerCaches, context: busy).items.first?.skipReason == "npm is running")

        _ = await Cleanup.clean(.caches, context: await busy.reviewing(.caches), log: nil)
        #expect(exists(home, "Library/Caches/open/db.sqlite"))
        #expect(!exists(home, "Library/Caches/closed"))
    }

    @Test func keepsEverythingWhenItCantTell() async throws {
        let home = try makeHome(["Library/Caches/loose": 1000, "Library/Caches/com.example.App/a": 1000])
        defer { try? FileManager.default.removeItem(at: home) }
        let unknown = Cleanup.Context(home: home, activity: ActivitySnapshot(commandLines: nil, bundleIDs: [], openFiles: nil))
        let scan = await Cleanup.scan(.caches, context: unknown)
        #expect(scan.cleanable.isEmpty)
        #expect(scan.items.allSatisfy { $0.skipReason == Cleanup.unknownUse })
        #expect(await Cleanup.clean(.caches, context: await unknown.reviewing(.caches), log: nil) == 0)
    }

    @Test func leavesFoldersWithADiskMountedInside() {
        let item = URL(filePath: "/Users/someone/Library/Caches/Tool")
        #expect(Cleanup.hasMount(inside: item, mounts: ["/", "/Users/someone/Library/Caches/Tool/images/disk"]))
        #expect(Cleanup.hasMount(inside: item, mounts: ["/Users/someone/Library/Caches/Tool"]))
        #expect(!Cleanup.hasMount(inside: item, mounts: ["/", "/System/Volumes/Data", "/Users/someone/Library/Caches/Tool2"]))
    }

    @Test func protectsDenoTldrAndSurge() {
        for name in ["deno", "tealdeer", "com.nssurge.surge-mac"] {
            #expect(CleanupTarget.caches.protects(name))
        }
    }
}

struct AppLeftoversTests {
    /// Folders an old app left, dated a month back unless `recent`.
    private func makeLibrary(_ paths: [String], recent: Set<String> = []) throws -> URL {
        let home = try makeHome(Dictionary(uniqueKeysWithValues: paths.map { ("Library/\($0)/x", 100) }))
        let old = Date.now.addingTimeInterval(-60 * 86_400)
        for path in paths {
            let url = home.appending(path: "Library/\(path)")
            let date = recent.contains(path) ? Date.now : old
            for item in [url.appending(path: "x"), url] {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
            }
        }
        return home
    }

    private let apps = InstalledApps(
        isInstalled: { ["net.kept.App", "com.vendor.Main"].contains($0) }, vendors: ["net.kept", "com.vendor"])

    @Test func findsWhatUninstalledAppsLeft() async throws {
        let home = try makeLibrary(
            [
                "Containers/com.gone.App", "Preferences/com.gone.App.plist", "Group Containers/ABCDE12345.com.gone.App",
                "Application Support/com.gone.App", "Caches/com.gone.App", "Logs/com.gone.App",
                // An installed app's widget, a vendor's other app, macOS's own and one changed this week.
                "Containers/net.kept.App.Widgets", "Containers/com.vendor.Other", "Containers/com.apple.Thing",
                "Containers/com.recent.App",
            ], recent: ["Containers/com.recent.App"])
        defer { try? FileManager.default.removeItem(at: home) }
        let context = Cleanup.Context(home: home, activity: .idle(), apps: apps)
        let scan = await Cleanup.scan(.leftovers, context: context)
        let gone = scan.items.filter { $0.name.hasPrefix("com.gone.App") }
        #expect(
            Set(gone.map { $0.name }) == [
                "com.gone.App · Container", "com.gone.App · Settings", "com.gone.App · App data",
            ])
        #expect(gone.allSatisfy { $0.skipReason == nil && $0.size > 0 })
        #expect(scan.items.first { $0.name.hasPrefix("com.recent.App") }?.skipReason == AppLeftovers.recentReason)
        #expect(!scan.items.contains { $0.name.hasPrefix("net.kept") || $0.name.hasPrefix("com.vendor") || $0.name.hasPrefix("com.apple") })
    }

    @Test func aFileChangedDeepInsideKeepsTheApp() async throws {
        let home = try makeLibrary(["Containers/com.gone.App", "Application Support/com.gone.App"])
        defer { try? FileManager.default.removeItem(at: home) }
        // A database edited in place, deep inside, doesn't change any folder's date.
        let deep = home.appending(path: "Library/Application Support/com.gone.App/db/store.sqlite")
        try FileManager.default.createDirectory(at: deep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: deep)
        let old = Date.now.addingTimeInterval(-60 * 86_400)
        for folder in ["Library/Application Support/com.gone.App/db", "Library/Application Support/com.gone.App"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home.appending(path: folder).path)
        }
        let scan = await Cleanup.scan(.leftovers, context: Cleanup.Context(home: home, activity: .idle(), apps: apps))
        #expect(!scan.items.isEmpty)
        #expect(scan.items.allSatisfy { $0.skipReason == AppLeftovers.recentReason })
    }

    @Test func movingToTheTrashIsntCountedAsFreed() async throws {
        let home = try makeLibrary(["Containers/com.gone.App"])
        defer { try? FileManager.default.removeItem(at: home) }
        var context = await Cleanup.Context(home: home, activity: .idle(), apps: apps).reviewing(.leftovers)
        context.trash = { try FileManager.default.removeItem(at: $0) }
        let events = Mutex<[CleanupEvent.Kind]>([])
        _ = await Cleanup.clean(.leftovers, context: context, log: nil) { event in events.withLock { $0.append(event.kind) } }
        #expect(events.withLock { $0 }.allSatisfy { if case .trashed = $0 { true } else { false } })
        #expect(!events.withLock { $0 }.isEmpty)
    }

    @Test func leavesAnOpenAppsDataAlone() async throws {
        let home = try makeLibrary(["Containers/com.gone.App"])
        defer { try? FileManager.default.removeItem(at: home) }
        let running = Cleanup.Context(home: home, activity: .idle(apps: ["com.gone.App"]), apps: apps)
        #expect(await Cleanup.scan(.leftovers, context: running).items.first?.skipReason == "App is open")
        let unknown = Cleanup.Context(home: home, activity: ActivitySnapshot(commandLines: nil, bundleIDs: [], openFiles: nil), apps: apps)
        #expect(await Cleanup.scan(.leftovers, context: unknown).items.first?.skipReason == Cleanup.unknownUse)
    }

    @Test func wontSelectLeftoversWithoutFullDiskAccess() {
        let without = CleanerController.testing(fullDiskAccess: { false })
        #expect(!without.setSelected(true, .leftovers))
        #expect(!without.selected.contains(.leftovers))
        // Other targets don't need it, and anything can be cleared.
        #expect(without.setSelected(false, .caches))
        #expect(without.setSelected(true, .caches))
        let with = CleanerController.testing(fullDiskAccess: { true })
        #expect(with.setSelected(true, .leftovers))
        #expect(with.selected.contains(.leftovers))
    }

    @Test func containersNeedFullDiskAccess() async throws {
        let home = try makeLibrary([
            "Containers/com.gone.App", "Group Containers/ABCDE12345.com.gone.App", "Application Support/com.gone.App",
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        var context = Cleanup.Context(home: home, activity: .idle(), apps: apps)
        context.canChangeAppContainers = false
        let reasons = Dictionary(
            uniqueKeysWithValues: await Cleanup.scan(.leftovers, context: context).items.map { ($0.name, $0.skipReason) })
        #expect(reasons["com.gone.App · Container"] == AppLeftovers.needsFullDiskAccess)
        // Shared group containers are never listed.
        #expect(reasons["com.gone.App · Shared data"] == nil)
        #expect(reasons["com.gone.App · App data"] == .some(nil))
    }

    @Test func saysWhySomethingStayed() {
        #expect(Cleanup.failureReason(CocoaError(.fileWriteNoPermission), trashing: true) == "No permission")
        #expect(Cleanup.failureReason(POSIXError(.EPERM), trashing: false) == "macOS didn't allow it")
        #expect(Cleanup.failureReason(nil, trashing: true) == "Couldn't move to the Trash")
        #expect(Cleanup.failureReason(nil, trashing: false) == "Couldn't be fully deleted")
    }

    @Test func theResultSaysWhatCouldntBeRemoved() async throws {
        let home = try makeHome(["Library/Caches/a/x": 1000])
        let folder = home.appending(path: "Library/Caches/a")
        defer {
            chmod(folder.path, 0o755)
            try? FileManager.default.removeItem(at: home)
        }
        let controller = CleanerController.testing(home: home)
        await controller.scan()
        controller.selected = [.caches]
        chmod(folder.path, 0o555)
        await controller.clean()
        #expect(controller.cleanFailed == 1)
        #expect(controller.result == "Nothing was removed. 1 item couldn't be removed.")
    }

    @Test func neverOffersContainersNamedAfterATeam() async throws {
        let home = try makeLibrary(["Containers/UBF8T346G9.OfficeOsfWebHost", "Containers/com.gone.App"])
        defer { try? FileManager.default.removeItem(at: home) }
        let scan = await Cleanup.scan(.leftovers, context: Cleanup.Context(home: home, activity: .idle(), apps: apps))
        #expect(!scan.items.contains { $0.name.hasPrefix("UBF8T346G9") })
        #expect(scan.items.contains { $0.name.hasPrefix("com.gone.App") })
        #expect(AppLeftovers.startsWithTeamID("ABCDE12345.foo"))
        #expect(!AppLeftovers.startsWithTeamID("com.example.App"))
    }

    @Test func countsAppsOnADiskThatIsntConnected() {
        #expect(InstalledApps.isPresent(URL(filePath: "/System/Applications/Calculator.app")))
        #expect(InstalledApps.isPresent(URL(filePath: "/Volumes/NotPluggedIn-\(UUID().uuidString)/Old.app")))
        #expect(!InstalledApps.isPresent(URL(filePath: "/Applications/Deleted-\(UUID().uuidString).app")))
    }

    @Test func aShortRunningIDCountsAsOpen() async throws {
        let home = try makeLibrary(["Containers/foo.app"])
        defer { try? FileManager.default.removeItem(at: home) }
        let context = Cleanup.Context(home: home, activity: .idle(apps: ["foo.app"]), apps: apps)
        #expect(await Cleanup.scan(.leftovers, context: context).items.first?.skipReason == "App is open")
    }

    @Test func saysWhenItCantTellWhatsInstalled() async {
        let scan = await Cleanup.scan(.leftovers, context: Cleanup.Context(home: URL(filePath: "/nonexistent"), activity: .idle()))
        #expect(scan.unavailable == "Couldn't check installed apps")
    }

    @Test func ownsHelpersAndVendorsButOnlyRealAppIDs() {
        #expect(apps.owns("net.kept.App.Widgets"))
        #expect(apps.owns("com.vendor.Anything"))
        #expect(!apps.owns("com.gone.App"))
        #expect(AppLeftovers.looksLikeAppID("com.example.App"))
        #expect(!AppLeftovers.looksLikeAppID(".DS_Store"))
        #expect(!AppLeftovers.looksLikeAppID("Haul"))
    }

    @Test func readsTheAppsOnThisMac() async throws {
        let installed = try #require(await InstalledApps.read())
        #expect(installed.isInstalled("com.apple.finder"))
        #expect(!installed.isInstalled("com.example.not-an-app"))
        #expect(installed.vendors.contains("com.apple"))
    }

    @Test func startsOffThenMovesTickedItemsToTheTrash() async throws {
        let home = try makeLibrary(["Containers/com.gone.App", "Preferences/com.gone.App.plist"])
        let trash = home.appending(path: "Trash")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!CleanupTarget.selectedByDefault.contains(.leftovers))
        let controller = CleanerController.testing(home: home)
        await controller.scan()
        #expect(!controller.selected.contains(.leftovers))
        let items = try #require(controller.scans[.leftovers]?.items)
        #expect(items.count == 2)
        // Its items are ticked like any target's, so checking it is all it takes.
        #expect(items.allSatisfy(controller.willClean))
        #expect(controller.nextReview.deleteSize == controller.sizes.filter { $0.key != .leftovers }.values.reduce(0, +))
        #expect(controller.setSelected(true, .leftovers))
        let settings = try #require(items.first { $0.name.hasSuffix("Settings") })
        controller.setWillClean(false, settings)
        #expect(controller.sizes[.leftovers] == items.reduce(0) { $0 + $1.size } - settings.size)

        // Straight through Cleanup, with a trash of its own, so the real Trash isn't touched.
        var context = Cleanup.Context(
            home: home, activity: .idle(), kept: [settings.id], apps: InstalledApps(isInstalled: { _ in false }, vendors: []))
        context.trash = { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appending(path: url.lastPathComponent))
        }
        let freed = await Cleanup.clean(.leftovers, context: await context.reviewing(.leftovers), log: nil)
        #expect(freed > 0)
        #expect(!exists(home, "Library/Containers/com.gone.App"))
        #expect(exists(home, "Trash/com.gone.App"))
        // The unticked one stays.
        #expect(exists(home, "Library/Preferences/com.gone.App.plist"))
    }
}
