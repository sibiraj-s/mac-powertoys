import AppKit
import SwiftUI

extension NSPanel {
    /// A see-through panel for Lanes to draw over windows with: clicks go through it, it never
    /// takes the keys, and it shows on every Space, over full-screen apps too. Its frame is set
    /// from outside; `content` only fills it.
    static func laneOverlay(level: NSWindow.Level, hasShadow: Bool, content: some View) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = hasShadow
        panel.level = level
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}
