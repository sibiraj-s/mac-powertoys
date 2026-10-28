import AppKit

enum Relaunch {
    /// Quits and opens the app again, as some permissions only count from the next launch.
    static func now() {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // Waits for this process to end, so the new one isn't refused as a second copy.
        process.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try process.run()
        } catch {
            NSLog("Relaunch failed: \(error)")
            return
        }
        NSApp.terminate(nil)
    }
}
