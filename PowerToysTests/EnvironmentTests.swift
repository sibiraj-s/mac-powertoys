import Foundation
import Testing
@testable import PowerToys

struct EnvSourceTests {
    private let etcShells = """
        # List of acceptable shells for chpass(1).
        /bin/bash
        /bin/csh
        /bin/sh
        /bin/zsh
        /opt/homebrew/bin/bash
        /opt/homebrew/bin/fish
        """

    @Test func loginShellComesFirstThenApps() {
        let sources = EnvSource.available(loginShell: URL(filePath: "/opt/homebrew/bin/fish"), etcShells: etcShells, exists: { _ in true })
        #expect(sources == [
            .shell(URL(filePath: "/opt/homebrew/bin/fish")),
            .shell(URL(filePath: "/bin/zsh")),
            .shell(URL(filePath: "/opt/homebrew/bin/bash")),
            .apps,
        ])
    }

    @Test func loginShellWinsOverOtherCopies() {
        let sources = EnvSource.available(loginShell: URL(filePath: "/bin/bash"), etcShells: etcShells, exists: { _ in true })
        #expect(sources.first == .shell(URL(filePath: "/bin/bash")))
        #expect(!sources.contains(.shell(URL(filePath: "/opt/homebrew/bin/bash"))))
    }

    @Test func skipsShellsThatArentInstalled() {
        let sources = EnvSource.available(loginShell: URL(filePath: "/bin/zsh"), etcShells: etcShells, exists: { !$0.hasPrefix("/opt") })
        #expect(sources == [.shell(URL(filePath: "/bin/zsh")), .shell(URL(filePath: "/bin/bash")), .apps])
        #expect(sources.map(\.name) == ["zsh", "bash", "Apps"])
    }
}

struct PathEntryTests {
    @Test func flagsProblems() {
        let entries = PathEntry.entries(
            of: "/opt/homebrew/bin:/usr/bin::/missing:/usr/bin/:/opt/homebrew/bin",
            sources: ["/usr/bin": "/etc/paths"],
            exists: { $0 != "/missing" }
        )
        #expect(entries.map(\.id) == [1, 2, 3, 4, 5, 6])
        #expect(entries[0].problem == nil)
        #expect(entries[1].source == "/etc/paths")
        #expect(entries[2].problem?.contains("current folder") == true)
        #expect(entries[3].problem == "This folder doesn't exist.")
        // A trailing slash is still the same folder.
        #expect(entries[4].isDuplicate)
        #expect(entries[5].isDuplicate)
        #expect(!entries[0].isDuplicate)
    }

    @Test func readsPathHelperFiles() {
        let sources = PathEntry.systemSources(
            paths: "/usr/local/bin\n/usr/bin\n/bin\n",
            pathsD: [("Wireshark", "/Applications/Wireshark.app/Contents/MacOS\n"), ("100-rvictl", "/usr/bin\n/Library/Apple/usr/bin")]
        )
        #expect(sources["/usr/bin"] == "/etc/paths")
        #expect(sources["/Library/Apple/usr/bin"] == "/etc/paths.d/100-rvictl")
        #expect(sources["/Applications/Wireshark.app/Contents/MacOS"] == "/etc/paths.d/Wireshark")
        #expect(PathEntry.systemSources(paths: nil, pathsD: []).isEmpty)
    }
}

struct EnvVariableTests {
    @Test func spotsSecrets() {
        #expect(EnvVariable(name: "GITHUB_TOKEN", value: "x").isSecret)
        #expect(EnvVariable(name: "AWS_SECRET_ACCESS_KEY", value: "x").isSecret)
        #expect(EnvVariable(name: "OPENAI_API_KEY", value: "x").isSecret)
        #expect(EnvVariable(name: "db_password", value: "x").isSecret)
        #expect(!EnvVariable(name: "PATH", value: "x").isSecret)
        #expect(!EnvVariable(name: "SSH_AUTH_SOCK", value: "x").isSecret)
        #expect(!EnvVariable(name: "KEYTIMEOUT", value: "x").isSecret)
    }

    @Test func filtersByNameOrValueButNotSecretValues() {
        #expect(EnvVariable(name: "EDITOR", value: "nvim").matches(""))
        #expect(EnvVariable(name: "EDITOR", value: "nvim").matches("edit"))
        #expect(EnvVariable(name: "EDITOR", value: "nvim").matches("NVIM"))
        #expect(!EnvVariable(name: "API_TOKEN", value: "hunter2").matches("hunter"))
        #expect(EnvVariable(name: "API_TOKEN", value: "hunter2").matches("token"))
    }

    @Test func snapshotsSortAndDropShellBookkeeping() {
        let snapshot = EnvSnapshot(
            variables: ["PATH": "/usr/bin:/bin", "HOME": "/Users/me", "_": "/usr/bin/env", "SHLVL": "2", "PWD": "/"],
            pathSources: [:], exists: { _ in true }
        )
        #expect(snapshot.variables.map(\.name) == ["HOME", "PATH"])
        #expect(snapshot.path.map(\.path) == ["/usr/bin", "/bin"])
    }
}

struct EnvironmentProbeTests {
    @Test func parsesEnvOutputAfterTheMarker() {
        let marker = LiveEnvironmentProbe.marker
        let output = "Welcome!\n\(marker)\nA=1\0MULTI=line one\nline two\0EQ=a=b\0=junk\0"
        #expect(LiveEnvironmentProbe.parse(output) == ["A": "1", "MULTI": "line one\nline two", "EQ": "a=b"])
        #expect(LiveEnvironmentProbe.parse("startup error") == nil)
    }

    @Test func appEnvironmentDropsDebuggerVariables() {
        let env = LiveEnvironmentProbe.appEnvironment(["PATH": "/usr/bin", "DYLD_LIBRARY_PATH": "x", "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "x", "XPC_SERVICE_NAME": "x"])
        #expect(env == ["PATH": "/usr/bin"])
    }

    @Test func loginEnvironmentStartsClean() {
        let env = LiveEnvironmentProbe.loginEnvironment(shell: URL(filePath: "/bin/zsh"))
        #expect(env["SHELL"] == "/bin/zsh")
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["HOME"] == NSHomeDirectory())
        #expect(env["DYLD_LIBRARY_PATH"] == nil)
    }

    @Test func readsARealShell() async throws {
        let variables = try await LiveEnvironmentProbe().variables(for: .shell(URL(filePath: "/bin/sh")))
        #expect(variables["SHELL"] == "/bin/sh")
        #expect(variables["PATH"]?.contains("/usr/bin") == true)
    }
}

final class FakeProbe: EnvironmentProbing, @unchecked Sendable {
    var variables: [EnvSource: [String: String]] = [:]
    private(set) var reads: [EnvSource] = []

    func variables(for source: EnvSource) async throws -> [String: String] {
        reads.append(source)
        guard let variables = variables[source] else { throw CommandError(errorDescription: "No shell") }
        return variables
    }
}

struct EnvironmentControllerTests {
    private let zsh = EnvSource.shell(URL(filePath: "/bin/zsh"))

    @Test func readsEachSourceOnceUnlessAsked() async {
        let probe = FakeProbe()
        probe.variables = [zsh: ["PATH": "/a:/b"], .apps: ["PATH": "/usr/bin"]]
        let controller = EnvironmentController(loginShell: nil, sources: [zsh, .apps], probe: probe, pathSources: { [:] }, exists: { _ in true })
        #expect(controller.selected == zsh)

        await controller.load(zsh)
        await controller.load(zsh)
        #expect(probe.reads == [zsh])
        #expect(controller.snapshot?.path.map(\.path) == ["/a", "/b"])

        await controller.load(zsh, force: true)
        #expect(probe.reads == [zsh, zsh])

        controller.selected = .apps
        #expect(controller.snapshot == nil)
        await controller.load(.apps)
        #expect(controller.snapshot?.path.map(\.path) == ["/usr/bin"])
    }

    @Test func showsErrors() async {
        let probe = FakeProbe()
        let controller = EnvironmentController(loginShell: nil, sources: [zsh], probe: probe, pathSources: { [:] }, exists: { _ in true })
        await controller.load(zsh)
        #expect(controller.error == "No shell")
        #expect(controller.snapshot == nil)
        #expect(!controller.isLoading)
    }
}

struct CommandTests {
    @Test func quoting() {
        #expect(Command.shellQuoted("it's here") == "'it'\\''s here'")
        #expect(Command.appleScriptString(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }

    @Test func runsCommands() async throws {
        let output = try await Command.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(output.status == 3)
        #expect(output.stdout == "out\n")
        #expect(output.stderr == "err\n")
    }

    @Test func killsCommandsThatTakeTooLong() async {
        let started = Date.now
        await #expect(throws: Command.TimedOut.self) {
            try await Command.run("/bin/sleep", ["10"], timeout: .milliseconds(200))
        }
        #expect(Date.now.timeIntervalSince(started) < 5)
    }

    @Test func timeoutsKillWhatTheCommandStarted() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        await #expect(throws: Command.TimedOut.self) {
            try await Command.run("/bin/sh", ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; wait"], timeout: .milliseconds(300))
        }
        let child = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        await waitUntil { kill(child, 0) != 0 }
        #expect(kill(child, 0) != 0)
    }

    @Test func cancellingStopsTheCommand() async {
        let started = Date.now
        let task = Task { try await Command.run("/bin/sleep", ["10"]) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date.now.timeIntervalSince(started) < 5)
    }

    @Test func leftoverBackgroundProcessesDontBlock() async throws {
        let started = Date.now
        let output = try await Command.run("/bin/sh", ["-c", "(sleep 5 &) ; echo done"])
        #expect(output.stdout == "done\n")
        #expect(Date.now.timeIntervalSince(started) < 4)
    }
}
