import Darwin
import Foundation
import Synchronization
import Testing

@testable import PowerToys

struct FileHolderTests {
    @Test func parsesProcessesAndTheirFiles() {
        let output = """
            p500
            czsh
            fcwd
            n/Volumes/Backup/projects
            p42
            cPreview
            f12
            n/Volumes/Backup/a.pdf
            f13
            n/Volumes/Backup/a.pdf
            f14
            n/Volumes/Backup/b.pdf
            p7
            cSelf
            f3
            n/Volumes/Backup/own.log

            """
        let holders = FileHolder.parse(lsof: output, excluding: 7)
        #expect(holders.map(\.pid) == [500, 42])
        #expect(holders[1].command == "Preview")
        #expect(holders[1].files.map(\.path) == ["/Volumes/Backup/a.pdf", "/Volumes/Backup/b.pdf"])
        #expect(holders[1].summary == "Open /Volumes/Backup/a.pdf · 1 more")
        #expect(holders[0].files[0].use == "working folder")
        #expect(FileHolder.parse(lsof: "").isEmpty)
    }

    @Test func anExcludedProcessesFilesDontLandOnTheOneBefore() {
        let output = "p1\ncone\nf3\nn/a\np2\nctwo\nf4\nn/b\n"
        let holders = FileHolder.parse(lsof: output, excluding: 2)
        #expect(holders.count == 1)
        #expect(holders[0].files.map(\.path) == ["/a"])
    }

    @Test func looksInsideFoldersButTakesDisksWhole() {
        let url = URL(filePath: "/Volumes/Backup")
        #expect(FileHolder.lsofArguments(for: url, isFolder: true, isVolume: false).suffix(2) == ["+D", "/Volumes/Backup"])
        #expect(FileHolder.lsofArguments(for: url, isFolder: true, isVolume: true).suffix(2) == ["--", "/Volumes/Backup"])
        #expect(FileHolder.lsofArguments(for: url, isFolder: false, isVolume: false).suffix(2) == ["--", "/Volumes/Backup"])
    }
}

final class FakeHolderScanner: FileHolderScanning, @unchecked Sendable {
    var holders: [FileHolder] = []
    var failure: CommandError?
    private(set) var asAdministrator: [Bool] = []

    func holders(of url: URL, asAdministrator: Bool) async throws -> [FileHolder] {
        self.asAdministrator.append(asAdministrator)
        if let failure { throw failure }
        return holders
    }
}

final class FakeQuitter: ProcessQuitting {
    var running: Set<pid_t> = []
    /// Processes that ignore being asked to quit.
    var ignoresQuit: Set<pid_t> = []
    var failure: CommandError?
    var onQuit: ((pid_t) -> Void)?
    /// How long asking takes, as when it waits on a password.
    var delay: Duration?
    private(set) var asked = 0

    func quit(_ pid: pid_t, force: Bool) async throws {
        asked += 1
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        if force || !ignoresQuit.contains(pid) {
            running.remove(pid)
            onQuit?(pid)
        }
    }

    func isRunning(_ pid: pid_t) -> Bool { running.contains(pid) }
}

struct LocksmithControllerTests {
    private let file = URL(filePath: "/tmp/report.pdf")
    private let preview = FileHolder(pid: 42, command: "Preview", files: [.init(descriptor: "12", path: "/tmp/report.pdf")])

    private func controller(
        _ scanner: FakeHolderScanner, _ quitter: FakeQuitter = FakeQuitter(), finder: FakeFinder = FakeFinder(),
        eject: @escaping @Sendable (URL) async throws -> Void = { _ in }
    ) -> LocksmithController {
        LocksmithController(
            scanner: scanner, quitter: quitter, finder: finder, eject: eject, volumes: { [] }, quitTimeout: .milliseconds(300))
    }

    @Test func listsWhatHasItOpen() async {
        let scanner = FakeHolderScanner()
        scanner.holders = [preview]
        let locksmith = controller(scanner)
        await locksmith.check(file)
        #expect(locksmith.target == file)
        #expect(locksmith.holders == [preview])
        #expect(locksmith.hasScanned)
        #expect(scanner.asAdministrator == [false])

        // Checking as administrator sticks for later checks of the same target.
        await locksmith.scan(asAdministrator: true)
        await locksmith.scan()
        #expect(scanner.asAdministrator == [false, true, true])
        #expect(locksmith.scannedAsAdministrator)
    }

    @Test func aNewTargetIsCheckedWithoutAdministrator() async {
        let scanner = FakeHolderScanner()
        let locksmith = controller(scanner)
        await locksmith.check(file)
        await locksmith.scan(asAdministrator: true)
        await locksmith.check(URL(filePath: "/tmp/other.pdf"))
        #expect(scanner.asAdministrator == [false, true, false])
        #expect(!locksmith.scannedAsAdministrator)
    }

    @Test func quittingRemovesTheProcess() async {
        let scanner = FakeHolderScanner()
        scanner.holders = [preview]
        let quitter = FakeQuitter()
        quitter.running = [42]
        quitter.onQuit = { _ in scanner.holders = [] }
        let locksmith = controller(scanner, quitter)
        await locksmith.check(file)
        await locksmith.quit(preview)
        #expect(locksmith.holders.isEmpty)
        #expect(locksmith.stubborn.isEmpty)
        #expect(locksmith.error == nil)
    }

    @Test func aProcessThatWontQuitCanBeForced() async {
        let scanner = FakeHolderScanner()
        scanner.holders = [preview]
        let quitter = FakeQuitter()
        quitter.running = [42]
        quitter.ignoresQuit = [42]
        let locksmith = controller(scanner, quitter)
        await locksmith.check(file)
        await locksmith.quit(preview)
        #expect(locksmith.stubborn == [42])
        #expect(locksmith.status(of: preview) == "Didn't quit. Force quit to stop it now.")

        scanner.holders = []
        await locksmith.quit(preview, force: true)
        #expect(locksmith.stubborn.isEmpty)
        #expect(locksmith.holders.isEmpty)
    }

    @Test func asksOnceWhenQuitIsClickedTwice() async {
        let scanner = FakeHolderScanner()
        scanner.holders = [preview]
        let quitter = FakeQuitter()
        quitter.running = [42]
        quitter.delay = .milliseconds(100)
        let locksmith = controller(scanner, quitter)
        await locksmith.check(file)
        async let first: Void = locksmith.quit(preview)
        async let second: Void = locksmith.quit(preview)
        _ = await (first, second)
        #expect(quitter.asked == 1)
        #expect(locksmith.quitting.isEmpty)
    }

    @Test func saysWhyItCouldntQuit() async {
        let scanner = FakeHolderScanner()
        scanner.holders = [preview]
        let quitter = FakeQuitter()
        quitter.failure = CommandError(errorDescription: "Not allowed.")
        let locksmith = controller(scanner, quitter)
        await locksmith.check(file)
        await locksmith.quit(preview)
        #expect(locksmith.error == "Couldn't quit Preview: Not allowed.")
        #expect(locksmith.holders == [preview])
        #expect(locksmith.status(of: preview) == nil)
    }

    @Test func checksFinderSelection() async {
        let scanner = FakeHolderScanner()
        let locksmith = controller(scanner, finder: FakeFinder(selected: [file]))
        await locksmith.checkFinderSelection()
        #expect(locksmith.target == file)

        let empty = controller(FakeHolderScanner())
        await empty.checkFinderSelection()
        #expect(empty.target == nil)
        #expect(empty.error == "Nothing is selected in Finder.")
    }

    @Test func reportsScanFailures() async {
        let scanner = FakeHolderScanner()
        scanner.failure = CommandError(errorDescription: "lsof broke")
        let locksmith = controller(scanner)
        await locksmith.check(file)
        #expect(locksmith.error == "Couldn't check: lsof broke")
        #expect(!locksmith.hasScanned)
    }

    @Test func ejectsADisk() async {
        let ejected = Mutex<[URL]>([])
        let locksmith = controller(FakeHolderScanner(), eject: { url in ejected.withLock { $0.append(url) } })
        // The startup disk is a volume, so it stands in for one; nothing is really ejected.
        let disk = URL(filePath: "/", directoryHint: .isDirectory)
        await locksmith.check(disk)
        #expect(locksmith.targetIsVolume)
        await locksmith.ejectTarget()
        #expect(ejected.withLock { $0 } == [disk.standardizedFileURL])
        #expect(locksmith.target == nil)
        #expect(locksmith.notice != nil)
    }

    @Test func filesArentEjected() async {
        let ejected = Mutex(false)
        let locksmith = controller(FakeHolderScanner(), eject: { _ in ejected.withLock { $0 = true } })
        await locksmith.check(file)
        await locksmith.ejectTarget()
        #expect(!ejected.withLock { $0 })
    }
}
