import Foundation

/// The apps macOS keeps on record, through `lsregister`. Every copy of an app Xcode builds goes
/// on record, and stays there after it's deleted: System Settings goes on listing it, with its
/// extensions, until it's taken off by its path.
nonisolated struct AppRegistry: Sendable {
    static let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// The `path:` lines of `lsregister -dump`, or nil when it couldn't be read; tests give a fake.
    var listPaths: @Sendable () async -> String?
    /// Takes paths off the record; tests give a fake.
    var takeOff: @Sendable (_ paths: [String]) async -> Void

    /// Leaves the record as it is, for tests that don't look at it.
    static let none = AppRegistry(listPaths: { nil }, takeOff: { _ in })

    static let live = AppRegistry(
        listPaths: {
            // The whole record runs to tens of megabytes; only the paths are wanted. A record cut
            // short by lsregister failing isn't taken for the whole of it.
            let output = try? await Command.run(
                "/bin/zsh", ["-fc", "set -o pipefail; '\(tool)' -dump | /usr/bin/grep '^path:'"], timeout: .seconds(60))
            return output.flatMap { $0.status == 0 ? $0.stdout : nil }
        },
        takeOff: { paths in
            _ = try? await Command.run(tool, ["-u"] + paths, timeout: .seconds(60))
        })

    /// Takes everything on record inside these folders off it: apps, their extensions and the
    /// apps inside them, each of which is on record by itself. Returns the paths taken off.
    @discardableResult
    func unregister(inside folders: [URL]) async -> [String] {
        guard !folders.isEmpty, let listed = await listPaths() else { return [] }
        let paths = Self.paths(in: listed, inside: folders.map(\.standardizedFileURL.path))
        // A few at a time, so no one call has an overly long list of arguments.
        for start in stride(from: 0, to: paths.count, by: 50) {
            await takeOff(Array(paths[start..<min(start + 50, paths.count)]))
        }
        return paths
    }

    /// The paths on record inside `folders`, from `lsregister -dump`, where each is on a line
    /// of its own: `path:`, spaces, the path, and the record's number in brackets.
    static func paths(in dump: String, inside folders: [String]) -> [String] {
        let folders = folders.map(plain)
        var found: Set<String> = []
        for line in dump.split(separator: "\n") where line.hasPrefix("path:") {
            var path = line.dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
            if let number = path.range(of: #" \(0x[0-9a-fA-F]+\)$"#, options: .regularExpression) {
                path.removeSubrange(number)
            }
            let plainPath = plain(path)
            if folders.contains(where: { plainPath == $0 || plainPath.hasPrefix($0 + "/") }) { found.insert(path) }
        }
        return found.sorted()
    }

    /// A path without the `/private` that /tmp and /var are links into, which a path can be on
    /// record with or without.
    private static func plain(_ path: String) -> String {
        for linked in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(linked) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
}
