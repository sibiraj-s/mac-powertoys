import Darwin
import Foundation

/// A process with a file, folder or disk open.
nonisolated struct FileHolder: Identifiable, Hashable, Sendable {
    let pid: pid_t
    /// The process's name as lsof gives it, cut to a few characters.
    let command: String
    var files: [OpenFile]
    /// The executable's path, for its full name.
    var path: String?

    var id: pid_t { pid }

    var name: String {
        path.map { URL(filePath: $0).lastPathComponent } ?? command
    }

    struct OpenFile: Hashable, Sendable {
        /// lsof's file descriptor field: a number, or "cwd", "txt" and the like.
        let descriptor: String
        let path: String

        /// How the process is using it, in words.
        var use: String {
            switch descriptor {
            case "cwd": "working folder"
            case "txt": "running code"
            case "rtd": "root folder"
            default: "open"
            }
        }
    }

    /// "Working folder ~/Projects/app · 3 more", for a row.
    var summary: String {
        guard let first = files.first else { return "" }
        let shown = "\(first.use.prefix(1).uppercased())\(first.use.dropFirst()) \(ProcessDetails.abbreviatingHome(first.path))"
        return files.count > 1 ? "\(shown) · \(files.count - 1) more" : shown
    }

    /// Holders from `lsof -F pcfn` output, one per process in lsof's order, leaving out `excluded`.
    static func parse(lsof output: String, excluding excluded: pid_t = getpid()) -> [FileHolder] {
        var holders: [FileHolder] = []
        /// The holder the lines belong to; nil while skipping the excluded process.
        var current: Int?
        var descriptor = ""
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                descriptor = ""
                guard let pid = pid_t(value), pid != excluded else {
                    current = nil
                    continue
                }
                holders.append(FileHolder(pid: pid, command: "", files: []))
                current = holders.indices.last
            case "c":
                guard let current else { continue }
                holders[current] = FileHolder(pid: holders[current].pid, command: value, files: holders[current].files)
            case "f":
                descriptor = value
            case "n":
                guard let current else { continue }
                // The same file open twice is listed once.
                if !holders[current].files.contains(where: { $0.path == value }) {
                    holders[current].files.append(OpenFile(descriptor: descriptor, path: value))
                }
            default:
                continue
            }
        }
        return holders.filter { !$0.files.isEmpty }
    }

    /// lsof's arguments for what has `url` open. Given a disk's mount point, lsof lists the
    /// whole disk; +D looks through everything inside a folder.
    static func lsofArguments(for url: URL, isFolder: Bool, isVolume: Bool) -> [String] {
        let path = url.path(percentEncoded: false)
        let base = ["-nPw", "-F", "pcfn"]
        return isFolder && !isVolume ? base + ["+D", path] : base + ["--", path]
    }
}
