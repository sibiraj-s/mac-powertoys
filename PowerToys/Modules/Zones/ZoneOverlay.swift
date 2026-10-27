import AppKit
import SwiftUI

/// A click-through panel over one display that draws its zones and highlights the drop target.
final class ZoneOverlay {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// `zones` and `highlight` are in Accessibility coordinates.
    func show(on screen: NSScreen, zones: [CGRect], highlight: CGRect?, title: String? = nil) {
        hideTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        let screenFrame = Displays.flip(screen.frame)
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
        panel.contentView = NSHostingView(rootView: ZoneOverlayView(
            zones: zones.map { local($0) }, highlight: highlight.map { local($0) }, title: title
        ))
        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
        panel.orderFrontRegardless()
    }

    /// Shows the zones briefly, for layout changes made with a shortcut.
    func flash(on screen: NSScreen, zones: [CGRect], title: String) {
        show(on: screen, zones: zones, highlight: nil, title: title)
        hideTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct ZoneOverlayView: View {
    let zones: [CGRect]
    let highlight: CGRect?
    let title: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
                zoneShape(zone, fill: Color.black.opacity(0.12), stroke: Color.white.opacity(0.7))
            }
            if let highlight {
                zoneShape(highlight, fill: Color.accentColor.opacity(0.35), stroke: Color.accentColor)
            }
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func zoneShape(_ rect: CGRect, fill: Color, stroke: Color) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(stroke, lineWidth: 2))
            .padding(4)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }
}
