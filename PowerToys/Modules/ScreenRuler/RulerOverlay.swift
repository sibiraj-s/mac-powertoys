import AppKit
import ScreenCaptureKit

/// A still of one display, taken before the ruler shows so the ruler isn't in it.
private struct DisplayShot {
    let screen: NSScreen
    let image: CGImage
    let grid: PixelGrid
    /// Pixels in the image per point on the display.
    let scale: CGFloat
}

/// The ruler over every display: a still of the screen, with lines out to the nearest edges
/// around the pointer, or the area being dragged over.
final class LiveRulerPresenter: RulerPresenting {
    /// Held while measuring, and ended by `cancel`.
    private var session: RulerSession?
    private var isCapturing = false
    /// Set by `cancel` while the displays are still being captured, so the ruler doesn't open after.
    private var cancelledCapture = false

    func measure(unit: RulerUnit, tolerance: Int) async -> RulerMeasurement? {
        guard session == nil, !isCapturing else { return nil }
        isCapturing = true
        cancelledCapture = false
        let shots = await Self.captureDisplays()
        isCapturing = false
        guard !shots.isEmpty, !cancelledCapture else { return nil }
        let session = RulerSession(shots: shots, unit: unit, tolerance: tolerance)
        self.session = session
        let measurement = await withCheckedContinuation { continuation in
            session.begin { continuation.resume(returning: $0) }
        }
        self.session = nil
        return measurement
    }

    func cancel() {
        if isCapturing { cancelledCapture = true }
        session?.finish(nil)
    }

    /// Every display at once, each read into pixels off the main thread.
    private static func captureDisplays() async -> [DisplayShot] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let screens = Dictionary(
            NSScreen.screens.compactMap { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { ($0, screen) }
            }, uniquingKeysWith: { first, _ in first })
        var captured: [CGDirectDisplayID: (CGImage, PixelGrid)] = [:]
        await withTaskGroup(of: (CGDirectDisplayID, CGImage, PixelGrid)?.self) { group in
            for display in content.displays {
                guard let screen = screens[display.displayID] else { continue }
                let scale = screen.backingScaleFactor
                let pixels = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
                // An SCDisplay is a description of the display that never changes, so it's safe to hand over.
                nonisolated(unsafe) let display = display
                group.addTask { await capture(display, pixels: pixels) }
            }
            for await shot in group {
                if let (id, image, grid) = shot { captured[id] = (image, grid) }
            }
        }
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                let (image, grid) = captured[id]
            else { return nil }
            return DisplayShot(screen: screen, image: image, grid: grid, scale: CGFloat(image.width) / screen.frame.width)
        }
    }

    nonisolated private static func capture(_ display: SCDisplay, pixels: CGSize) async -> (CGDirectDisplayID, CGImage, PixelGrid)? {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(pixels.width))
        configuration.height = max(1, Int(pixels.height))
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
            let grid = PixelGrid(image: image)
        else { return nil }
        return (display.displayID, image, grid)
    }
}

/// One measuring: the panels over each display, and the one the pointer is on.
private final class RulerSession {
    let shots: [DisplayShot]
    let unit: RulerUnit
    let tolerance: Int
    /// The view the pointer is over; only it draws lines.
    weak var active: RulerView?
    private var panels: [RulerPanel] = []
    private var completion: ((RulerMeasurement?) -> Void)?

    init(shots: [DisplayShot], unit: RulerUnit, tolerance: Int) {
        self.shots = shots
        self.unit = unit
        self.tolerance = tolerance
    }

    func begin(completion: @escaping (RulerMeasurement?) -> Void) {
        self.completion = completion
        panels = shots.map { RulerPanel(shot: $0, session: self) }
        for panel in panels { panel.orderFrontRegardless() }
        // Key without activating the app, so its own windows don't come forward over the still.
        let mouse = NSEvent.mouseLocation
        let current = panels.first { $0.frame.contains(mouse) } ?? panels.first
        current?.makeKey()
        current?.ruler.hover(atScreen: mouse)
    }

    func activate(_ view: RulerView) {
        guard active !== view else { return }
        let previous = active
        active = view
        previous?.needsDisplay = true
    }

    func finish(_ measurement: RulerMeasurement?) {
        guard let completion else { return }
        self.completion = nil
        for panel in panels { panel.orderOut(nil) }
        panels = []
        completion(measurement)
    }
}

private final class RulerPanel: NSPanel {
    let ruler: RulerView

    init(shot: DisplayShot, session: RulerSession) {
        ruler = RulerView(shot: shot, session: session)
        super.init(contentRect: shot.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = .screenSaver
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        setFrame(shot.screen.frame, display: false)
        // The still is the layer's contents, set once, so moving the pointer redraws only the lines.
        let still = NSView()
        still.wantsLayer = true
        still.layer?.contents = shot.image
        still.layer?.contentsGravity = .resize
        let container = NSView()
        for view in [still, ruler] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        contentView = container
        // Esc goes to the ruler, not the container.
        makeFirstResponder(ruler)
    }

    override var canBecomeKey: Bool { true }
}

private final class RulerView: NSView {
    private let shot: DisplayShot
    /// Weak, as AppKit can still send an event or a redraw after the ruler has closed.
    weak var session: RulerSession?
    /// The pointer, in this view's points from its top left.
    private var pointer: CGPoint?
    private var dragStart: CGPoint?

    /// Movement under this many points counts as a click, which measures the spacing.
    static let dragThreshold: CGFloat = 3

    init(shot: DisplayShot, session: RulerSession) {
        self.shot = shot
        self.session = session
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    /// Moves the pointer to a point in AppKit screen coordinates.
    func hover(atScreen point: CGPoint) {
        guard let window else { return }
        let inWindow = window.convertPoint(fromScreen: point)
        move(to: convert(inWindow, from: nil))
    }

    private func local(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.maxX - 0.01), y: min(max(point.y, 0), bounds.maxY - 0.01))
    }

    private func move(to point: CGPoint) {
        pointer = point
        session?.activate(self)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        // The pointer may have come from another display; keys follow it so Esc still works.
        if window?.isKeyWindow == false { window?.makeKey() }
        move(to: local(event))
    }

    override func mouseDown(with event: NSEvent) {
        let point = local(event)
        dragStart = point
        move(to: point)
    }

    override func mouseDragged(with event: NSEvent) { move(to: local(event)) }

    override func mouseUp(with event: NSEvent) {
        let end = local(event)
        guard let start = dragStart, let session else { return }
        dragStart = nil
        if hypot(end.x - start.x, end.y - start.y) < Self.dragThreshold {
            session.finish(spacing(at: end))
        } else {
            session.finish(bounds(from: start, to: end))
        }
    }

    override func rightMouseDown(with event: NSEvent) { session?.finish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            session?.finish(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Measuring

    private func pixel(_ value: CGFloat, limit: Int) -> Int {
        min(max(Int((value * shot.scale).rounded(.down)), 0), limit - 1)
    }

    private func extent(at point: CGPoint) -> EdgeFinder.Extent? {
        guard let session else { return nil }
        return EdgeFinder.extent(
            aroundX: pixel(point.x, limit: shot.grid.width), y: pixel(point.y, limit: shot.grid.height), in: shot.grid,
            tolerance: session.tolerance)
    }

    private func spacing(at point: CGPoint) -> RulerMeasurement? {
        extent(at: point).map {
            RulerMeasurement(kind: .spacing, widthPixels: $0.width, heightPixels: $0.height, scale: shot.scale)
        }
    }

    private func bounds(from start: CGPoint, to end: CGPoint) -> RulerMeasurement {
        let rect = Self.rect(from: start, to: end)
        return RulerMeasurement(
            kind: .bounds, widthPixels: Int((rect.width * shot.scale).rounded()), heightPixels: Int((rect.height * shot.scale).rounded()),
            scale: shot.scale)
    }

    private static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let session, session.active === self, let pointer else { return }
        let accent = NSColor.systemPink
        if let start = dragStart, hypot(pointer.x - start.x, pointer.y - start.y) >= Self.dragThreshold {
            let rect = Self.rect(from: start, to: pointer)
            accent.withAlphaComponent(0.15).setFill()
            rect.fill()
            accent.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1
            border.stroke()
            drawLabel(bounds(from: start, to: pointer).text(in: session.unit), at: pointer)
        } else if let extent = extent(at: pointer) {
            let scale = shot.scale
            let left = CGFloat(extent.minX) / scale
            let right = CGFloat(extent.maxX + 1) / scale
            let top = CGFloat(extent.minY) / scale
            let bottom = CGFloat(extent.maxY + 1) / scale
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: CGPoint(x: left, y: pointer.y))
            path.line(to: CGPoint(x: right, y: pointer.y))
            path.move(to: CGPoint(x: pointer.x, y: top))
            path.line(to: CGPoint(x: pointer.x, y: bottom))
            // End caps, so where each line stops is clear against any background.
            for x in [left, right] {
                path.move(to: CGPoint(x: x, y: pointer.y - 5))
                path.line(to: CGPoint(x: x, y: pointer.y + 5))
            }
            for y in [top, bottom] {
                path.move(to: CGPoint(x: pointer.x - 5, y: y))
                path.line(to: CGPoint(x: pointer.x + 5, y: y))
            }
            accent.setStroke()
            path.stroke()
            let measurement = RulerMeasurement(kind: .spacing, widthPixels: extent.width, heightPixels: extent.height, scale: scale)
            drawLabel(measurement.text(in: session.unit), at: pointer)
        }
        drawHint()
    }

    /// A capsule just below and right of the pointer, kept on screen.
    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var capsule = CGRect(x: point.x + 14, y: point.y + 14, width: size.width + 16, height: size.height + 6)
        if capsule.maxX > bounds.maxX - 4 { capsule.origin.x = point.x - 14 - capsule.width }
        if capsule.maxY > bounds.maxY - 4 { capsule.origin.y = point.y - 14 - capsule.height }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: capsule.minX + 8, y: capsule.minY + 3), withAttributes: attributes)
    }

    /// How to use the ruler, at the top of the display.
    private func drawHint() {
        let text = "Click to copy the spacing · Drag to measure an area · Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        // Below the menu bar.
        let top = shot.screen.frame.maxY - shot.screen.visibleFrame.maxY
        let capsule = CGRect(x: bounds.midX - size.width / 2 - 10, y: top + 10, width: size.width + 20, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: capsule.minX + 10, y: capsule.minY + 4), withAttributes: attributes)
    }
}
