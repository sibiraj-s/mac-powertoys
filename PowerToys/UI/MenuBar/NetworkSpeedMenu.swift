import AppKit
import Observation
import SwiftUI

/// The Mac's network speed as a menu bar item of its own, beside the app's icon, with the
/// busiest apps in a popover. AppKit rather than a MenuBarExtra: one that's off still keeps a
/// hidden item in the app's scenes, and the item exists here only while it's shown.
@MainActor
final class NetworkSpeedItem: NSObject, NSPopoverDelegate {
    private let state: AppState
    private var item: NSStatusItem?
    /// What the item's image shows, so an idle network doesn't redraw it every second.
    private var shown: (download: Double, upload: Double)?
    private let popover = NSPopover()

    init(state: AppState) {
        self.state = state
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    func start() {
        follow()
    }

    /// Updates the item now and again whenever what it shows changes.
    private func follow() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            // Called before the change lands, so the update waits a turn.
            Task { @MainActor in self?.follow() }
        }
    }

    private func update() {
        guard state.showsNetworkSpeed else {
            popover.performClose(nil)
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shown = nil
            return
        }
        let speed = state.networkSpeed
        let item = item ?? makeItem()
        let now = (download: speed.download, upload: speed.upload)
        if let shown, shown == now { return }
        shown = now
        item.button?.image = NetworkSpeedImage.make(download: now.download, upload: now.upload)
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        self.item = item
        return item
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // Made each time, so the panel's sampling stops once it closes.
        let panel = NetworkSpeedPanel { [weak self] in
            self?.popover.performClose(nil)
            MainWindow.show(.module(.network), open: MainWindow.open)
        }
        popover.contentViewController = NSHostingController(rootView: panel.environment(state))
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}

/// What opens from the speed item: the speed now, and the apps using the network most.
struct NetworkSpeedPanel: View {
    static let limit = 6

    let openSettings: () -> Void

    @Environment(AppState.self) private var state

    var body: some View {
        let speed = state.networkSpeed
        let bandwidth = state.bandwidth

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                SpeedFigure(symbol: "arrow.down", title: "Download", value: NetworkSpeedMonitor.compact(speed.download))
                SpeedFigure(symbol: "arrow.up", title: "Upload", value: NetworkSpeedMonitor.compact(speed.upload))
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Using the network")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if !bandwidth.isLoaded {
                    Text("Measuring…").font(.caption).foregroundStyle(.secondary)
                } else if bandwidth.usage.isEmpty {
                    Text("Nothing right now").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(bandwidth.usage.prefix(Self.limit)) { usage in
                    HStack(spacing: 8) {
                        ProcessIcon(pid: usage.pid, size: 16)
                        Text(usage.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        RateText(symbol: "arrow.down", rate: usage.download, width: 84)
                        RateText(symbol: "arrow.up", rate: usage.upload, width: 84)
                    }
                    .frame(minHeight: 22)
                }
            }

            Divider()

            Button(action: openSettings) {
                Text("Network Settings…").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 2)
        }
        .padding(14)
        .frame(width: 340)
        // nettop runs only while this is open.
        .task { await bandwidth.watch() }
    }
}

private struct SpeedFigure: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rate in a column of fixed width: the arrow at its left edge and the number right-aligned,
/// so both line up from row to row.
struct RateText: View {
    let symbol: String
    let rate: Double
    let width: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.secondaryText)
            Spacer(minLength: 0)
            Text(NetworkSpeedMonitor.detailed(rate))
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(rate < 1 ? Palette.secondaryText : Color.primary)
        }
        .frame(width: width)
    }
}
