import Darwin
import Foundation
import Testing
@testable import PowerToys

struct ListenerTests {
    @Test func parsesLsofAndMergesAddresses() {
        let output = """
            p680
            crapportd
            f12
            PTCP
            n*:49152
            f13
            n*:49152
            p4321
            cnode
            f20
            n127.0.0.1:3000
            f21
            n[::1]:3000
            f22
            n127.0.0.1:24678
            p99
            cpostgres
            f5
            n*:5432

            """
        let listeners = Listener.parse(lsof: output)
        #expect(listeners.map(\.port) == [3000, 5432, 24678, 49152])
        #expect(listeners[0].addresses == ["127.0.0.1", "::1"])
        #expect(listeners[0].command == "node")
        #expect(listeners[0].pid == 4321)
        #expect(listeners[0].isLocalOnly)
        #expect(!listeners[1].isLocalOnly)
        #expect(listeners[3].addresses == ["*"])
        #expect(Listener.parse(lsof: "").isEmpty)
    }

    @Test func foldsWorkersIntoTheProcessThatStartedThem() {
        // uvicorn --reload: the reloader (30749) opens the port; its worker inherits it.
        let output = """
            p30749
            R1200
            cpython3.1
            f3
            n127.0.0.1:8000
            p30784
            R30749
            cpython3.1
            f3
            n127.0.0.1:8000
            p30800
            R30784
            cpython3.1
            f3
            n127.0.0.1:8000
            p40000
            R30749
            cpython3.1
            f9
            n127.0.0.1:9000

            """
        let listeners = Listener.parse(lsof: output)
        #expect(listeners.map(\.port) == [8000, 9000])
        #expect(listeners[0].pid == 30749)
        #expect(listeners[0].workers == [30784, 30800])
        #expect(listeners[0].allPIDs == [30749, 30784, 30800])
        #expect(listeners[0].matches("30784"))
        // A child on a different port is its own listener.
        #expect(listeners[1].pid == 40000)
        #expect(listeners[1].workers.isEmpty)
    }

    @Test func unrelatedProcessesOnOnePortStayApart() {
        // Two processes with SO_REUSEPORT, neither started by the other.
        let output = "p1\nR100\ncone\nn*:7000\np2\nR100\nctwo\nn*:7000\n"
        #expect(Listener.parse(lsof: output).map(\.pid) == [1, 2])
    }

    @Test func lsofExitStatuses() throws {
        let found = "p1\ncnode\nn*:3000\n"
        // Nothing listening.
        #expect(try LivePortScanner.listeners(from: .init(status: 1, stdout: "", stderr: "")).isEmpty)
        // A warning, with results.
        let warned = try LivePortScanner.listeners(from: .init(status: 1, stdout: found, stderr: "lsof: WARNING: can't stat() nfs file system"))
        #expect(warned.map(\.port) == [3000])
        // A real failure.
        #expect(throws: CommandError.self) {
            try LivePortScanner.listeners(from: .init(status: 1, stdout: "", stderr: "lsof: unsupported option"))
        }
    }

    @Test func reusesDetailsOfProcessesSeenBefore() {
        let start = Date(timeIntervalSince1970: 1000)
        let cached: [pid_t: ProcessDetails] = [
            1: ProcessDetails(path: "/cached/one", arguments: [], started: start),
            2: ProcessDetails(path: "/cached/two", arguments: [], started: start),
        ]
        var reads: [pid_t] = []
        let details = ProcessDetails.details(
            for: [1, 2, 3], cached: cached,
            // PID 2 was reused by a new process.
            startTime: { $0 == 2 ? start.addingTimeInterval(50) : start },
            read: { pid, started in
                reads.append(pid)
                return ProcessDetails(path: "/fresh/\(pid)", arguments: [], started: started)
            }
        )
        #expect(Set(reads) == [2, 3])
        #expect(details[1]?.path == "/cached/one")
        #expect(details[2]?.path == "/fresh/2")
        #expect(details.count == 3)
    }

    @Test func namesAndSystemServices() {
        var listener = Listener(pid: 1, port: 3000, addresses: ["*"], command: "com.docke")
        #expect(listener.name == "com.docke")
        #expect(!listener.isSystem)
        listener.process = ProcessDetails(path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", arguments: [])
        #expect(listener.name == "com.docker.backend")
        listener.process?.path = "/usr/libexec/rapportd"
        #expect(listener.isSystem)
        #expect(listener.url.absoluteString == "http://localhost:3000")
    }

    @Test func filters() {
        let listener = Listener(
            pid: 4321, port: 3000, addresses: ["*"], command: "node",
            process: ProcessDetails(path: "/opt/homebrew/bin/node", arguments: ["/opt/homebrew/bin/node", "vite", "--port", "3000"])
        )
        #expect(listener.matches(""))
        #expect(listener.matches(":3000"))
        #expect(listener.matches("30"))
        #expect(listener.matches("4321"))
        #expect(listener.matches("NODE"))
        #expect(listener.matches("vite"))
        #expect(!listener.matches("5432"))
    }

    @Test func commandLinesAreShortened() {
        let home = NSHomeDirectory()
        let details = ProcessDetails(
            path: "/opt/homebrew/bin/node",
            arguments: ["/opt/homebrew/bin/node", "\(home)/code/app/node_modules/.bin/vite"],
            directory: "\(home)/code/app"
        )
        #expect(details.commandLine == "node ~/code/app/node_modules/.bin/vite")
        #expect(details.shortDirectory == "~/code/app")
        #expect(ProcessDetails.abbreviatingHome(home) == "~")
        #expect(ProcessDetails.abbreviatingHome("\(home)other") == "\(home)other")
    }

    @Test func parsesProcessArguments() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        bytes += Array("/usr/bin/python3".utf8) + [0, 0, 0]
        for argument in ["python3", "-m", "http.server"] {
            bytes += Array(argument.utf8) + [0]
        }
        bytes += Array("HOME=/Users/me".utf8) + [0]
        #expect(ProcessDetails.parseArguments(bytes) == ["python3", "-m", "http.server"])
        #expect(ProcessDetails.parseArguments([]) == [])
    }

    @Test func readsThisProcess() {
        let details = ProcessDetails.read(getpid(), started: ProcessDetails.startTime(getpid()))
        #expect(details.path != nil)
        #expect(!details.arguments.isEmpty)
        #expect(details.started.map { $0 < .now } == true)
        #expect(details.directory != nil)
    }

    @Test func uptimes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ProcessDetails.uptime(since: now.addingTimeInterval(-42), now: now) == "42s")
        #expect(ProcessDetails.uptime(since: now.addingTimeInterval(-600), now: now) == "10m")
        #expect(ProcessDetails.uptime(since: now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(ProcessDetails.uptime(since: now.addingTimeInterval(-3 * 86_400), now: now) == "3d")
        #expect(ProcessDetails.uptime(since: now.addingTimeInterval(60), now: now) == "0s")
    }
}

final class FakePortScanner: PortScanning, @unchecked Sendable {
    var listeners: [Listener] = []
    var fails = false
    private(set) var scans = 0

    /// Held scans return what was listening when they started, once `release()` is called.
    var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int { held.count }

    func listeners() async throws -> [Listener] {
        scans += 1
        if fails { throw CommandError(errorDescription: "lsof broke") }
        let snapshot = listeners
        if holds {
            await withCheckedContinuation { held.append($0) }
        }
        return snapshot
    }

    func release() {
        holds = false
        held.forEach { $0.resume() }
        held = []
    }
}

final class FakeSignaling: ProcessSignaling {
    var running: Set<pid_t> = []
    /// Processes that ignore SIGTERM.
    var ignoresTerm: Set<pid_t> = []
    var result: Int32 = 0
    private(set) var sent: [(Int32, pid_t)] = []
    var onQuit: ((pid_t) -> Void)?

    func send(_ signal: Int32, to pid: pid_t) -> Int32 {
        sent.append((signal, pid))
        guard result == 0 else { return result }
        if signal == SIGKILL || !ignoresTerm.contains(pid) {
            running.remove(pid)
            onQuit?(pid)
        }
        return 0
    }

    func isRunning(_ pid: pid_t) -> Bool { running.contains(pid) }
}

struct PortsControllerTests {
    private let node = Listener(pid: 10, port: 3000, addresses: ["127.0.0.1"], command: "node")
    private let rapportd = Listener(
        pid: 20, port: 49152, addresses: ["*"], command: "rapportd",
        process: ProcessDetails(path: "/usr/libexec/rapportd", arguments: [])
    )

    @Test func hidesSystemServicesUnlessAsked() async {
        let store = TestDefaults()
        let scanner = FakePortScanner()
        scanner.listeners = [node, rapportd]
        let controller = PortsController(defaults: store.defaults, scanner: scanner, signaling: FakeSignaling())
        await controller.refresh()
        #expect(controller.isLoaded)
        #expect(controller.visibleListeners == [node])
        #expect(controller.listeners.count - controller.visibleListeners.count == 1)

        controller.showsSystemServices = true
        #expect(controller.visibleListeners == [node, rapportd])
        #expect(PortsController(defaults: store.defaults, scanner: scanner, signaling: FakeSignaling()).showsSystemServices)
    }

    @Test func showsInTheMenuBarByDefault() {
        let store = TestDefaults()
        #expect(PortsController(defaults: store.defaults, scanner: FakePortScanner(), signaling: FakeSignaling()).showsInMenuBar)
    }

    @Test func scanFailuresAreShown() async {
        let store = TestDefaults()
        let scanner = FakePortScanner()
        scanner.fails = true
        let controller = PortsController(defaults: store.defaults, scanner: scanner, signaling: FakeSignaling())
        await controller.refresh()
        #expect(controller.error?.contains("lsof broke") == true)
        scanner.fails = false
        await controller.refresh()
        #expect(controller.error == nil)
    }

    @Test func quitsProcesses() async {
        let store = TestDefaults()
        let scanner = FakePortScanner()
        scanner.listeners = [node]
        let signaling = FakeSignaling()
        signaling.running = [10]
        signaling.onQuit = { pid in scanner.listeners.removeAll { $0.pid == pid } }
        let controller = PortsController(defaults: store.defaults, scanner: scanner, signaling: signaling)
        await controller.refresh()

        await controller.quit(node)
        #expect(signaling.sent.map(\.0) == [SIGTERM])
        #expect(controller.listeners.isEmpty)
        #expect(controller.stubborn.isEmpty)
        #expect(controller.quitting.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func offersForceQuitWhenIgnored() async {
        let store = TestDefaults()
        let scanner = FakePortScanner()
        scanner.listeners = [node]
        let signaling = FakeSignaling()
        signaling.running = [10]
        signaling.ignoresTerm = [10]
        signaling.onQuit = { pid in scanner.listeners.removeAll { $0.pid == pid } }
        let controller = PortsController(defaults: store.defaults, scanner: scanner, signaling: signaling, quitTimeout: .milliseconds(200))
        await controller.refresh()

        await controller.quit(node)
        #expect(controller.stubborn == [10])
        #expect(controller.status(of: node)?.contains("Force quit") == true)

        await controller.quit(node, force: true)
        #expect(signaling.sent.map(\.0) == [SIGTERM, SIGKILL])
        #expect(controller.stubborn.isEmpty)
        #expect(controller.listeners.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func forceQuitAlsoKillsWorkers() async {
        let store = TestDefaults()
        var server = node
        server.workers = [11]
        let scanner = FakePortScanner()
        scanner.listeners = [server]
        let signaling = FakeSignaling()
        signaling.running = [10, 11]
        signaling.ignoresTerm = [10, 11]
        let controller = PortsController(defaults: store.defaults, scanner: scanner, signaling: signaling, quitTimeout: .milliseconds(200))

        await controller.quit(server)
        #expect(signaling.sent.map(\.1) == [10])
        #expect(controller.stubborn == [10])

        await controller.quit(server, force: true)
        #expect(signaling.sent.map(\.0) == [SIGTERM, SIGKILL, SIGKILL])
        #expect(signaling.sent.map(\.1) == [10, 10, 11])
        #expect(signaling.running.isEmpty)
        #expect(controller.stubborn.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func waitsForWorkersAfterTheParentQuits() async {
        let store = TestDefaults()
        var server = node
        server.workers = [11]
        let signaling = FakeSignaling()
        signaling.running = [10, 11]
        let scanner = FakePortScanner()
        scanner.listeners = [server]
        // The worker outlives the parent, still holding the port.
        let controller = PortsController(defaults: store.defaults, scanner: scanner, signaling: signaling, quitTimeout: .milliseconds(200))
        await controller.quit(server)
        #expect(controller.stubborn == [10])
    }

    @Test(.timeLimit(.minutes(1)))
    func aScanFromBeforeAQuitDoesntBringItBack() async {
        let store = TestDefaults()
        let scanner = FakePortScanner()
        scanner.listeners = [node]
        let signaling = FakeSignaling()
        signaling.running = [10]
        signaling.onQuit = { pid in scanner.listeners.removeAll { $0.pid == pid } }
        let controller = PortsController(defaults: store.defaults, scanner: scanner, signaling: signaling)
        await controller.refresh()

        // A refresh, as the page's every two seconds, starts while node is still listening.
        scanner.holds = true
        let refresh = Task { await controller.refresh() }
        await waitUntil { scanner.heldCount == 1 }
        await controller.quit(node)
        scanner.release()
        await refresh.value

        #expect(controller.listeners.isEmpty)
        #expect(scanner.scans >= 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func forceQuitWorksWhileWaitingForAQuit() async {
        let store = TestDefaults()
        let signaling = FakeSignaling()
        signaling.running = [10]
        signaling.ignoresTerm = [10]
        let controller = PortsController(defaults: store.defaults, scanner: FakePortScanner(), signaling: signaling, quitTimeout: .seconds(30))

        let quit = Task { await controller.quit(node) }
        await waitUntil { controller.quitting.contains(10) }
        await controller.quit(node, force: true)
        await quit.value
        #expect(signaling.sent.map(\.0) == [SIGTERM, SIGKILL])
        #expect(signaling.running.isEmpty)
        #expect(controller.quitting.isEmpty)
        #expect(controller.stubborn.isEmpty)
    }

    @Test func otherUsersProcessesExplainWhy() async {
        let store = TestDefaults()
        let signaling = FakeSignaling()
        signaling.result = EPERM
        let controller = PortsController(defaults: store.defaults, scanner: FakePortScanner(), signaling: signaling)
        await controller.quit(node)
        #expect(controller.error?.contains("another user") == true)
        #expect(controller.quitting.isEmpty)
    }

    @Test func findsARealListener() async throws {
        // Opens a port in this process and checks lsof sees it.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))

        let listeners = try await LivePortScanner().listeners()
        let mine = try #require(listeners.first { $0.port == port })
        #expect(mine.pid == getpid())
        #expect(mine.isLocalOnly)
        #expect(mine.process?.path != nil)
    }
}
