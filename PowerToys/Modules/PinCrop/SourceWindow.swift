import AppKit

/// Brings a pinned window forward in the pin's place; a protocol so tests don't move windows.
protocol SourceWindowRaising {
    /// Moves the window so the part that's pinned sits at `point`, in top-left global coordinates,
    /// raises it and brings its app forward. False without Accessibility, or when the window is gone.
    func raise(_ selection: WindowSelection, showingAt point: CGPoint) -> Bool
}

struct LiveSourceWindowRaiser: SourceWindowRaising {
    func raise(_ selection: WindowSelection, showingAt point: CGPoint) -> Bool {
        let id = selection.window.id
        guard AXIsProcessTrusted(),
            // Where the window is now: it may have moved since it was pinned.
            let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
            let current = WindowPicking.windows(from: list, ownPID: getpid()).first(where: { $0.id == id }),
            let window = AXWindow.window(of: current.pid, at: current.frame)
        else { return false }
        window.move(to: selection.windowOrigin(showingAt: point))
        window.raise()
        return true
    }
}
