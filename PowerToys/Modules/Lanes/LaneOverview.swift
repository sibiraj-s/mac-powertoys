import CoreGraphics

/// A small picture of a whole row, shown while it's scrolled with a swipe or the wheel: every
/// window drawn to scale where it sits in the row, the part of the row on screen framed, and
/// the window the row is on picked out. Distances are in points from the picture's top left.
nonisolated struct LaneOverview: Equatable {
    /// Where on the display the picture goes.
    enum Position: String, CaseIterable, Identifiable {
        case off, top, middle, bottom

        var id: Self { self }

        var title: String {
            switch self {
            case .off: "Off"
            case .top: "Top"
            case .middle: "Middle"
            case .bottom: "Bottom"
            }
        }
    }

    struct Tile: Equatable, Identifiable {
        let id: Int
        let frame: CGRect
    }

    /// A window in the row: whose it is, for its app's icon, and its number with the window
    /// server, for a picture of it.
    struct Window: Equatable {
        let id: Int
        let pid: pid_t
        let number: CGWindowID?
    }

    let size: CGSize
    let tiles: [Tile]
    /// The part of the row on screen.
    let view: CGRect
    /// The window the row is on.
    let current: Int?

    /// The tallest the picture gets, and how far it keeps from the edges of the display.
    static let maxHeight: CGFloat = 120
    static let margin: CGFloat = 24
    /// Between the picture and the edge of the panel it sits on.
    static let padding: CGFloat = 8

    /// The picture of `lane` on a display whose usable area is `area` big, as large as fits in
    /// `bounds`. A row narrower than the display is drawn on a display-wide picture.
    init(lane: Lane, area: CGSize, current: Int?, fitting bounds: CGSize) {
        let rowWidth = lane.columns.reduce(0) { $0 + $1.width }
        let width = max(rowWidth, area.width, 1)
        let scale = min(bounds.width / width, bounds.height / max(area.height, 1))
        let height = area.height * scale
        var start: CGFloat = 0
        var tiles: [Tile] = []
        for column in lane.columns {
            let rowHeight = height / CGFloat(column.ids.count)
            for (row, id) in column.ids.enumerated() {
                tiles.append(
                    Tile(
                        id: id,
                        frame: CGRect(x: start * scale, y: CGFloat(row) * rowHeight, width: column.width * scale, height: rowHeight)))
            }
            start += column.width
        }
        self.tiles = tiles
        size = CGSize(width: width * scale, height: height)
        view = CGRect(x: lane.offset * scale, y: 0, width: area.width * scale, height: height)
        self.current = current
    }

    /// The room for the picture on a display with usable area `area`.
    static func bounds(in area: CGRect) -> CGSize {
        CGSize(width: max(area.width - 2 * (margin + padding), 1), height: maxHeight)
    }

    /// Where the panel holding a picture of `size` goes on a display with usable area `area`,
    /// in Accessibility coordinates: centered across it, at `position` up or down it.
    static func frame(of size: CGSize, in area: CGRect, at position: Position) -> CGRect {
        let panel = CGSize(width: size.width + 2 * padding, height: size.height + 2 * padding)
        let y: CGFloat =
            switch position {
            case .top, .off: area.minY + margin
            case .middle: area.midY - panel.height / 2
            case .bottom: area.maxY - margin - panel.height
            }
        return CGRect(x: (area.midX - panel.width / 2).rounded(), y: y.rounded(), width: panel.width, height: panel.height)
    }
}

/// Shows a row's overview; a protocol so tests don't put up a panel.
protocol LaneOverviewPresenting: AnyObject {
    /// Shows an overview, or updates the one showing, in a panel at `frame` in Accessibility
    /// coordinates. `windows` are those in the row, to take pictures of. `animated` says the
    /// row jumped, as by the wheel, rather than following a swipe.
    func show(_ overview: LaneOverview, at frame: CGRect, windows: [LaneOverview.Window], animated: Bool)
    func hide()
}
