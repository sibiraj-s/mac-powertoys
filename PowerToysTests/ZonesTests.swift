import CoreGraphics
import Testing
@testable import PowerToys

struct ZoneLayoutTests {
    private let area = CGRect(x: 0, y: 25, width: 1200, height: 800)

    @Test(arguments: ZoneLayout.all)
    func zonesTileTheWholeArea(layout: ZoneLayout) {
        let frames = layout.frames(in: area)
        let covered = frames.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(covered - area.width * area.height) < 4 * area.width, "\(layout.name) leaves gaps or overlaps")
        for frame in frames {
            #expect(area.contains(frame))
        }
    }

    @Test func halvesSplitDownTheMiddle() {
        let frames = ZoneLayout.halves.frames(in: area)
        #expect(frames == [
            CGRect(x: 0, y: 25, width: 600, height: 800),
            CGRect(x: 600, y: 25, width: 600, height: 800),
        ])
    }

    @Test func focusIsTwentySixtyTwenty() {
        let widths = ZoneLayout.focus.frames(in: area).map(\.width)
        #expect(widths == [240, 720, 240])
    }

    @Test func layoutIDsAreUniqueAndLookUp() {
        let ids = ZoneLayout.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for layout in ZoneLayout.all {
            #expect(ZoneLayout.layout(id: layout.id) == layout)
        }
        #expect(ZoneLayout.layout(id: "missing") == nil)
    }
}

struct ZoneMathTests {
    private let thirds = ZoneLayout.thirds.frames(in: CGRect(x: 0, y: 0, width: 1200, height: 800))

    @Test func snappedWindowStepsAndWraps() {
        #expect(ZoneMath.target(from: thirds[0], in: thirds, step: 1) == 1)
        #expect(ZoneMath.target(from: thirds[2], in: thirds, step: 1) == 0)
        #expect(ZoneMath.target(from: thirds[0], in: thirds, step: -1) == 2)
    }

    @Test func nearlySnappedWindowCounts() {
        // Terminal-style rounding leaves a window a few points short of the zone.
        let rounded = thirds[1].insetBy(dx: 3, dy: 5)
        #expect(ZoneMath.snappedIndex(of: rounded, in: thirds) == 1)
        #expect(ZoneMath.target(from: rounded, in: thirds, step: 1) == 2)
    }

    @Test func freeWindowGoesToTheZoneUnderItsCenter() {
        let window = CGRect(x: 450, y: 100, width: 300, height: 300) // center x 600: middle third
        #expect(ZoneMath.snappedIndex(of: window, in: thirds) == nil)
        #expect(ZoneMath.target(from: window, in: thirds, step: 1) == 1)
        #expect(ZoneMath.target(from: window, in: thirds, step: -1) == 1)
    }

    @Test func offscreenWindowGoesToFirstOrLast() {
        let window = CGRect(x: 5000, y: 0, width: 300, height: 300)
        #expect(ZoneMath.target(from: window, in: thirds, step: 1) == 0)
        #expect(ZoneMath.target(from: window, in: thirds, step: -1) == 2)
        #expect(ZoneMath.target(from: window, in: [], step: 1) == nil)
    }

    @Test func spanCoversBothZones() {
        #expect(ZoneMath.span(thirds[0], thirds[1]) == CGRect(x: 0, y: 0, width: 800, height: 800))
    }

    @Test func moveKeepsRelativePlacement() {
        let source = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let destination = CGRect(x: 1000, y: 0, width: 2000, height: 1000)
        let moved = ZoneMath.move(CGRect(x: 500, y: 0, width: 500, height: 1000), from: source, to: destination)
        #expect(moved == CGRect(x: 2000, y: 0, width: 1000, height: 1000))
    }

    @Test func moveKeepsWindowOnTheDestination() {
        let source = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let destination = CGRect(x: 1000, y: 0, width: 800, height: 600)
        let hangingOff = CGRect(x: 900, y: 900, width: 400, height: 400)
        let moved = ZoneMath.move(hangingOff, from: source, to: destination)
        #expect(destination.contains(moved))
    }
}

struct ZonesControllerTests {
    private let store = TestDefaults()

    @Test func defaultsMatchTheDesign() {
        let zones = ZonesController(defaults: store.defaults)
        #expect(zones.snapsWhileDragging)
        #expect(zones.spansWithOption)
        #expect(!zones.restoresSizeOnUnsnap)
        #expect(!zones.isRunning)
    }

    @Test func layoutIsPerDisplayAndPersists() {
        let zones = ZonesController(defaults: store.defaults)
        #expect(zones.layout(forDisplay: "A") == .defaultLayout)
        zones.setLayout(.focus, forDisplay: "A")
        zones.setLayout(.grid, forDisplay: "B")

        let reloaded = ZonesController(defaults: store.defaults)
        #expect(reloaded.layout(forDisplay: "A") == .focus)
        #expect(reloaded.layout(forDisplay: "B") == .grid)
        #expect(reloaded.layout(forDisplay: "C") == .defaultLayout)
    }

    @Test func behaviorSettingsPersist() {
        let zones = ZonesController(defaults: store.defaults)
        zones.snapsWhileDragging = false
        zones.restoresSizeOnUnsnap = true
        let reloaded = ZonesController(defaults: store.defaults)
        #expect(!reloaded.snapsWhileDragging)
        #expect(reloaded.restoresSizeOnUnsnap)
    }
}
