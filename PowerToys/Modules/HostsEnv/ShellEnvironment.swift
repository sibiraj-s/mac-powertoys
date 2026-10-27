import Foundation

/// Where environment variables are read from: a new login shell, or what apps get from launchd.
nonisolated enum EnvSource: Hashable, Identifiable, Sendable {
    case shell(URL)
    case apps

    var id: Self { self }

    var name: String {
        switch self {
        case .shell(let url): url.lastPathComponent
        case .apps: "Apps"
        }
    }

    static let supportedShells = ["zsh", "bash", "fish"]

    /// The login shell first, then the other supported shells listed in /etc/shells, then apps.
    /// When a shell is listed twice, such as Homebrew's bash beside /bin/bash, the later one is kept
    /// unless it's the login shell.
    static func available(loginShell: URL?, etcShells: String, exists: (String) -> Bool) -> [EnvSource] {
        var byName: [String: URL] = [:]
        for line in etcShells.split(separator: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, !path.hasPrefix("#"), exists(path) else { continue }
            let url = URL(filePath: path)
            if supportedShells.contains(url.lastPathComponent) { byName[url.lastPathComponent] = url }
        }
        if let loginShell, supportedShells.contains(loginShell.lastPathComponent), exists(loginShell.path) {
            byName[loginShell.lastPathComponent] = loginShell
        }
        let loginName = loginShell?.lastPathComponent
        let names = supportedShells.filter { $0 == loginName } + supportedShells.filter { $0 != loginName }
        return names.compactMap { byName[$0].map(EnvSource.shell) } + [.apps]
    }

    static var loginShell: URL? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return URL(filePath: String(cString: shell))
    }
}

/// One folder in PATH and anything worth knowing about it.
nonisolated struct PathEntry: Identifiable, Equatable, Sendable {
    /// Position in PATH, from 1.
    let id: Int
    let path: String
    let exists: Bool
    /// An earlier entry is the same folder, so this one is never searched.
    let isDuplicate: Bool
    /// The file in /etc/paths or /etc/paths.d that adds it, through path_helper.
    let source: String?

    var problem: String? {
        if path.isEmpty { return "An empty entry searches the current folder." }
        if isDuplicate { return "Already earlier in PATH, so this one has no effect." }
        if !exists { return "This folder doesn't exist." }
        return nil
    }

    static func entries(of path: String, sources: [String: String], exists: (String) -> Bool) -> [PathEntry] {
        var seen: Set<String> = []
        return path.split(separator: ":", omittingEmptySubsequences: false).enumerated().map { offset, component in
            let folder = String(component)
            let normalized = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
            let isDuplicate = !seen.insert(normalized).inserted
            return PathEntry(
                id: offset + 1, path: folder, exists: !folder.isEmpty && exists(folder),
                isDuplicate: isDuplicate, source: sources[normalized]
            )
        }
    }

    /// Folders listed in /etc/paths and /etc/paths.d, by folder, with the file that lists each.
    static func systemSources(paths: String?, pathsD: [(name: String, contents: String)]) -> [String: String] {
        var sources: [String: String] = [:]
        let files = [("/etc/paths", paths ?? "")] + pathsD.sorted { $0.name < $1.name }.map { ("/etc/paths.d/\($0.name)", $0.contents) }
        for (file, contents) in files {
            for line in contents.split(separator: "\n") {
                let folder = line.trimmingCharacters(in: .whitespaces)
                if !folder.isEmpty, sources[folder] == nil { sources[folder] = file }
            }
        }
        return sources
    }

    static func liveSystemSources() -> [String: String] {
        let directory = URL(filePath: "/etc/paths.d")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return systemSources(
            paths: try? String(contentsOf: URL(filePath: "/etc/paths"), encoding: .utf8),
            pathsD: names.compactMap { name in
                (try? String(contentsOf: directory.appending(path: name), encoding: .utf8)).map { (name, $0) }
            }
        )
    }
}

nonisolated struct EnvVariable: Identifiable, Equatable, Sendable {
    let name: String
    let value: String

    var id: String { name }

    /// Probably a password or key, so shown hidden.
    var isSecret: Bool {
        let name = name.uppercased()
        return ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL"].contains { name.contains($0) }
            || name.hasSuffix("_KEY")
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
            || (!isSecret && value.localizedCaseInsensitiveContains(query))
    }
}

/// The environment of one source, with PATH split out.
nonisolated struct EnvSnapshot: Equatable, Sendable {
    let variables: [EnvVariable]
    let path: [PathEntry]

    /// The shell's own bookkeeping, which says nothing about your setup.
    static let ignoredNames: Set<String> = ["_", "SHLVL", "PWD", "OLDPWD"]

    init(variables: [String: String], pathSources: [String: String], exists: (String) -> Bool) {
        self.variables = variables
            .filter { !Self.ignoredNames.contains($0.key) }
            .map { EnvVariable(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
        path = PathEntry.entries(of: variables["PATH"] ?? "", sources: pathSources, exists: exists)
    }
}

/// Reads environments; a protocol so tests don't start shells.
protocol EnvironmentProbing: Sendable {
    func variables(for source: EnvSource) async throws -> [String: String]
}

nonisolated struct LiveEnvironmentProbe: EnvironmentProbing {
    static let marker = "__POWERTOYS_ENV__"

    func variables(for source: EnvSource) async throws -> [String: String] {
        switch source {
        case .apps:
            return Self.appEnvironment(ProcessInfo.processInfo.environment)
        case .shell(let url):
            // Interactive as well as login, as in Terminal, so .zshrc and .bashrc are read too.
            // The marker skips anything the startup files print.
            let output = try await Command.run(
                url.path, ["-l", "-i", "-c", "echo \(Self.marker); /usr/bin/env -0"],
                environment: Self.loginEnvironment(shell: url), timeout: .seconds(10)
            )
            guard let variables = Self.parse(output.stdout) else {
                throw CommandError(errorDescription: "\(url.lastPathComponent) didn't start. Check its startup files.")
            }
            return variables
        }
    }

    /// Variables from `env -0` output that follows the marker; nil when the marker never came.
    static func parse(_ output: String) -> [String: String]? {
        guard let range = output.range(of: marker + "\n", options: .backwards) else { return nil }
        var variables: [String: String] = [:]
        for pair in output[range.upperBound...].split(separator: "\0") {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { continue }
            variables[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        return variables
    }

    /// Roughly what Terminal starts a login shell with, rather than this app's environment.
    static func loginEnvironment(shell: URL) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var environment = [
            "HOME": NSHomeDirectory(), "USER": NSUserName(), "LOGNAME": NSUserName(),
            "SHELL": shell.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
            "LANG": current["LANG"] ?? "en_US.UTF-8",
        ]
        for name in ["TMPDIR", "SSH_AUTH_SOCK"] {
            environment[name] = current[name]
        }
        return environment
    }

    /// This app's environment, minus what Xcode and the system add for debugging.
    static func appEnvironment(_ environment: [String: String]) -> [String: String] {
        let debugPrefixes = ["__", "DYLD_", "XPC_", "XCODE", "OS_ACTIVITY", "NSUnbufferedIO", "MallocNanoZone"]
        return environment.filter { name, _ in !debugPrefixes.contains { name.hasPrefix($0) } }
    }
}
