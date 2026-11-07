import Darwin
import Foundation

/// Where macOS keeps what it runs, as opposed to what you installed, such as /usr/local.
nonisolated enum SystemPaths {
    static func contains(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
}

/// When a process started, to tell it apart from a later process given the same ID.
nonisolated enum ProcessStart {
    /// From the kernel's process table, which any user can read, unlike `proc_pidinfo` for
    /// another user's process. Nil when no process has the ID.
    static func read(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}

/// An app bundle's ID, read from its Info.plist rather than through `Bundle`, which keeps every
/// bundle it opens for the life of the process.
nonisolated enum AppBundle {
    static func identifier(atPath path: String) -> String? {
        let info = URL(filePath: path).appending(path: "Contents/Info.plist")
        return NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String
    }
}
