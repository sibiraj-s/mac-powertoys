import AppKit
import SwiftUI

/// Shows where a window being dragged along its row would come to rest.
protocol LaneDropPresenting: AnyObject {
    /// Shows the place, or moves the one showing there, `frame` in Accessibility coordinates.
    func show(at frame: CGRect)
    func hide()
}

/// A ghost of the dragged window's place in the row: an outline over the windows, which clicks
/// go through and which never takes the keys. It glides from place to place as the drop changes.
final class LaneDropPanel: LaneDropPresenting {
    private var panel: NSPanel?
    private var isShowing = false
    /// The frame last asked for, which the panel may still be gliding to.
    private var target: CGRect?
    /// Counts showings, so a fade-out that ends after the panel came back leaves it up.
    private var showing = 0

    /// How far the ghost sits inside the place, so it reads as a slot and not a window's edge.
    private static let inset: CGFloat = 6
    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(at frame: CGRect) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let frame = Displays.flip(frame.insetBy(dx: Self.inset, dy: Self.inset))
        // The same place comes again with every look while the pointer moves; a glide under
        // way to it is left to finish.
        guard frame != target || !isShowing else { return }
        target = frame
        guard !isShowing else {
            if Self.reducesMotion {
                panel.setFrame(frame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            }
            return
        }
        isShowing = true
        showing += 1
        // Set through the animator, so it takes the place of a glide from the last drag that's
        // still under way, which would otherwise carry on to where that one was going.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(frame, display: false)
        }
        let fades = !Self.reducesMotion
        // Back while it's still fading out, it fades in from there rather than blinking.
        if !panel.isVisible || !fades { panel.alphaValue = fades ? 0 : 1 }
        panel.orderFrontRegardless()
        guard fades else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShowing, let panel else { return }
        isShowing = false
        target = nil
        guard !Self.reducesMotion else {
            panel.orderOut(nil)
            return
        }
        let fading = showing
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.showing == fading else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        // Over the window being dragged, which is at the normal level.
        .laneOverlay(level: .floating, hasShadow: false, content: LaneDropGhost())
    }
}

private struct LaneDropGhost: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        shape.fill(Color.accentColor.opacity(0.14))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
