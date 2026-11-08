import AppKit
import Testing

@testable import PowerToys

struct EdgeFinderTests {
    /// A grid of one gray level per pixel, from rows of characters: "." is white, "#" black, "+" near white.
    private func grid(_ rows: [String]) -> PixelGrid {
        var bytes: [UInt8] = []
        for row in rows {
            for character in row {
                let level: UInt8 = character == "#" ? 0 : character == "+" ? 245 : 255
                bytes += [level, level, level, 255]
            }
        }
        return PixelGrid(width: rows[0].count, height: rows.count, bytes: bytes)
    }

    @Test func stopsAtTheFirstEdgeEachWay() throws {
        let grid = grid([
            "#######",
            "#.....#",
            "#.....#",
            "#######",
        ])
        let extent = try #require(EdgeFinder.extent(aroundX: 3, y: 1, in: grid, tolerance: 0))
        #expect(extent == .init(minX: 1, maxX: 5, minY: 1, maxY: 2))
        #expect(extent.width == 5)
        #expect(extent.height == 2)
    }

    @Test func runsToTheScreensEdgeWithoutOne() throws {
        let extent = try #require(EdgeFinder.extent(aroundX: 0, y: 0, in: grid(["...", "..."]), tolerance: 0))
        #expect(extent == .init(minX: 0, maxX: 2, minY: 0, maxY: 1))
    }

    @Test func toleranceIgnoresSmallDifferences() throws {
        let rows = ["..+..#"]
        #expect(try #require(EdgeFinder.extent(aroundX: 0, y: 0, in: grid(rows), tolerance: 0)).maxX == 1)
        #expect(try #require(EdgeFinder.extent(aroundX: 0, y: 0, in: grid(rows), tolerance: 16)).maxX == 4)
    }

    @Test func nothingOffTheGrid() {
        #expect(EdgeFinder.extent(aroundX: 5, y: 0, in: grid(["..."]), tolerance: 0) == nil)
    }

    @Test func readsAnImage() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let image = try #require(context.makeImage())
        let grid = try #require(PixelGrid(image: image))
        #expect(grid.width == 4)
        #expect(grid.height == 2)
        #expect(Array(grid.bytes.prefix(4)) == [255, 0, 0, 255])
    }
}

struct RulerMeasurementTests {
    @Test func pointsHalveRetinaPixels() {
        let measurement = RulerMeasurement(kind: .spacing, widthPixels: 241, heightPixels: 96, scale: 2)
        #expect(measurement.text(in: .pixels) == "241 × 96")
        #expect(measurement.text(in: .points) == "120.5 × 48")
    }
}

@MainActor
struct ScreenRulerControllerTests {
    final class FakePresenter: RulerPresenting {
        var result: RulerMeasurement?
        var asked: [(RulerUnit, Int)] = []
        var cancelCount = 0

        func measure(unit: RulerUnit, tolerance: Int) async -> RulerMeasurement? {
            asked.append((unit, tolerance))
            return result
        }

        func cancel() { cancelCount += 1 }
    }

    final class Access {
        var isGranted = true
        var requests = 0
    }

    let store = TestDefaults()
    let presenter = FakePresenter()
    let pasteboard = NSPasteboard.withUniqueName()
    let access = Access()

    func makeController() -> ScreenRulerController {
        let access = access
        return ScreenRulerController(
            defaults: store.defaults, presenter: presenter, pasteboard: pasteboard,
            access: ScreenAccess(isGranted: { access.isGranted }, request: { access.requests += 1 }, explain: {}))
    }

    @Test func copiesWhatsMeasuredInTheChosenUnit() async throws {
        presenter.result = RulerMeasurement(kind: .bounds, widthPixels: 200, heightPixels: 100, scale: 2)
        let controller = makeController()
        controller.unit = .pixels
        controller.tolerance = 30

        let measured = try #require(await controller.measure())
        #expect(measured == presenter.result)
        #expect(controller.latest == measured)
        #expect(pasteboard.string(forType: .string) == "200 × 100")
        #expect(presenter.asked.map(\.0) == [.pixels])
        #expect(presenter.asked.map(\.1) == [30])
        #expect(!controller.isMeasuring)
    }

    @Test func cancellingCopiesNothing() async {
        pasteboard.clearContents()
        let controller = makeController()
        #expect(await controller.measure() == nil)
        #expect(controller.latest == nil)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func asksForScreenRecordingFirst() async {
        access.isGranted = false
        let controller = makeController()
        #expect(await controller.measure() == nil)
        #expect(access.requests == 1)
        #expect(presenter.asked.isEmpty)
    }

    @Test func remembersSettings() {
        let controller = makeController()
        #expect(controller.unit == .points)
        #expect(controller.tolerance == 16)
        controller.unit = .pixels
        controller.tolerance = 40
        let reopened = makeController()
        #expect(reopened.unit == .pixels)
        #expect(reopened.tolerance == 40)
    }

    @Test func toleranceStaysInRange() {
        let controller = makeController()
        controller.tolerance = 300
        #expect(controller.tolerance == ScreenRulerController.toleranceRange.upperBound)
        controller.tolerance = -5
        #expect(controller.tolerance == 0)
        #expect(makeController().tolerance == 0)
    }

    @Test func turningTheModuleOffClosesTheRuler() {
        let state = AppState.testing(
            defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings(), screenRuler: makeController())
        state.setEnabled(.screenRuler, true)
        state.setEnabled(.screenRuler, false)
        #expect(presenter.cancelCount == 1)
    }
}
