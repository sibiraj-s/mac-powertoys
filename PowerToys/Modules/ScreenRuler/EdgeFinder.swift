import CoreGraphics

/// A screenshot's pixels, read once so edges can be found as the pointer moves.
nonisolated struct PixelGrid: Sendable {
    let width: Int
    let height: Int
    /// Row by row from the top left, each pixel's red, green, blue and alpha bytes.
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "Four bytes per pixel")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// The image redrawn as 8-bit RGBA, whatever format it came in.
    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, bytes: bytes)
    }

    func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// Whether two pixels differ by more than `tolerance` in any of red, green or blue.
    func differs(x: Int, y: Int, fromX: Int, fromY: Int, tolerance: Int) -> Bool {
        let a = (y * width + x) * 4
        let b = (fromY * width + fromX) * 4
        for channel in 0..<3 where abs(Int(bytes[a + channel]) - Int(bytes[b + channel])) > tolerance {
            return true
        }
        return false
    }
}

/// The run of pixels around a point that match it, up to the first edge in each direction.
nonisolated enum EdgeFinder {
    /// Inclusive pixel bounds of the matching run on the point's row and column.
    struct Extent: Equatable {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    /// Walks out from the pixel at `x`, `y` until a pixel differs from it by more than
    /// `tolerance`, or the screen ends. nil when the point is off the grid.
    static func extent(aroundX x: Int, y: Int, in grid: PixelGrid, tolerance: Int) -> Extent? {
        guard grid.contains(x: x, y: y) else { return nil }
        func walk(_ dx: Int, _ dy: Int) -> Int {
            var cx = x
            var cy = y
            while grid.contains(x: cx + dx, y: cy + dy),
                !grid.differs(x: cx + dx, y: cy + dy, fromX: x, fromY: y, tolerance: tolerance)
            {
                cx += dx
                cy += dy
            }
            return dx == 0 ? cy : cx
        }
        return Extent(minX: walk(-1, 0), maxX: walk(1, 0), minY: walk(0, -1), maxY: walk(0, 1))
    }
}

/// What a measurement is shown and copied in.
nonisolated enum RulerUnit: String, CaseIterable, Identifiable, Sendable {
    /// Points, as AppKit, SwiftUI and CSS lay things out.
    case points
    /// The display's own pixels, twice the points on a Retina display.
    case pixels

    var id: Self { self }

    var title: String {
        switch self {
        case .points: "Points"
        case .pixels: "Pixels"
        }
    }
}

/// A width and height measured on screen.
nonisolated struct RulerMeasurement: Equatable, Sendable {
    enum Kind: Sendable {
        /// The space between the edges around a point.
        case spacing
        /// An area dragged over.
        case bounds
    }

    let kind: Kind
    let widthPixels: Int
    let heightPixels: Int
    /// Pixels per point on the display measured.
    let scale: CGFloat

    func width(in unit: RulerUnit) -> CGFloat { unit == .pixels ? CGFloat(widthPixels) : CGFloat(widthPixels) / scale }
    func height(in unit: RulerUnit) -> CGFloat { unit == .pixels ? CGFloat(heightPixels) : CGFloat(heightPixels) / scale }

    /// Such as "120 × 48", with a decimal only for half points.
    func text(in unit: RulerUnit) -> String {
        "\(Self.format(width(in: unit))) × \(Self.format(height(in: unit)))"
    }

    static func format(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
