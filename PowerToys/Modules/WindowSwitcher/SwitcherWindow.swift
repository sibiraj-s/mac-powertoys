import AppKit

/// A window the switcher can bring forward.
struct SwitcherWindow: Identifiable {
    enum State {
        case onScreen, minimized, hidden
    }

    /// The window list's number for it, used for its preview; nil for windows that aren't on screen.
    let windowID: CGWindowID?
    let pid: pid_t
    let appName: String
    let title: String
    var state: State
    /// Where it is, in top-left global coordinates, while it's on screen.
    var frame: CGRect?
    let window: AXWindow

    /// The Accessibility element stays the same for as long as the window is open.
    var id: AXUIElement { window.element }
}

/// An app's windows as Accessibility reports them, for matching to the window list.
struct AppWindows {
    struct Entry {
        let window: AXWindow
        let title: String
        let frame: CGRect?
        let isMinimized: Bool
        let isStandard: Bool
    }

    let pid: pid_t
    let appName: String
    let isHidden: Bool
    let windows: [Entry]
}

enum WindowSwitching {
    /// Windows on screen front to back, as the window list orders them, then minimized windows and
    /// those of hidden apps. A listed window only counts when its app has an Accessibility window at
    /// the same place: that's what gets raised, and it leaves out overlays and other non-windows.
    static func windows(onScreen: [PickableWindow], apps: [AppWindows]) -> [SwitcherWindow] {
        var remaining = Dictionary(apps.map { ($0.pid, $0.windows) }, uniquingKeysWith: { first, _ in first })
        var result: [SwitcherWindow] = []

        func append(
            _ entry: AppWindows.Entry, windowID: CGWindowID?, frame: CGRect?, pid: pid_t, appName: String, state: SwitcherWindow.State
        ) {
            result.append(
                SwitcherWindow(
                    windowID: windowID, pid: pid, appName: appName, title: entry.title, state: state, frame: frame,
                    window: entry.window))
        }

        for listed in onScreen {
            guard let candidates = remaining[listed.pid] else { continue }
            let matches = candidates.indices.filter {
                candidates[$0].isStandard && !candidates[$0].isMinimized && candidates[$0].frame?.integral == listed.frame.integral
            }
            // Windows in the same place, as when snapped into the same zone, are told apart by title,
            // which the window list has with Screen Recording.
            guard let index = matches.first(where: { !listed.title.isEmpty && candidates[$0].title == listed.title }) ?? matches.first,
                let entry = remaining[listed.pid]?.remove(at: index)
            else { continue }
            append(entry, windowID: listed.id, frame: listed.frame, pid: listed.pid, appName: listed.appName, state: .onScreen)
        }

        for app in apps {
            for entry in remaining[app.pid] ?? [] where entry.isStandard && (entry.isMinimized || app.isHidden) {
                append(
                    entry, windowID: nil, frame: nil, pid: app.pid, appName: app.appName, state: entry.isMinimized ? .minimized : .hidden)
            }
        }
        return result
    }
}

/// Lists the windows to switch between; a protocol so tests don't read the real ones.
protocol WindowListing {
    func windows() -> [SwitcherWindow]
}

struct LiveWindowLister: WindowListing {
    func windows() -> [SwitcherWindow] {
        guard AXIsProcessTrusted() else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreen = WindowPicking.windows(from: list, ownPID: ownPID).filter { $0.pid != ownPID }
        // Only apps with windows somewhere are asked for them. Windows on other Spaces count here but
        // aren't listed: Accessibility only reports the current Space's.
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let withWindows = Set(
            all.compactMap { info -> pid_t? in
                guard info[kCGWindowLayer as String] as? Int == 0, let pid = info[kCGWindowOwnerPID as String] as? Int else { return nil }
                return pid_t(pid)
            })
        let apps = NSWorkspace.shared.runningApplications
            .filter {
                // Menu bar apps (accessory ones) can have windows too.
                $0.activationPolicy != .prohibited && $0.processIdentifier != ownPID && withWindows.contains($0.processIdentifier)
            }
            .map { app in
                AppWindows(
                    pid: app.processIdentifier, appName: app.localizedName ?? "", isHidden: app.isHidden,
                    windows: AXWindow.windows(of: app.processIdentifier, timeout: 0.5).map {
                        AppWindows.Entry(
                            window: $0, title: $0.title, frame: $0.frame, isMinimized: $0.isMinimized, isStandard: $0.isStandard)
                    })
            }
        return WindowSwitching.windows(onScreen: onScreen, apps: apps)
    }
}

/// How the switcher's tiles fit on a display.
enum SwitcherLayout {
    nonisolated static let tileSize = CGSize(width: 180, height: 150)
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 16
    /// The row of action keys under the windows.
    static let footerHeight: CGFloat = 28

    /// Most cards shown in the stack at once.
    static let stackDepth = 7
    static let titleHeight: CGFloat = 44

    /// The stack: cards one behind another, receding up and to the left, the selected one in front.
    struct Stack: Equatable {
        /// The switcher's size, most of the display.
        let size: CGSize
        /// The front card's size, a 16:10 window.
        let card: CGSize
        /// How far each card sits from the one in front of it.
        let step: CGSize

        /// Where the card `depth` cards back sits, from the center, with `visible` cards showing.
        func offset(depth: Int, visible: Int) -> CGSize {
            let fromMiddle = CGFloat(visible - 1) / 2 - CGFloat(depth)
            return CGSize(width: fromMiddle * step.width, height: fromMiddle * step.height)
        }
    }

    static let cardStep: CGFloat = 0.11

    static func stack(in area: CGSize) -> Stack {
        let size = CGSize(width: area.width * 0.9, height: area.height * 0.9)
        let room = CGSize(width: size.width - 2 * padding, height: size.height - 2 * padding - titleHeight - footerHeight)
        // The front card plus each one behind it shifted by a share of the card's size.
        let spread = 1 + CGFloat(stackDepth - 1) * cardStep
        let width = max(1, min(room.width / spread, room.height / spread / 0.625))
        let card = CGSize(width: width, height: width * 0.625)
        return Stack(size: size, card: card, step: CGSize(width: card.width * cardStep, height: card.height * cardStep))
    }

    /// How far behind the selected card `index` sits: 0 in front, then each next window one further back.
    static func depth(of index: Int, selected: Int, count: Int) -> Int {
        wrapped(index - selected, count: count)
    }

    /// `index` wrapped into 0..<count, either way round.
    static func wrapped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index % count + count) % count
    }

    /// Previews at about twice a grid tile's size, for Retina displays.
    nonisolated static let tilePreviewPixels = CGSize(width: 2 * tileSize.width, height: 2 * tileSize.height)
    /// Large enough for the stack's front card.
    nonisolated static let cardPreviewPixels = CGSize(width: 1400, height: 1000)

    /// Columns for `count` tiles in at most 90% of `area`'s width, and the panel's size with its
    /// keys, at most 85% of its height; past that the tiles scroll.
    static func grid(count: Int, in area: CGSize) -> (columns: Int, size: CGSize) {
        let fit = Int((area.width * 0.9 - 2 * padding + spacing) / (tileSize.width + spacing))
        let columns = max(1, min(count, fit))
        let rows = max(1, (count + columns - 1) / columns)
        let width = CGFloat(columns) * tileSize.width + CGFloat(columns - 1) * spacing + 2 * padding
        let height = CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * spacing + 2 * padding
        return (columns, CGSize(width: width, height: min(height + footerHeight, area.height * 0.85)))
    }
}
