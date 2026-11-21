import AppKit
import ApplicationServices
import os

/// Who has the keyboard, as Accessibility tells it. This can be another app than the one in
/// front: panels such as Spotlight's take the keyboard without coming forward.
nonisolated enum KeyboardFocus {
    /// The app with the keyboard. It can take as long as Accessibility gives an app that has
    /// hung, so it's best asked off the main thread.
    static func appPID() -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(unsafeDowncast(value, to: AXUIElement.self), &pid) == .success else { return nil }
        return pid
    }

    /// `appPID()` asked on a queue of its own, or nil when no answer comes within `limit`.
    /// One question is asked at a time: while an app that has hung keeps one waiting, the
    /// others get nil at once rather than piling up behind it.
    static func appPID(within limit: Duration) async -> pid_t? {
        let isFree = isAsking.withLock { isAsking in
            defer { isAsking = true }
            return !isAsking
        }
        guard isFree else { return nil }
        let isAnswered = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<pid_t?, Never>) in
            let answer: @Sendable (pid_t?) -> Void = { pid in
                let isFirst = isAnswered.withLock { isAnswered in
                    defer { isAnswered = true }
                    return !isAnswered
                }
                if isFirst { continuation.resume(returning: pid) }
            }
            let timer = Task {
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                answer(nil)
            }
            // Not on Swift's own threads, which a call waiting on a hung app would hold up.
            queue.async {
                let pid = appPID()
                isAsking.withLock { $0 = false }
                timer.cancel()
                answer(pid)
            }
        }
    }

    private static let queue = DispatchQueue(label: "PowerToys keyboard focus")
    private static let isAsking = OSAllocatedUnfairLock(initialState: false)
}
