import AppKit
import Darwin
import Foundation
import Observation

/// Finds what has a file open; a protocol so tests don't run lsof.
protocol FileHolderScanning: Sendable {
    @concurrent func holders(of url: URL, asAdministrator: Bool) async throws -> [FileHolder]
}

/// Quits processes; a protocol so tests don't quit anything.
protocol ProcessQuitting {
    /// Asks the process to quit, or makes it with `force`. Throws when it can't be asked.
    func quit(_ pid: pid_t, force: Bool) async throws
    func isRunning(_ pid: pid_t) -> Bool
}

nonisolated struct LiveFileHolderScanner: FileHolderScanning {
    /// Looking through a big folder such as ~/Library can take a while, but not forever.
    static let timeLimit = 120
    static let tooLong = CommandError(
        errorDescription: "Checking took longer than \(timeLimit / 60) minutes. Try a smaller folder or a single file.")

    /// Off the main thread: a disk can have tens of thousands of open files to read through.
    @concurrent
    func holders(of url: URL, asAdministrator: Bool) async throws -> [FileHolder] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isVolumeKey])
        let arguments = FileHolder.lsofArguments(
            for: url, isFolder: values?.isDirectory == true, isVolume: values?.isVolume == true)
        let stdout: String
        if asAdministrator {
            let command = (["/usr/bin/timeout", String(Self.timeLimit), "/usr/sbin/lsof"] + arguments)
                .map(Command.shellQuoted).joined(separator: " ")
            // lsof exits with 1 when nothing has it open; that's an answer, not a failure.
            // timeout exits with 124 when it stopped lsof. The limit starts after the password.
            do {
                stdout = try await Command.runAsAdministrator(
                    "\(command); [ $? -ne 124 ] || { echo \(Self.timeoutMarker) >&2; exit 1; }",
                    prompt: "\(AppInfo.name) wants to see which system processes are using “\(url.lastPathComponent)”.")
            } catch let error as CommandError where error.errorDescription?.contains(Self.timeoutMarker) == true {
                throw Self.tooLong
            }
        } else {
            let output: Command.Output
            do {
                output = try await Command.run("/usr/sbin/lsof", arguments, timeout: .seconds(Self.timeLimit))
            } catch is Command.TimedOut {
                throw Self.tooLong
            }
            // lsof exits with 1 both when nothing has it open and when some was found under a
            // folder. Only no output with an error is a failure; its usage text after is noise.
            let message = output.stderr.split(separator: "\n").first.map(String.init) ?? ""
            if output.status != 0, output.stdout.isEmpty, !message.isEmpty {
                throw CommandError(errorDescription: message.trimmingPrefix("lsof: ").description)
            }
            stdout = output.stdout
        }
        // Sorted by the full name shown, now that it's known, rather than lsof's short one.
        return FileHolder.parse(lsof: stdout)
            .map { holder in
                var holder = holder
                holder.path = ProcessDetails.executablePath(holder.pid)
                return holder
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let timeoutMarker = "powertoys-lsof-timed-out"
}

struct LiveProcessQuitter: ProcessQuitting {
    /// Apps are asked to quit as from the Dock, so they can offer to save. Other processes get
    /// SIGTERM, or SIGKILL with `force`; those belonging to another user, such as root, are
    /// signalled after an administrator password.
    func quit(_ pid: pid_t, force: Bool) async throws {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
            guard force ? app.forceTerminate() : app.terminate() else {
                throw CommandError(errorDescription: "\(app.localizedName ?? "The app") didn't respond.")
            }
            return
        }
        let signal = force ? SIGKILL : SIGTERM
        guard kill(pid, signal) != 0 else { return }
        guard errno == EPERM else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
        try await Command.runAsAdministrator(
            "kill -\(force ? "KILL" : "TERM") \(pid)", prompt: "\(AppInfo.name) wants to quit a process run by the system.")
    }

    func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// The file, folder or disk being checked, what has it open, and quitting those.
@Observable
final class LocksmithController {
    private(set) var target: URL?
    private(set) var holders: [FileHolder] = []
    private(set) var isScanning = false
    /// Whether the last scan saw processes run by the system and other users.
    private(set) var scannedAsAdministrator = false
    private(set) var hasScanned = false
    private(set) var error: String?
    private(set) var notice: String?
    /// Processes asked to quit that haven't yet.
    private(set) var quitting: Set<pid_t> = []
    /// Processes that ignored a request to quit, which can be force quit.
    private(set) var stubborn: Set<pid_t> = []
    /// Disks that can be ejected, to check from a menu.
    private(set) var volumes: [URL] = []

    @ObservationIgnored private let scanner: any FileHolderScanning
    @ObservationIgnored private let quitter: any ProcessQuitting
    @ObservationIgnored private let finder: any FinderAccess
    @ObservationIgnored private let ejector: @Sendable (URL) async throws -> Void
    @ObservationIgnored private let listVolumes: () -> [URL]
    @ObservationIgnored private let quitTimeout: Duration
    /// Counts scans, so a slow one that's been overtaken doesn't overwrite the newer result.
    @ObservationIgnored private var scanCount = 0

    init(
        scanner: any FileHolderScanning = LiveFileHolderScanner(),
        quitter: any ProcessQuitting = LiveProcessQuitter(),
        finder: any FinderAccess = LiveFinder(),
        eject: @escaping @Sendable (URL) async throws -> Void = LocksmithController.eject,
        volumes: @escaping () -> [URL] = { LiveSystemSettings.ejectableVolumes() },
        quitTimeout: Duration = .seconds(5)
    ) {
        self.scanner = scanner
        self.quitter = quitter
        self.finder = finder
        self.ejector = eject
        listVolumes = volumes
        self.quitTimeout = quitTimeout
    }

    /// Whether the target is a disk, which can be ejected. Read once per target.
    private(set) var targetIsVolume = false

    func refreshVolumes() {
        volumes = listVolumes()
    }

    /// Checks `url`, forgetting what was found for the last one.
    func check(_ url: URL) async {
        target = url.standardizedFileURL
        targetIsVolume = (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
        // Checking as administrator is asked for again for each new target.
        scannedAsAdministrator = false
        holders = []
        stubborn = []
        hasScanned = false
        notice = nil
        await scan()
    }

    func checkFinderSelection() async {
        do {
            guard let first = try await finder.selection().first else {
                error = "Nothing is selected in Finder."
                return
            }
            await check(first)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Looks again at what has the target open; as administrator, system processes are listed too.
    func scan(asAdministrator: Bool? = nil) async {
        guard let target else { return }
        let asAdministrator = asAdministrator ?? scannedAsAdministrator
        scanCount += 1
        let scan = scanCount
        isScanning = true
        defer { if scan == scanCount { isScanning = false } }
        do {
            let found = try await scanner.holders(of: target, asAdministrator: asAdministrator)
            guard scan == scanCount, target == self.target else { return }
            holders = found
            stubborn.formIntersection(Set(found.map(\.pid)))
            scannedAsAdministrator = asAdministrator
            hasScanned = true
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard scan == scanCount else { return }
            self.error = "Couldn't check: \(error.localizedDescription)"
        }
    }

    /// Asks the process to quit, or makes it with `force`. One still running after a few
    /// seconds can then be force quit.
    func quit(_ holder: FileHolder, force: Bool = false) async {
        let pid = holder.pid
        guard force || !quitting.contains(pid) else { return }
        // Marked before asking, which can wait on a password, so a second click doesn't ask again.
        let marked = quitting.insert(pid).inserted
        do {
            try await quitter.quit(pid, force: force)
        } catch is CancellationError {
            if marked { quitting.remove(pid) }
            return
        } catch {
            if marked { quitting.remove(pid) }
            self.error = "Couldn't quit \(holder.name): \(error.localizedDescription)"
            return
        }
        error = nil
        let clock = ContinuousClock()
        let deadline = clock.now + quitTimeout
        while quitter.isRunning(pid), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        quitting.remove(pid)
        if quitter.isRunning(pid) {
            stubborn.insert(pid)
        } else {
            stubborn.remove(pid)
            holders.removeAll { $0.pid == pid }
        }
        await scan()
    }

    /// Ejects the target disk, once nothing has it open.
    func ejectTarget() async {
        guard let target, targetIsVolume else { return }
        do {
            try await ejector(target)
            notice = "Ejected \(target.lastPathComponent)."
            self.target = nil
            targetIsVolume = false
            holders = []
            hasScanned = false
            error = nil
            refreshVolumes()
        } catch {
            self.error = "Couldn't eject \(target.lastPathComponent): \(error.localizedDescription)"
            await scan()
        }
    }

    func status(of holder: FileHolder) -> String? {
        if quitting.contains(holder.pid) { return "Quitting…" }
        if stubborn.contains(holder.pid) { return "Didn't quit. Force quit to stop it now." }
        return nil
    }

    /// Unmounting waits on the disk, so it runs off the main thread.
    @concurrent
    nonisolated static func eject(_ volume: URL) async throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
    }
}
