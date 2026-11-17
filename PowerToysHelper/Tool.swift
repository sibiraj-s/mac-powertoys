import Foundation
import Synchronization

/// Runs a tool and waits for it, with `input` on its standard input.
nonisolated enum Tool {
    struct Result {
        let status: Int32
        let output: String
    }

    /// A tool still running after `timeout` seconds is stopped, so a hung one can't hold up the
    /// helper, or the app waiting for its answer.
    static func run(_ path: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval = 20) -> Result {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin } else { process.standardInput = FileHandle.nullDevice }

        // Output is gathered as it comes rather than read to the end, since a child the tool left
        // running can keep the pipe open long after the tool itself is gone.
        let collected = Mutex(Data())
        let readAll = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                readAll.signal()
            } else {
                collected.withLock { $0.append(chunk) }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return Result(status: -1, output: error.localizedDescription)
        }
        if let stdin, let input {
            // Written on the side, so a tool that never reads can't hold this up past the timeout.
            // A tool that exits without reading fails the write (SIGPIPE is ignored), and that's all.
            let writer = stdin.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: Data(input.utf8))
                try? writer.close()
            }
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // SIGKILL, as the helper ignores SIGTERM and its tools inherit that.
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
            timedOut = true
        }
        if readAll.wait(timeout: .now() + 1) == .timedOut { output.fileHandleForReading.readabilityHandler = nil }
        if timedOut {
            return Result(status: -1, output: "\((path as NSString).lastPathComponent) didn't finish in time.")
        }
        return Result(status: process.terminationStatus, output: String(decoding: collected.withLock { $0 }, as: UTF8.self))
    }

    /// nil when it worked, otherwise what it printed.
    static func check(_ path: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval = 20) -> String? {
        let result = run(path, arguments, input: input, timeout: timeout)
        if result.status == -1 { return result.output }
        guard result.status != 0 else { return nil }
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "\((path as NSString).lastPathComponent) failed (\(result.status))." : message
    }
}
