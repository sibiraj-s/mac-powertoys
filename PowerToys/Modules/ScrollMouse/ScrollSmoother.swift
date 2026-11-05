import CoreGraphics

/// Spreads wheel notches over a few frames so scrolling glides instead of jumping a line at a time.
/// Each frame moves a share of what's left, easing out; whole pixels go out and the rest carries
/// over, so the distance scrolled adds up to the distance asked for.
struct ScrollSmoother {
    /// Pixels still to scroll on each axis.
    private(set) var remainingX = 0.0
    private(set) var remainingY = 0.0

    /// The share of what's left that each frame scrolls, at `frameInterval`.
    static let fraction = 0.16
    static let frameInterval = 1.0 / 120

    var isIdle: Bool { remainingX == 0 && remainingY == 0 }

    /// Adds wheel movement in pixels. Turning the wheel the other way drops what was left on that axis.
    mutating func add(pointsX: Double, pointsY: Double) {
        Self.add(pointsX, to: &remainingX)
        Self.add(pointsY, to: &remainingY)
    }

    mutating func stop() {
        remainingX = 0
        remainingY = 0
    }

    /// The whole pixels to scroll this frame.
    mutating func step() -> (x: Int32, y: Int32) {
        (Self.step(&remainingX), Self.step(&remainingY))
    }

    private static func add(_ pixels: Double, to remaining: inout Double) {
        guard pixels != 0 else { return }
        if remaining != 0, (remaining > 0) != (pixels > 0) { remaining = 0 }
        remaining += pixels
    }

    private static func step(_ remaining: inout Double) -> Int32 {
        guard abs(remaining) >= 0.5 else {
            remaining = 0
            return 0
        }
        var move = (remaining * fraction).rounded()
        if move == 0 { move = remaining > 0 ? 1 : -1 }
        if abs(move) > abs(remaining) { move = remaining.rounded() }
        remaining -= move
        return Int32(move)
    }
}
