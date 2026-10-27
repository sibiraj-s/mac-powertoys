import Foundation
import Synchronization

/// Runs a command-line tool off the main thread.
nonisolated enum Command {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    struct TimedOut: LocalizedError {
        var errorDescription: String? { "It took too long to respond." }
    }

    /// Output goes to temporary files rather than pipes, so a background process the command
    /// leaves behind (an interactive shell's agents, say) can't keep us waiting for the end of it.
    /// The command runs in its own process group. After `timeout`, or if the task is cancelled,
    /// the whole group is killed, including anything the command started, and this throws
    /// `TimedOut` or `CancellationError`.
    @concurrent
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration? = nil
    ) async throws -> Output {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appending(path: "PowerToys-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let outURL = directory.appending(path: "out")
        let errURL = directory.appending(path: "err")

        let group = ProcessGroup()
        let watchdog = timeout.map { timeout in
            Task {
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                group.kill(timedOut: true)
            }
        }
        defer { watchdog?.cancel() }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pid: pid_t
                do {
                    pid = try spawn(executable, arguments, environment: environment ?? ProcessInfo.processInfo.environment,
                                    stdout: outURL.path, stderr: errURL.path)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                group.started(pid)
                DispatchQueue.global().async {
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                    continuation.resume(returning: status)
                }
            }
        } onCancel: {
            group.kill(timedOut: false)
        }

        if group.wasTimedOut { throw TimedOut() }
        if group.wasKilled { throw CancellationError() }
        return Output(
            status: exitCode(status),
            stdout: String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self),
            stderr: String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        )
    }

    /// The exit code, or 128 plus the signal for a process that was killed, as shells report it.
    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    private static func spawn(
        _ executable: String, _ arguments: [String], environment: [String: String], stdout: String, stderr: String
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, stdout, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, stderr, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so it can be killed with its children; no other open files.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }

    /// Runs a shell command as root, after macOS asks for an administrator password with `prompt`.
    /// Throws `CancellationError` when the password prompt is cancelled.
    static func runAsAdministrator(_ shellCommand: String, prompt: String) async throws {
        let script = "do shell script \(appleScriptString(shellCommand)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        let output = try await run("/usr/bin/osascript", ["-e", script])
        guard output.status != 0 else { return }
        // -128: the user cancelled.
        if output.stderr.contains("(-128)") { throw CancellationError() }
        throw CommandError(errorDescription: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `text` as one argument for /bin/sh.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }

    /// `text` as an AppleScript string literal.
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }
}

struct CommandError: LocalizedError {
    let errorDescription: String?
}

/// A running command's process group, which a timeout or cancellation can kill at any moment,
/// even before the command has started.
private nonisolated final class ProcessGroup: Sendable {
    private let state = Mutex<(pid: pid_t, killed: Bool, timedOut: Bool)>((0, false, false))

    var wasKilled: Bool { state.withLock { $0.killed } }
    var wasTimedOut: Bool { state.withLock { $0.timedOut } }

    func started(_ pid: pid_t) {
        let killed = state.withLock { state in
            state.pid = pid
            return state.killed
        }
        if killed { Darwin.kill(-pid, SIGKILL) }
    }

    func kill(timedOut: Bool) {
        let pid = state.withLock { state in
            guard !state.killed else { return pid_t(0) }
            state.killed = true
            state.timedOut = timedOut
            return state.pid
        }
        // Interactive shells ignore SIGTERM.
        if pid > 0 { Darwin.kill(-pid, SIGKILL) }
    }
}
