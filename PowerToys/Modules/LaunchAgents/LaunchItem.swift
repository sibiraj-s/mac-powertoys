import Darwin
import Foundation

/// A folder launchd loads jobs from.
nonisolated enum LaunchLocation: String, CaseIterable, Identifiable, Sendable {
    case userAgents, agents, daemons, appleAgents, appleDaemons

    var id: Self { self }

    var directory: URL {
        switch self {
        case .userAgents: URL.homeDirectory.appending(path: "Library/LaunchAgents")
        case .agents: URL(filePath: "/Library/LaunchAgents")
        case .daemons: URL(filePath: "/Library/LaunchDaemons")
        case .appleAgents: URL(filePath: "/System/Library/LaunchAgents")
        case .appleDaemons: URL(filePath: "/System/Library/LaunchDaemons")
        }
    }

    var title: String {
        switch self {
        case .userAgents: "Your agents"
        case .agents: "Agents for all users"
        case .daemons: "Daemons"
        case .appleAgents: "Apple's agents"
        case .appleDaemons: "Apple's daemons"
        }
    }

    var summary: String {
        switch self {
        case .userAgents: "Run as you while you're logged in. From ~/Library/LaunchAgents."
        case .agents: "Run as each user who logs in, often installed by apps. From /Library/LaunchAgents."
        case .daemons: "Run as root, even before anyone logs in. Changing them asks for an administrator password."
        case .appleAgents, .appleDaemons: "Part of macOS, which protects them from changes."
        }
    }

    /// Daemons run in the system domain; agents in your login session's.
    var isDaemon: Bool { self == .daemons || self == .appleDaemons }

    var isApple: Bool { self == .appleAgents || self == .appleDaemons }

    /// Changing system daemons takes root.
    var needsAdministrator: Bool { self == .daemons }

    /// Only your own agents' files can be moved to the Trash without a password.
    var canTrash: Bool { self == .userAgents }

    func domain(uid: uid_t) -> LaunchDomain {
        isDaemon ? .system : .gui(uid)
    }
}

/// Where launchd runs a job: your login session, or the system.
nonisolated enum LaunchDomain: Hashable, Sendable {
    case gui(uid_t)
    case system

    var target: String {
        switch self {
        case .gui(let uid): "gui/\(uid)"
        case .system: "system"
        }
    }
}

/// A job's plist: what it runs and when.
nonisolated struct LaunchItem: Identifiable, Hashable, Sendable {
    let label: String
    let url: URL
    let location: LaunchLocation
    var program: [String]
    var schedule: String
    var logPaths: [String]
    var isDisabledInPlist: Bool
    /// The program it starts isn't there, as when its app was deleted but this was left behind.
    var isProgramMissing = false
    /// launchd starts it again as soon as it stops, so stopping it only restarts it.
    var restartsWhenStopped = false

    var id: String { url.path }

    /// The program by name, then its arguments, with the home folder as ~.
    var commandLine: String {
        guard let first = program.first else { return "" }
        return ([URL(filePath: first).lastPathComponent] + program.dropFirst().map(ProcessDetails.abbreviatingHome))
            .joined(separator: " ")
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || label.localizedCaseInsensitiveContains(query)
            || program.joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    /// Reads a plist; nil when it isn't a launchd job.
    static func parse(_ data: Data, url: URL, location: LaunchLocation) -> LaunchItem? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let label = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
        var program = plist["ProgramArguments"] as? [String] ?? []
        if let path = plist["Program"] as? String {
            if program.isEmpty { program = [path] } else { program[0] = path }
        }
        var logs: [String] = []
        for case let path as String in [plist["StandardOutPath"], plist["StandardErrorPath"]] where !logs.contains(path) {
            logs.append(path)
        }
        return LaunchItem(
            label: label, url: url, location: location, program: program,
            schedule: schedule(of: plist, isDaemon: location.isDaemon),
            logPaths: logs,
            isDisabledInPlist: plist["Disabled"] as? Bool ?? false,
            restartsWhenStopped: plist["KeepAlive"] as? Bool == true
        )
    }

    /// When the job runs, in words.
    static func schedule(of plist: [String: Any], isDaemon: Bool) -> String {
        var parts: [String] = []
        if let keepAlive = plist["KeepAlive"], keepAlive as? Bool != false {
            parts.append(keepAlive is Bool ? "Kept running" : "Kept running when needed")
        } else if plist["RunAtLoad"] as? Bool == true {
            parts.append(isDaemon ? "At startup" : "At login")
        }
        if let seconds = plist["StartInterval"] as? Int, seconds > 0 {
            parts.append("Every \(duration(seconds))")
        }
        if let calendar = plist["StartCalendarInterval"] {
            let entries = (calendar as? [[String: Int]]) ?? (calendar as? [String: Int]).map { [$0] } ?? []
            parts.append(entries.count == 1 ? calendarText(entries[0]) : "On a schedule")
        }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil {
            parts.append("When files change")
        }
        if parts.isEmpty, plist["MachServices"] != nil || plist["Sockets"] != nil {
            parts.append("When something asks for it")
        }
        return parts.isEmpty ? "Only when started" : parts.joined(separator: ", ")
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return seconds == 86_400 ? "day" : "\(seconds / 86_400) days" }
        if seconds % 3600 == 0 { return seconds == 3600 ? "hour" : "\(seconds / 3600) hours" }
        if seconds % 60 == 0 { return seconds == 60 ? "minute" : "\(seconds / 60) minutes" }
        return "\(seconds) seconds"
    }

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let months = [
        "", "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    private static func calendarText(_ entry: [String: Int]) -> String {
        let minute = entry["Minute"] ?? 0
        guard let hour = entry["Hour"] else {
            return entry.keys.allSatisfy({ $0 == "Minute" }) ? "Hourly at :\(String(format: "%02d", minute))" : "On a schedule"
        }
        let time = String(format: "%02d:%02d", hour, minute)
        var month: String?
        if let number = entry["Month"] {
            guard (1...12).contains(number) else { return "On a schedule" }
            month = months[number]
        }
        switch (entry["Weekday"], entry["Day"]) {
        case (nil, nil):
            return month.map { "Daily in \($0) at \(time)" } ?? "Daily at \(time)"
        case (let weekday?, nil) where weekdays.indices.contains(weekday):
            return "\(weekdays[weekday])s\(month.map { " in \($0)" } ?? "") at \(time)"
        case (nil, let day?):
            return month.map { "Yearly on \($0) \(day) at \(time)" } ?? "Monthly on day \(day) at \(time)"
        default:
            // A weekday and a day of the month run on either, which is hard to say briefly.
            return "On a schedule"
        }
    }
}

/// What launchd says about the jobs in one domain.
nonisolated struct DomainState: Equatable, Sendable {
    struct Service: Equatable, Sendable {
        var pid: pid_t?
        /// The last exit code, or a negative signal number when it was killed.
        var lastExitStatus: Int?
    }

    var services: [String: Service] = [:]
    /// Labels switched on (false) or off (true) with `launchctl enable` and `disable`.
    var disabled: [String: Bool] = [:]

    /// The `services = { ... }` block of `launchctl print <domain>`: PID, last exit status, label.
    static func services(fromPrint output: String) -> [String: Service] {
        var services: [String: Service] = [:]
        var inBlock = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" { inBlock = true; continue }
            guard inBlock else { continue }
            if trimmed == "}" { break }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3 else { continue }
            let pid = pid_t(fields[0]).flatMap { $0 > 0 ? $0 : nil }
            services[fields[2...].joined(separator: " ")] = Service(pid: pid, lastExitStatus: Int(fields[1]))
        }
        return services
    }

    /// `launchctl print-disabled <domain>`: `"label" => disabled`, or enabled, or true and false
    /// on older systems.
    static func disabled(fromPrintDisabled output: String) -> [String: Bool] {
        var disabled: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=>", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].hasPrefix("\""), parts[0].hasSuffix("\""), parts[0].count >= 2 else { continue }
            let label = String(parts[0].dropFirst().dropLast())
            switch parts[1] {
            case "disabled", "true": disabled[label] = true
            case "enabled", "false": disabled[label] = false
            default: continue
            }
        }
        return disabled
    }
}

/// A job's state, put together from its plist and its domain.
nonisolated struct LaunchStatus: Equatable, Sendable {
    var isEnabled: Bool
    var isLoaded: Bool
    var pid: pid_t?
    var lastExitStatus: Int?

    init(item: LaunchItem, domain: DomainState?) {
        isEnabled = !(domain?.disabled[item.label] ?? item.isDisabledInPlist)
        let service = domain?.services[item.label]
        isLoaded = service != nil
        pid = service?.pid
        lastExitStatus = service?.lastExitStatus
    }

    init(isEnabled: Bool, isLoaded: Bool, pid: pid_t? = nil, lastExitStatus: Int? = nil) {
        self.isEnabled = isEnabled
        self.isLoaded = isLoaded
        self.pid = pid
        self.lastExitStatus = lastExitStatus
    }

    /// Something went wrong last time it ran.
    var hasFailed: Bool {
        pid == nil && (lastExitStatus ?? 0) != 0
    }

    var text: String {
        if let pid { return "Running · PID \(pid)" }
        if !isEnabled { return isLoaded ? "Off, still loaded" : "Off" }
        if let status = lastExitStatus, status != 0 {
            return status < 0 ? "Stopped by signal \(-status)" : "Exited with code \(status)"
        }
        return isLoaded ? "Waiting to run" : "Not loaded"
    }
}

/// What can be done to a job.
nonisolated enum LaunchAction: Sendable {
    case enable, disable, start, restart, stop
    /// Unloads it without switching it off, so it loads again if it's put back or reinstalled.
    case unload

    /// The `launchctl` invocations, in order. Switching on also loads it, and off unloads it,
    /// so the change takes effect now as well as at the next login.
    static func commands(for action: LaunchAction, item: LaunchItem, domain: LaunchDomain, isLoaded: Bool) -> [[String]] {
        let service = "\(domain.target)/\(item.label)"
        let load = ["bootstrap", domain.target, item.url.path]
        switch action {
        case .enable:
            return [["enable", service]] + (isLoaded ? [] : [load])
        case .disable:
            return (isLoaded ? [["bootout", service]] : []) + [["disable", service]]
        case .start:
            return (isLoaded ? [] : [load]) + [["kickstart", service]]
        case .restart:
            return [["kickstart", "-k", service]]
        case .stop:
            return [["kill", "SIGTERM", service]]
        case .unload:
            return isLoaded ? [["bootout", service]] : []
        }
    }
}
