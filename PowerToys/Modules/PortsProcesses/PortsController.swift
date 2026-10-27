import Darwin
import Foundation
import Observation
import Synchronization

/// Finds listening ports; a protocol so tests don't run lsof.
protocol PortScanning: Sendable {
    func listeners() async throws -> [Listener]
}

/// Sends signals to processes; a protocol so tests don't kill anything.
protocol ProcessSignaling {
    /// 0, or the errno it failed with.
    func send(_ signal: Int32, to pid: pid_t) -> Int32
    func isRunning(_ pid: pid_t) -> Bool
}

nonisolated final class LivePortScanner: PortScanning, Sendable {
    /// Details of processes seen before, so each refresh reads only new ones.
    private let cache = Mutex<[pid_t: ProcessDetails]>([:])

    func listeners() async throws -> [Listener] {
        let output = try await Command.run(
            "/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcRn"], timeout: .seconds(10)
        )
        return await withDetails(try Self.listeners(from: output))
    }

    /// lsof exits with 1 both when nothing matches and after warnings, such as about a network
    /// volume that doesn't answer, while still listing what it found. Only no output with an
    /// error message is a failure.
    static func listeners(from output: Command.Output) throws -> [Listener] {
        let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.status != 0, output.stdout.isEmpty, !message.isEmpty {
            throw CommandError(errorDescription: message)
        }
        return Listener.parse(lsof: output.stdout)
    }

    @concurrent
    private func withDetails(_ listeners: [Listener]) async -> [Listener] {
        let cached = cache.withLock { $0 }
        let details = ProcessDetails.details(
            for: Set(listeners.map(\.pid)), cached: cached,
            startTime: ProcessDetails.startTime, read: ProcessDetails.read
        )
        cache.withLock { $0 = details }
        return listeners.map { listener in
            var listener = listener
            listener.process = details[listener.pid]
            return listener
        }
    }
}

struct LiveProcessSignaling: ProcessSignaling {
    func send(_ signal: Int32, to pid: pid_t) -> Int32 {
        kill(pid, signal) == 0 ? 0 : errno
    }

    func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// What's listening, kept up to date while it's on screen, and quitting it.
@Observable
final class PortsController {
    private(set) var listeners: [Listener] = []
    private(set) var isLoaded = false
    private(set) var error: String?
    /// Processes asked to quit that haven't yet.
    private(set) var quitting: Set<pid_t> = []
    /// Processes that ignored a request to quit, which can be force quit.
    private(set) var stubborn: Set<pid_t> = []

    var showsSystemServices: Bool {
        didSet { defaults.set(showsSystemServices, forKey: Self.showsSystemServicesKey) }
    }

    var showsInMenuBar: Bool {
        didSet { defaults.set(showsInMenuBar, forKey: Self.showsInMenuBarKey) }
    }

    static let showsSystemServicesKey = "ports.showsSystemServices"
    static let showsInMenuBarKey = "ports.showsInMenuBar"
    /// How often the list refreshes while it's on screen.
    static let refreshInterval: Duration = .seconds(2)

    private let defaults: UserDefaults
    @ObservationIgnored private let scanner: any PortScanning
    @ObservationIgnored private let signaling: any ProcessSignaling
    /// How long a process gets to quit before it's offered a force quit.
    @ObservationIgnored private let quitTimeout: Duration
    @ObservationIgnored private var isRefreshing = false
    /// Set when a refresh is asked for while one is running, so it runs again after.
    @ObservationIgnored private var needsRefresh = false
    /// Counts processes that quit, so a scan started before one did isn't used.
    @ObservationIgnored private var quitCount = 0

    init(
        defaults: UserDefaults = .standard,
        scanner: any PortScanning = LivePortScanner(),
        signaling: any ProcessSignaling = LiveProcessSignaling(),
        quitTimeout: Duration = .seconds(3)
    ) {
        self.quitTimeout = quitTimeout
        self.defaults = defaults
        self.scanner = scanner
        self.signaling = signaling
        showsSystemServices = defaults.bool(forKey: Self.showsSystemServicesKey)
        showsInMenuBar = defaults.object(forKey: Self.showsInMenuBarKey) as? Bool ?? true
    }

    /// The listeners to show, without system services unless they're asked for.
    var visibleListeners: [Listener] {
        showsSystemServices ? listeners : listeners.filter { !$0.isSystem }
    }

    /// Scans again. While a scan is running, another is queued to run once it finishes, and a
    /// scan that started before a process quit is thrown away and run again.
    func refresh() async {
        guard !isRefreshing else {
            needsRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsRefresh = false
            let quitsBefore = quitCount
            do {
                let scanned = try await scanner.listeners()
                guard quitCount == quitsBefore else {
                    needsRefresh = true
                    continue
                }
                listeners = scanned
                stubborn.formIntersection(Set(scanned.map(\.pid)))
                isLoaded = true
                error = nil
            } catch is CancellationError {
                return
            } catch {
                self.error = "Couldn't list ports: \(error.localizedDescription)"
            }
        } while needsRefresh
    }

    /// Refreshes until the calling task is cancelled, as when the view showing it goes away.
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// Asks the process to quit, as `kill` does, or makes it with `force`, as `kill -9` does.
    /// Quitting leaves the workers to the process, which stops them itself; force quitting
    /// kills them too, so none is left holding the port. A process still running a few seconds
    /// later can then be force quit.
    func quit(_ listener: Listener, force: Bool = false) async {
        let pid = listener.pid
        // Force quitting is allowed while waiting for a quit, rather than waiting it out.
        guard force || !quitting.contains(pid) else { return }
        let result = signaling.send(force ? SIGKILL : SIGTERM, to: pid)
        if force, result == 0 {
            for worker in listener.workers { _ = signaling.send(SIGKILL, to: worker) }
        }
        guard result == 0 else {
            error = result == EPERM
                ? "\(listener.name) belongs to another user, so it can't be quit from here."
                : "Couldn't quit \(listener.name): \(String(cString: strerror(result)))"
            return
        }
        error = nil
        quitting.insert(pid)
        let clock = ContinuousClock()
        let deadline = clock.now + quitTimeout
        let isRunning = { listener.allPIDs.contains { self.signaling.isRunning($0) } }
        while isRunning(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        quitting.remove(pid)
        if isRunning() {
            stubborn.insert(pid)
        } else {
            stubborn.remove(pid)
            listeners.removeAll { $0.pid == pid }
            quitCount += 1
        }
        await refresh()
    }

    func status(of listener: Listener) -> String? {
        if quitting.contains(listener.pid) { return "Quitting…" }
        if stubborn.contains(listener.pid) { return "Didn't quit. Force quit to stop it now." }
        return nil
    }
}
