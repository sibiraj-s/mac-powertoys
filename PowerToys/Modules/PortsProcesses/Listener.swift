import Darwin
import Foundation

/// A process listening on a TCP port.
nonisolated struct Listener: Identifiable, Hashable, Sendable {
    let pid: pid_t
    let port: Int
    /// Where it listens: "*" for every interface, or addresses such as 127.0.0.1 and ::1.
    var addresses: [String]
    /// The process's name as lsof gives it, cut to a few characters.
    let command: String
    var process: ProcessDetails?
    var parentPID: pid_t?
    /// Child processes sharing the port, such as the worker `uvicorn --reload` or gunicorn runs
    /// the app in. They inherit the socket from this process, which is the one you started.
    var workers: [pid_t] = []

    var id: String { "\(pid):\(port)" }

    /// This process and its workers.
    var allPIDs: [pid_t] { [pid] + workers }

    /// Reachable from this Mac only, not from other devices on the network.
    var isLocalOnly: Bool {
        addresses.allSatisfy { $0 == "::1" || $0.hasPrefix("127.") }
    }

    var url: URL {
        URL(string: "http://localhost:\(port)")!
    }

    /// The executable's name in full, since lsof shortens it.
    var name: String {
        process?.path.map { URL(filePath: $0).lastPathComponent } ?? command
    }

    /// Something macOS runs, rather than something you started.
    var isSystem: Bool {
        guard let path = process?.path else { return false }
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).trimmingPrefix(":")
        guard !query.isEmpty else { return true }
        return String(port).hasPrefix(query) || allPIDs.contains { String($0) == query }
            || name.localizedCaseInsensitiveContains(query)
            || (process?.commandLine.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// Listeners from `lsof -F pcRn` output, one per process and port, by port, with workers
    /// folded into the process that started them.
    static func parse(lsof output: String) -> [Listener] {
        var listeners: [Listener] = []
        var pid: pid_t?
        var parentPID: pid_t?
        var command = ""
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = pid_t(value)
                parentPID = nil
                command = ""
            case "R":
                parentPID = pid_t(value)
            case "c":
                command = value
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = value[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if let index = listeners.firstIndex(where: { $0.pid == pid && $0.port == port }) {
                    if !listeners[index].addresses.contains(address) { listeners[index].addresses.append(address) }
                } else {
                    listeners.append(Listener(pid: pid, port: port, addresses: [address], command: command, parentPID: parentPID))
                }
            default:
                continue
            }
        }
        return foldingWorkers(listeners).sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Merges listeners whose parent listens on the same port into that parent.
    static func foldingWorkers(_ listeners: [Listener]) -> [Listener] {
        let byPortAndPID = Dictionary(listeners.map { (Key(port: $0.port, pid: $0.pid), $0) }, uniquingKeysWith: { first, _ in first })
        func root(of listener: Listener) -> pid_t {
            var current = listener
            var seen: Set<pid_t> = [current.pid]
            while let parent = current.parentPID, let next = byPortAndPID[Key(port: current.port, pid: parent)], seen.insert(parent).inserted {
                current = next
            }
            return current.pid
        }
        var merged: [Key: Listener] = [:]
        var order: [Key] = []
        for listener in listeners {
            let key = Key(port: listener.port, pid: root(of: listener))
            if merged[key] == nil {
                merged[key] = byPortAndPID[key]
                merged[key]?.workers = []
                order.append(key)
            }
            guard listener.pid != key.pid else { continue }
            merged[key]?.workers.append(listener.pid)
            for address in listener.addresses where merged[key]?.addresses.contains(address) == false {
                merged[key]?.addresses.append(address)
            }
        }
        return order.compactMap { merged[$0] }
    }

    private struct Key: Hashable {
        let port: Int
        let pid: pid_t
    }
}

/// What the system knows about a running process.
nonisolated struct ProcessDetails: Hashable, Sendable {
    var path: String?
    var arguments: [String]
    /// Its working folder, usually the project a dev server serves.
    var directory: String?
    var started: Date?

    /// The arguments, with the program by name rather than full path and the home folder as ~.
    var commandLine: String {
        guard let first = arguments.first else { return path ?? "" }
        let parts = [URL(filePath: first).lastPathComponent] + arguments.dropFirst().map(Self.abbreviatingHome)
        return parts.joined(separator: " ")
    }

    var shortDirectory: String? {
        directory.map(Self.abbreviatingHome)
    }

    /// "45s", "12m", "3h", "2d": how long a process has been running.
    static func uptime(since start: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func read(_ pid: pid_t, started: Date?) -> ProcessDetails {
        ProcessDetails(
            path: executablePath(pid), arguments: arguments(pid) ?? [],
            directory: workingDirectory(pid), started: started
        )
    }

    /// Details for each process, reusing cached ones whose start time still matches. A process's
    /// details don't change while it runs, and a reused PID has a new start time.
    static func details(
        for pids: Set<pid_t>, cached: [pid_t: ProcessDetails],
        startTime: (pid_t) -> Date?, read: (pid_t, Date?) -> ProcessDetails
    ) -> [pid_t: ProcessDetails] {
        var details: [pid_t: ProcessDetails] = [:]
        for pid in pids {
            let started = startTime(pid)
            if let known = cached[pid], started != nil, known.started == started {
                details[pid] = known
            } else {
                details[pid] = read(pid, started)
            }
        }
        return details
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    static func startTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_start_tvsec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseArguments(Array(buffer.prefix(size)))
    }

    /// KERN_PROCARGS2 is the argument count, the executable path, padding, then the arguments,
    /// each ending in a zero byte, followed by the environment.
    static func parseArguments(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > 4 else { return [] }
        let count = bytes.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
