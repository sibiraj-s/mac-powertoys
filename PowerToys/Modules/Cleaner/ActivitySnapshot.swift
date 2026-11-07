import Darwin
import Foundation

/// What's running and which files are open, read once per scan, for telling which cleanup items
/// are in use. Anything it couldn't read is nil, and items that depend on it are kept, since not
/// knowing isn't proof something is idle.
nonisolated struct ActivitySnapshot: Sendable {
    /// Every process's command line, lowercased.
    let commandLines: [String]?
    /// Bundle IDs of the app bundles running processes are in, helpers included, lowercased.
    let bundleIDs: Set<String>
    /// Paths open in this user's processes, lowercased, since Mac disks usually ignore case and
    /// a process can open a path in other capitals than the folder's.
    let openFiles: [String]?
    /// The words of each command line that isn't inside an app bundle, such as daemons'.
    private let daemonWords: [Set<Substring>]

    init(commandLines: [String]?, bundleIDs: Set<String>, openFiles: [String]?) {
        let lines = commandLines?.map { $0.lowercased() }
        self.commandLines = lines
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        // Sorted, so each check is a search rather than a pass over every open file.
        self.openFiles = openFiles?.map { $0.lowercased() }.sorted()
        daemonWords = (lines ?? []).filter { !$0.contains(".app/") }.map(Self.words)
    }

    /// Whether the app or process a cache folder is named after, such as com.apple.bird, is
    /// running; nil when the process list couldn't be read. Only names shaped like bundle IDs are
    /// checked. A process counts as the owner when:
    /// - it's in an app bundle with that ID, or one the ID extends, such as com.example.App.ShipIt;
    /// - its command line mentions the whole ID; or
    /// - outside an app bundle, its command line has the ID's last part as a word along with
    ///   another distinctive part, as `/usr/libexec/bird` does for com.apple.bird.
    func ownerIsRunning(_ name: String) -> Bool? {
        // Without the process list, nothing can be said to be idle.
        guard let commandLines else { return nil }
        let name = name.lowercased()
        let parts = name.split(separator: ".")
        guard parts.count >= 3, !name.contains(" ") else { return false }
        if bundleIDs.contains(where: { name == $0 || name.hasPrefix($0 + ".") || $0.hasPrefix(name + ".") }) {
            return true
        }
        if commandLines.contains(where: { $0.contains(name) }) { return true }
        guard let leaf = parts.last, leaf.count >= 4 else { return false }
        // "com" and short parts are in too many names to tell anything.
        let others = parts.dropLast().filter { $0.count >= 4 && $0 != "com" }
        guard !others.isEmpty else { return false }
        return daemonWords.contains { words in words.contains(leaf) && others.contains(where: words.contains) }
    }

    /// Whether npm or npx is running; nil when the process list couldn't be read. Any word counts,
    /// not just the first, as npm usually runs through node: `node /opt/homebrew/bin/npm install`.
    var npmIsRunning: Bool? {
        guard let commandLines else { return nil }
        if commandLines.contains(where: { $0.contains("npm-cli.js") || $0.contains("npx-cli.js") }) { return true }
        return isRunning(program: "npm") == true || isRunning(program: "npx") == true
    }

    /// Whether an app's own program runs, as `<App>.app/Contents/MacOS/<executable>`, rather than
    /// some tool inside the app's bundle; nil when the process list couldn't be read.
    func isAppRunning(executable: String) -> Bool? {
        let program = ".app/contents/macos/\(executable.lowercased())"
        return commandLines.map { lines in
            lines.contains { line in
                guard let range = line.range(of: program) else { return false }
                return range.upperBound == line.endIndex || line[range.upperBound] == " "
            }
        }
    }

    /// Whether a program of this name runs, as any word of a command line, so through an
    /// interpreter too; nil when the process list couldn't be read.
    func isRunning(program: String) -> Bool? {
        let program = program.lowercased()
        return commandLines.map { lines in
            lines.contains { line in
                line.split(separator: " ").contains { word in (word.split(separator: "/").last ?? word) == program }
            }
        }
    }

    /// Whether a process has a file open in `url`, or `url` itself; nil when open files couldn't
    /// be listed.
    func isOpen(_ url: URL) -> Bool? {
        let path = url.standardizedFileURL.path.lowercased()
        guard let openFiles else { return nil }
        // The path itself, then anything inside it, which sorts together after "path/".
        for target in [path, path + "/"] {
            let index = Self.firstIndex(notBelow: target, in: openFiles)
            if index < openFiles.count, target == path ? openFiles[index] == path : openFiles[index].hasPrefix(target) {
                return true
            }
        }
        return false
    }

    /// Where `value` is, or would go, in sorted `values`.
    private static func firstIndex(notBelow value: String, in values: [String]) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func words(_ line: String) -> Set<Substring> {
        Set(line.split { !$0.isLetter && !$0.isNumber })
    }

    /// Reads the process list and this user's open files.
    @concurrent
    static func read() async -> ActivitySnapshot {
        async let processes = try? Command.run("/bin/ps", ["-axww", "-o", "args="], timeout: .seconds(10))
        async let listing = try? Command.run(
            "/usr/sbin/lsof", ["-nP", "-w", "-Fn", "-u", String(getuid())], timeout: .seconds(20))
        let lines = await processes.flatMap { $0.status == 0 ? $0.stdout.split(separator: "\n").map(String.init) : nil }
        let files = await listing
        // lsof exits with 1 after warnings too, so a listing counts when it printed files.
        let openFiles = files.flatMap { output -> [String]? in
            let names = output.stdout.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
            return names.isEmpty ? nil : names
        }
        return ActivitySnapshot(commandLines: lines, bundleIDs: bundleIDs(in: lines ?? []), openFiles: openFiles)
    }

    /// The IDs of every app bundle the command lines run from, inner helpers and outer apps alike.
    static func bundleIDs(in commandLines: [String]) -> Set<String> {
        var paths: Set<String> = []
        for line in commandLines where line.hasPrefix("/") {
            var searchStart = line.startIndex
            while let range = line.range(of: ".app/", range: searchStart..<line.endIndex) {
                paths.insert(String(line[..<range.upperBound].dropLast()))
                searchStart = range.upperBound
            }
        }
        return Set(paths.compactMap(AppBundle.identifier(atPath:)))
    }
}
