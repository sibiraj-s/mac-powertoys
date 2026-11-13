import AppKit
import Observation
import SwiftUI

/// What the overview panel shows: the picture of the row, and a picture of each window in it.
@Observable
private final class LaneOverviewModel {
    var overview: LaneOverview?
    var animates = false
    /// By window in the row.
    var images: [Int: CGImage] = [:]
    var pids: [Int: pid_t] = [:]
    /// Apps without an icon are remembered too, so they aren't asked again on every redraw.
    @ObservationIgnored private var icons: [pid_t: NSImage?] = [:]

    func icon(of id: Int) -> NSImage? {
        guard let pid = pids[id] else { return nil }
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }
}

/// The overview in a panel over the display being scrolled. Clicks go through it, and it never
/// takes the keys. Each time it appears it takes fresh pictures of the row's windows, keeping
/// the last ones meanwhile; without Screen Recording it shows each window's app icon instead.
final class LaneOverviewPanel: LaneOverviewPresenting {
    private let model = LaneOverviewModel()
    private let previewer: any WindowPreviewing
    private var panel: NSPanel?
    private var isShowing = false
    /// Counts showings, so a fade-out that ends after the panel came back leaves it up.
    private var showing = 0
    /// The windows pictures were asked for since the panel last appeared.
    private var asked: Set<Int> = []
    private var captures: [Task<Void, Never>] = []

    /// Big enough for a tile on a large display, on a Retina screen.
    private static let maxPixels = CGSize(width: 480, height: 320)
    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(previewer: any WindowPreviewing = LiveWindowPreviewer()) {
        self.previewer = previewer
    }

    func show(_ overview: LaneOverview, at frame: CGRect, windows: [LaneOverview.Window], animated: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        // This comes with every bit of a swipe, on the thread moving the windows: only what changed is touched.
        if model.animates != animated { model.animates = animated }
        if model.overview != overview { model.overview = overview }
        let pids = Dictionary(windows.map { ($0.id, $0.pid) }) { first, _ in first }
        if model.pids != pids { model.pids = pids }
        let frame = Displays.flip(frame)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !isShowing {
            isShowing = true
            showing += 1
            asked = []
            model.images = model.images.filter { pids[$0.key] != nil }
            appear(panel)
        }
        // Windows that joined the row while it's up are pictured too.
        capture(windows.filter { !asked.contains($0.id) })
    }

    private func appear(_ panel: NSPanel) {
        let fades = !Self.reducesMotion
        panel.alphaValue = fades ? 0 : 1
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
        for capture in captures { capture.cancel() }
        captures = []
        guard !Self.reducesMotion else {
            panel.orderOut(nil)
            return
        }
        let fading = showing
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.showing == fading else { return }
                panel.orderOut(nil)
            }
        }
    }

    /// Takes a picture of each window, in the background, handing each over as it comes.
    private func capture(_ windows: [LaneOverview.Window]) {
        guard !windows.isEmpty else { return }
        asked.formUnion(windows.map(\.id))
        guard CGPreflightScreenCaptureAccess() else { return }
        let byNumber = Dictionary(windows.compactMap { window in window.number.map { ($0, window.id) } }) { first, _ in first }
        guard !byNumber.isEmpty else { return }
        let current = showing
        captures.append(
            Task { [weak self, previewer] in
                await previewer.capture(Array(byNumber.keys), maxPixels: Self.maxPixels) { number, image in
                    guard let self, self.isShowing, self.showing == current, let id = byNumber[number] else { return }
                    self.model.images[id] = image
                }
            })
    }

    private func makePanel() -> NSPanel {
        // The panel's frame is set from the row.
        .laneOverlay(level: .statusBar, hasShadow: true, content: LaneOverviewView(model: model))
    }
}

// MARK: - Views

private struct LaneOverviewView: View {
    let model: LaneOverviewModel
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        if let overview = model.overview {
            let gap: CGFloat = 3
            ZStack(alignment: .topLeading) {
                ForEach(overview.tiles) { tile in
                    let size = CGSize(width: max(tile.frame.width - gap, 1), height: max(tile.frame.height - gap, 1))
                    LaneOverviewTile(
                        size: size, image: model.images[tile.id], icon: model.icon(of: tile.id), isCurrent: tile.id == overview.current
                    )
                    .offset(x: tile.frame.minX + gap / 2, y: tile.frame.minY + gap / 2)
                }
                // What's off screen is dimmed, and what's on it framed.
                OffScreenShade(view: overview.view)
                    .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: overview.view.width, height: overview.view.height)
                    .offset(x: overview.view.minX, y: overview.view.minY)
            }
            .frame(width: overview.size.width, height: overview.size.height, alignment: .topLeading)
            .animation(model.animates && !reducesMotion ? .spring(duration: 0.22, bounce: 0) : nil, value: overview)
            .padding(LaneOverview.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border.opacity(0.6)))
        }
    }
}

/// The whole picture but for the part of the row on screen.
private nonisolated struct OffScreenShade: Shape {
    var view: CGRect

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(view.minX, view.width) }
        set {
            view.origin.x = newValue.first
            view.size.width = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: view, cornerSize: CGSize(width: 4, height: 4))
        return path
    }
}

private struct LaneOverviewTile: View {
    let size: CGSize
    let image: CGImage?
    let icon: NSImage?
    let isCurrent: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        ZStack {
            shape.fill(Color.primary.opacity(0.1))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height, alignment: .top)
            } else if let icon {
                let side = min(min(size.width, size.height) * 0.5, 32)
                Image(nsImage: icon).resizable().frame(width: side, height: side)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(alignment: .bottomLeading) {
            if image != nil, let icon, min(size.width, size.height) > 36 {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14).padding(3)
            }
        }
        .overlay {
            if isCurrent { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
        }
    }
}
