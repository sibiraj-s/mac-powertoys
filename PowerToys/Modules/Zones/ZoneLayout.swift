import CoreGraphics

/// A set of zones as fractions of a display's usable area, origin at the top left.
nonisolated struct ZoneLayout: Identifiable, Hashable {
    let id: String
    let name: String
    /// Ordered left to right, then top to bottom; "next zone" follows this order.
    let zones: [CGRect]

    /// Each zone in `area`, rounded to whole points.
    func frames(in area: CGRect) -> [CGRect] {
        zones.map { zone in
            CGRect(
                x: area.minX + zone.minX * area.width,
                y: area.minY + zone.minY * area.height,
                width: zone.width * area.width,
                height: zone.height * area.height
            ).integral
        }
    }
}

nonisolated extension ZoneLayout {
    static let halves = ZoneLayout(id: "halves", name: "Halves", zones: [
        CGRect(x: 0, y: 0, width: 0.5, height: 1),
        CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
    ])

    static let thirds = ZoneLayout(id: "thirds", name: "Thirds", zones: [
        CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1),
        CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1),
        CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1),
    ])

    static let focus = ZoneLayout(id: "focus", name: "Focus · 20 / 60 / 20", zones: [
        CGRect(x: 0, y: 0, width: 0.2, height: 1),
        CGRect(x: 0.2, y: 0, width: 0.6, height: 1),
        CGRect(x: 0.8, y: 0, width: 0.2, height: 1),
    ])

    static let grid = ZoneLayout(id: "grid", name: "Grid 2 × 2", zones: [
        CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
        CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
        CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
        CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
    ])

    static let all: [ZoneLayout] = [.halves, .thirds, .focus, .grid]
    static let defaultLayout = ZoneLayout.halves

    static func layout(id: String) -> ZoneLayout? {
        all.first { $0.id == id }
    }
}

/// Geometry for picking zones. Everything is in one coordinate space with y growing downward.
nonisolated enum ZoneMath {
    /// How far a window's edges may be from a zone and still count as snapped to it. Apps round
    /// sizes to their own increments (Terminal to character cells, for example).
    static let tolerance: CGFloat = 12

    /// The zone the window currently fills, if any.
    static func snappedIndex(of frame: CGRect, in zones: [CGRect]) -> Int? {
        zones.firstIndex { zone in
            abs(zone.minX - frame.minX) <= tolerance && abs(zone.minY - frame.minY) <= tolerance
                && abs(zone.maxX - frame.maxX) <= tolerance && abs(zone.maxY - frame.maxY) <= tolerance
        }
    }

    /// The zone to move to for "next" (`step` 1) or "previous" (`step` -1). A snapped window steps
    /// along the order and wraps; any other window goes to the zone under its center, or else to
    /// the first or last zone.
    static func target(from frame: CGRect, in zones: [CGRect], step: Int) -> Int? {
        guard !zones.isEmpty else { return nil }
        if let current = snappedIndex(of: frame, in: zones) {
            return (current + step + zones.count) % zones.count
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let containing = index(at: center, in: zones) {
            return containing
        }
        return step > 0 ? 0 : zones.count - 1
    }

    static func index(at point: CGPoint, in zones: [CGRect]) -> Int? {
        zones.firstIndex { $0.contains(point) }
    }

    /// The smallest rectangle covering both zones, for spanning.
    static func span(_ a: CGRect, _ b: CGRect) -> CGRect {
        a.union(b)
    }

    /// `frame` moved from one area to another, keeping its relative position and size.
    static func move(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        let scaleX = destination.width / source.width
        let scaleY = destination.height / source.height
        var moved = CGRect(
            x: destination.minX + (frame.minX - source.minX) * scaleX,
            y: destination.minY + (frame.minY - source.minY) * scaleY,
            width: frame.width * scaleX,
            height: frame.height * scaleY
        ).integral
        // Keep it on the destination even if it hung off the source.
        moved.size.width = min(moved.width, destination.width)
        moved.size.height = min(moved.height, destination.height)
        moved.origin.x = min(max(moved.minX, destination.minX), destination.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, destination.minY), destination.maxY - moved.height)
        return moved
    }
}
