import Darwin
import Foundation

/// A line of the hosts file that points host names at an address, possibly commented out.
nonisolated struct HostEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var address: String
    var hostnames: [String]
    var comment: String?
    var isEnabled: Bool
    /// The line as read, so saving leaves entries nobody changed exactly as they were.
    var source: String?

    init(
        id: UUID = UUID(), address: String, hostnames: [String], comment: String? = nil,
        isEnabled: Bool = true, source: String? = nil
    ) {
        self.id = id
        self.address = address
        self.hostnames = hostnames
        self.comment = comment
        self.isEnabled = isEnabled
        self.source = source
    }

    /// Reads an entry from a line; nil for comments, blank lines and anything else.
    init?(line: String) {
        var body = line.trimmingCharacters(in: .whitespaces)
        let isEnabled = !body.hasPrefix("#")
        if !isEnabled {
            body = String(body.drop { $0 == "#" })
        }
        var comment: String?
        if let hash = body.firstIndex(of: "#") {
            comment = body[body.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            body = String(body[..<hash])
        }
        let fields = body.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, Self.isValidAddress(fields[0]) else { return nil }
        let hostnames = Array(fields.dropFirst())
        // A commented-out line only counts when it reads like an entry rather than prose such as
        // "# 10.0.0.1 is the router": host names with dots, or the way PowerToys writes entries.
        if !isEnabled {
            let looksLikeHosts = hostnames.allSatisfy { $0.contains(".") || Self.systemNames.contains($0.lowercased()) }
            let writtenByUs = line.hasPrefix("# \(fields[0])\t")
            guard hostnames.allSatisfy(Self.isValidHostname), looksLikeHosts || writtenByUs else { return nil }
        }
        self.init(
            address: fields[0], hostnames: hostnames, comment: comment?.isEmpty == false ? comment : nil,
            isEnabled: isEnabled, source: line
        )
    }

    var line: String {
        if let source { return source }
        var line = "\(address)\t\(hostnames.joined(separator: " "))"
        if let comment, !comment.isEmpty { line += " # \(comment)" }
        return isEnabled ? line : "# " + line
    }

    static let systemNames: Set<String> = ["localhost", "broadcasthost"]

    /// Lines with localhost or broadcasthost, which macOS needs. Shown, but not editable, even
    /// when other names share the line, since switching it off would break localhost too.
    var isSystem: Bool {
        hostnames.contains { Self.systemNames.contains($0.lowercased()) }
    }

    var isIPv6: Bool { address.contains(":") }

    // MARK: Validation

    static func isValidAddress(_ address: String) -> Bool {
        // IPv6 link-local addresses carry a zone, as in fe80::1%lo0.
        let host = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var buffer = in6_addr()
        return inet_pton(AF_INET, host, &buffer) == 1 || inet_pton(AF_INET6, host, &buffer) == 1
    }

    static func isValidHostname(_ name: String) -> Bool {
        guard (1...253).contains(name.count) else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.count)
                && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Host names as typed: separated by spaces or commas.
    static func hostnames(from text: String) -> [String] {
        text.split { $0.isWhitespace || $0 == "," }.map(String.init)
    }

    /// What's wrong with an entry being typed, or nil when it can be saved.
    static func problem(address: String, hostnames: [String]) -> String? {
        let address = address.trimmingCharacters(in: .whitespaces)
        if address.isEmpty { return "Enter an address, such as 127.0.0.1." }
        if !isValidAddress(address) { return "“\(address)” isn't an IPv4 or IPv6 address." }
        if hostnames.isEmpty { return "Enter at least one host name." }
        if let bad = hostnames.first(where: { !isValidHostname($0) }) { return "“\(bad)” isn't a valid host name." }
        if let system = hostnames.first(where: { systemNames.contains($0.lowercased()) }) {
            return "\(system) is built in and can't be changed here."
        }
        return nil
    }
}

/// /etc/hosts as lines, so it can be edited without disturbing what PowerToys doesn't touch.
/// Groups are blocks between marker comments; they still work if PowerToys is removed.
nonisolated struct HostsFile: Equatable, Sendable {
    enum Line: Equatable, Sendable {
        case entry(HostEntry)
        case groupStart(String)
        case groupEnd
        case other(String)

        var text: String {
            switch self {
            case .entry(let entry): entry.line
            case .groupStart(let name): HostsFile.groupStartPrefix + name
            case .groupEnd: HostsFile.groupEndMarker
            case .other(let text): text
            }
        }
    }

    /// The entries outside any group (`name` nil), or in one group.
    struct Section: Identifiable, Equatable, Sendable {
        let name: String?
        var entries: [HostEntry]

        var id: String { name.map { "group:\($0)" } ?? "ungrouped" }
    }

    static let path = "/etc/hosts"
    static let groupStartPrefix = "# >>> PowerToys: "
    static let groupEndMarker = "# <<< PowerToys"

    private(set) var lines: [Line]

    /// Entries whose line is unchanged from `previous` keep their ids, so rows and open editors
    /// still find them after a reload.
    init(text: String, reusingIDsFrom previous: HostsFile? = nil) {
        var raw = text.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        var previousIDs = Dictionary(grouping: previous?.entries ?? [], by: \.line).mapValues { $0.map(\.id) }
        var names: Set<String> = []
        lines = raw.map { line in
            if line.hasPrefix(Self.groupStartPrefix) {
                let name = line.dropFirst(Self.groupStartPrefix.count).trimmingCharacters(in: .whitespaces)
                // A second group by the same name, from editing by hand, is left as a comment.
                if !name.isEmpty, names.insert(name.lowercased()).inserted { return .groupStart(name) }
            }
            if line.trimmingCharacters(in: .whitespaces) == Self.groupEndMarker { return .groupEnd }
            if var entry = HostEntry(line: line) {
                if let id = previousIDs[line]?.first {
                    previousIDs[line]?.removeFirst()
                    entry = HostEntry(
                        id: id, address: entry.address, hostnames: entry.hostnames, comment: entry.comment,
                        isEnabled: entry.isEnabled, source: entry.source
                    )
                }
                return .entry(entry)
            }
            return .other(line)
        }
    }

    var text: String {
        lines.map(\.text).joined(separator: "\n") + "\n"
    }

    // MARK: Reading

    /// Each line's group, or nil outside groups. A group without an end marker runs to the end.
    private var groupsByLine: [String?] {
        var current: String?
        return lines.map { line in
            switch line {
            case .groupStart(let name):
                current = name
                return name
            case .groupEnd:
                defer { current = nil }
                return current
            default:
                return current
            }
        }
    }

    var groups: [String] {
        lines.compactMap { if case .groupStart(let name) = $0 { name } else { nil } }
    }

    /// Entries outside groups first, then each group in file order. Built-in entries are left out.
    var sections: [Section] {
        var sections = [Section(name: nil, entries: [])] + groups.map { Section(name: $0, entries: []) }
        for (line, group) in zip(lines, groupsByLine) {
            guard case .entry(let entry) = line, !entry.isSystem,
                  let index = sections.firstIndex(where: { $0.name == group })
            else { continue }
            sections[index].entries.append(entry)
        }
        return sections
    }

    var entries: [HostEntry] {
        lines.compactMap { if case .entry(let entry) = $0 { entry } else { nil } }
    }

    var systemEntries: [HostEntry] {
        entries.filter(\.isSystem)
    }

    func entry(_ id: HostEntry.ID) -> HostEntry? {
        entries.first { $0.id == id }
    }

    func group(of id: HostEntry.ID) -> String? {
        guard let index = index(of: id) else { return nil }
        return groupsByLine[index]
    }

    /// Host names this entry sets that an earlier, switched-on line already set for the same kind
    /// of address. The first match wins, so the entry has no effect for them.
    func shadowedHostnames(of entry: HostEntry) -> [String] {
        guard entry.isEnabled, let position = index(of: entry.id) else { return [] }
        let earlier = lines[..<position].compactMap { line -> HostEntry? in
            guard case .entry(let other) = line, other.isEnabled, other.isIPv6 == entry.isIPv6 else { return nil }
            return other
        }
        let taken = Set(earlier.flatMap(\.hostnames).map { $0.lowercased() })
        return entry.hostnames.filter { taken.contains($0.lowercased()) }
    }

    static func problem(groupName: String, existing: [String]) -> String? {
        let name = groupName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Enter a name." }
        if name.contains(where: \.isNewline) { return "Use a single line." }
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "There's already a group called “\(name)”."
        }
        return nil
    }

    // MARK: Changing

    mutating func add(_ entry: HostEntry, to group: String? = nil) {
        var entry = entry
        entry.source = nil
        lines.insert(.entry(entry), at: insertionIndex(in: group))
    }

    mutating func update(_ entry: HostEntry) {
        guard let index = index(of: entry.id) else { return }
        var entry = entry
        entry.source = nil
        lines[index] = .entry(entry)
    }

    mutating func remove(_ id: HostEntry.ID) {
        guard let index = index(of: id) else { return }
        lines.remove(at: index)
    }

    mutating func setEnabled(_ id: HostEntry.ID, _ isEnabled: Bool) {
        guard var entry = entry(id), entry.isEnabled != isEnabled else { return }
        entry.isEnabled = isEnabled
        update(entry)
    }

    mutating func move(_ id: HostEntry.ID, to group: String?) {
        guard let entry = entry(id), self.group(of: id) != group else { return }
        remove(id)
        add(entry, to: group)
    }

    mutating func setEnabled(group: String, _ isEnabled: Bool) {
        for section in sections where section.name == group {
            for entry in section.entries {
                setEnabled(entry.id, isEnabled)
            }
        }
    }

    mutating func addGroup(_ name: String) {
        if let last = lines.last, last != .other("") {
            lines.append(.other(""))
        }
        lines.append(.groupStart(name))
        lines.append(.groupEnd)
    }

    mutating func renameGroup(_ name: String, to newName: String) {
        guard let start = lines.firstIndex(of: .groupStart(name)) else { return }
        lines[start] = .groupStart(newName)
    }

    /// Removes a group and the entries in it.
    mutating func removeGroup(_ name: String) {
        guard let range = lineRange(ofGroup: name) else { return }
        let start = range.lowerBound
        lines.removeSubrange(range)
        // The blank line addGroup put before it.
        if start > 0, lines[start - 1] == .other(""), start == lines.endIndex || lines[start] == .other("") {
            lines.remove(at: start - 1)
        }
    }

    private func index(of id: HostEntry.ID) -> Int? {
        lines.firstIndex { if case .entry(let entry) = $0 { entry.id == id } else { false } }
    }

    /// A group's lines, from its start marker through its end marker. A group without an end
    /// marker stops before the next group.
    private func lineRange(ofGroup name: String) -> Range<Int>? {
        guard let start = lines.firstIndex(of: .groupStart(name)) else { return nil }
        for index in lines.indices.dropFirst(start + 1) {
            switch lines[index] {
            case .groupEnd: return start..<(index + 1)
            case .groupStart: return start..<index
            default: continue
            }
        }
        return start..<lines.endIndex
    }

    /// At the end of the group, or, outside groups, after the last entry that isn't in one.
    private func insertionIndex(in group: String?) -> Int {
        let groupsByLine = groupsByLine
        if let group, let range = lineRange(ofGroup: group) {
            let last = range.upperBound - 1
            return lines[last] == .groupEnd ? last : range.upperBound
        }
        let ungrouped = lines.indices.filter { index in
            if case .entry = lines[index], groupsByLine[index] == nil { true } else { false }
        }
        if let last = ungrouped.last { return last + 1 }
        return lines.firstIndex { if case .groupStart = $0 { true } else { false } } ?? lines.endIndex
    }
}
