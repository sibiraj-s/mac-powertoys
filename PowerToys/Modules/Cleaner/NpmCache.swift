import Foundation

/// The npm command, where a Node install put it, for letting npm empty its own cache.
nonisolated struct NpmCLI: Sendable {
    let path: String
    /// Runs npm with the arguments; tests give a fake.
    var run: @Sendable (_ arguments: [String], _ timeout: Duration) async throws -> Command.Output

    init(path: String, run: (@Sendable ([String], Duration) async throws -> Command.Output)? = nil) {
        self.path = path
        // npm is a node script, and apps don't get the shell's PATH, so the folder it's in, where
        // node is too, comes first.
        let folder = URL(filePath: path).deletingLastPathComponent().path
        let environment = [
            "PATH": "\(folder):/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
        ]
        self.run = run ?? { try await Command.run(path, $0, environment: environment, timeout: $1) }
    }

    /// Where Homebrew, Volta, nvm, mise and fnm put npm, newest Node first, keeping only one with
    /// node beside it.
    static func candidates(home: URL, files: FileManager = .default) -> [String] {
        var paths = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", home.appending(path: ".volta/bin/npm").path]
        let versioned = [
            (".nvm/versions/node", "bin/npm"), (".local/share/mise/installs/node", "bin/npm"),
            (".local/share/fnm/node-versions", "installation/bin/npm"),
        ]
        for (root, inner) in versioned {
            let folder = home.appending(path: root)
            let versions = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
            paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { folder.appending(path: "\($0)/\(inner)").path }
        }
        return paths
    }

    static func find(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> NpmCLI? {
        candidates(home: home).first { path in
            isExecutable(path) && isExecutable(URL(filePath: path).deletingLastPathComponent().appending(path: "node").path)
        }.map { NpmCLI(path: $0) }
    }
}
