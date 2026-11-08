import Foundation

/// What's selected in Finder and which folder it's showing; a protocol so tests don't script Finder.
protocol FinderAccess: Sendable {
    /// The selected files and folders in the front Finder window, or on the desktop.
    func selection() async throws -> [URL]
    /// The folder of the front Finder window, or the desktop when no window is open.
    func currentFolder() async throws -> URL
}

/// Asks Finder through osascript, off the main thread and with a time limit, so a busy Finder
/// can't stall the app. macOS asks once whether PowerToys may control Finder.
nonisolated struct LiveFinder: FinderAccess {
    func selection() async throws -> [URL] {
        let script = """
            tell application "Finder"
                set out to ""
                repeat with x in (get selection as alias list)
                    set out to out & POSIX path of x & linefeed
                end repeat
                return out
            end tell
            """
        return Self.paths(try await Self.run(script))
    }

    func currentFolder() async throws -> URL {
        let script = "tell application \"Finder\" to return POSIX path of (insertion location as alias)"
        guard let folder = Self.paths(try await Self.run(script)).first else {
            throw CommandError(errorDescription: "Finder didn't say which folder it's showing.")
        }
        return folder
    }

    /// One path per line; folders end in "/", which makes them directory URLs.
    static func paths(_ output: String) -> [URL] {
        output.split(separator: "\n").map { URL(filePath: String($0)) }
    }

    private static func run(_ script: String) async throws -> String {
        let output = try await Command.run("/usr/bin/osascript", ["-e", script], timeout: .seconds(10))
        guard output.status == 0 else { throw error(from: output.stderr) }
        return output.stdout
    }

    static func error(from stderr: String) -> CommandError {
        // -1743: not allowed to control Finder; -1744 is the same, asked from a background state.
        if stderr.contains("-1743") || stderr.contains("-1744") {
            return CommandError(errorDescription: "Allow PowerToys to control Finder in Privacy & Security → Automation.")
        }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandError(errorDescription: message.isEmpty ? "Finder didn't answer." : "Finder: \(message)")
    }
}
