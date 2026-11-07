import Darwin
import Foundation

/// The processor's time counters since startup, for working out how busy it was between two reads.
nonisolated struct CPUTicks: Hashable, Sendable {
    var busy: UInt64
    var total: UInt64

    /// The share of time all cores were busy since `earlier`, from 0 to 1.
    func usage(since earlier: CPUTicks) -> Double? {
        guard total > earlier.total, busy >= earlier.busy else { return nil }
        return min(1, Double(busy - earlier.busy) / Double(total - earlier.total))
    }

    /// The host port, looked up once: each `mach_host_self()` call adds a reference that's never
    /// released.
    static let host = mach_host_self()

    static func read() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(Self.host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // User, system, idle and nice, in that order.
        let (user, system, idle, nice) = info.cpu_ticks
        let busy = UInt64(user) + UInt64(system) + UInt64(nice)
        return CPUTicks(busy: busy, total: busy + UInt64(idle))
    }
}

/// Memory in use the way Activity Monitor counts it: app memory, wired and compressed.
nonisolated struct MemoryUsage: Hashable, Sendable {
    var used: UInt64
    var total: UInt64

    var fraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }

    init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }

    init(stats: vm_statistics64, pageSize: UInt64, total: UInt64) {
        let appPages = UInt64(stats.internal_page_count)
        let app = appPages - min(appPages, UInt64(stats.purgeable_count))
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        self.init(used: pages * pageSize, total: total)
    }

    static func read() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(CPUTicks.host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryUsage(stats: stats, pageSize: UInt64(getpagesize()), total: ProcessInfo.processInfo.physicalMemory)
    }
}

/// Space on the startup disk. Available counts space macOS can free on its own, such as purgeable
/// files and local snapshots, as Finder does.
nonisolated struct StorageUsage: Hashable, Sendable {
    var total: Int64
    var available: Int64

    var used: Int64 { max(0, total - available) }
    var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    static func read(volume: URL = URL(filePath: "/")) -> StorageUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? volume.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return StorageUsage(total: Int64(total), available: available)
    }

    /// Working out the space available can take a moment, so it's read off the main thread.
    @concurrent
    static func readInBackground() async -> StorageUsage? {
        read()
    }
}

/// A running process and what it uses.
nonisolated struct ProcessUsage: Identifiable, Hashable, Sendable {
    let pid: pid_t
    /// Percent of one core, so a process busy on several goes over 100.
    let cpu: Double
    /// Resident memory, in bytes.
    let memory: Int64
    let path: String
    /// When it started, to tell it apart from a later process given its ID. Read only for the
    /// processes shown.
    var started: Date? = nil
    /// Who runs it; only your own processes can be quit.
    var uid: uid_t = getuid()

    var id: pid_t { pid }

    var name: String { URL(filePath: path).lastPathComponent }

    /// Part of macOS, such as loginwindow or the Dock; quitting one can log you out.
    var isSystem: Bool {
        SystemPaths.contains(path)
    }

    /// Processes from `ps -axo pid=,uid=,pcpu=,rss=,comm=` output. The command is the rest of the
    /// line, since paths can have spaces. Other users' processes may show a bare name, not a path.
    static func parse(ps output: String) -> [ProcessUsage] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = pid_t(fields[0]), let uid = uid_t(fields[1]), let cpu = Double(fields[2]),
                let rss = Int64(fields[3])
            else { return nil }
            return ProcessUsage(pid: pid, cpu: cpu, memory: rss * 1024, path: String(fields[4]), uid: uid)
        }
    }
}

/// One reading of everything the monitor shows.
nonisolated struct UsageSample: Sendable {
    var cpuTicks: CPUTicks?
    var memory: MemoryUsage?
    var storage: StorageUsage?
    var processes: [ProcessUsage]
}

/// Reads usage; a protocol so tests don't run ps.
protocol UsageSampling: Sendable {
    /// Free disk space is slow to work out, so it's read only when `includesStorage` is set.
    func sample(includesStorage: Bool) async throws -> UsageSample
}

nonisolated struct LiveUsageSampler: UsageSampling {
    /// Off the main thread: working out free disk space can take a moment.
    @concurrent
    func sample(includesStorage: Bool) async throws -> UsageSample {
        let output = try await Command.run("/bin/ps", ["-axo", "pid=,uid=,pcpu=,rss=,comm="], timeout: .seconds(10))
        return UsageSample(
            cpuTicks: CPUTicks.read(), memory: MemoryUsage.read(), storage: includesStorage ? StorageUsage.read() : nil,
            processes: ProcessUsage.parse(ps: output.stdout))
    }
}
