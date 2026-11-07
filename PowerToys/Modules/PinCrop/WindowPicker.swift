import AppKit
import CoreGraphics

/// A window on screen that can be pinned. `frame` is in global display coordinates: origin at
/// the top left of the main display, y growing downward, as Core Graphics and Accessibility use.
nonisolated struct PickableWindow: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let frame: CGRect
}

/// What was picked: a whole window, or part of one.
nonisolated struct WindowSelection: Equatable, Sendable {
    let window: PickableWindow
    /// The part to show, in the window's own points from its top left; nil for the whole window.
    let crop: CGRect?

    /// What's shown, in global display coordinates.
    var sourceRect: CGRect {
        crop.map { $0.offsetBy(dx: window.frame.minX, dy: window.frame.minY) } ?? window.frame
    }

    /// Where the window goes so the part shown sits with its top left at `point`.
    func windowOrigin(showingAt point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - (crop?.minX ?? 0), y: point.y - (crop?.minY ?? 0))
    }
}

/// Finding the window under the pointer and turning a click or drag into a selection.
nonisolated enum WindowPicking {
    /// Movement under this many points counts as a click, which pins the whole window.
    static let dragThreshold: CGFloat = 4
    /// Crops smaller than this on either side are ignored, as from dragging off the window's edge.
    static let minimumCrop: CGFloat = 16

    /// Ordinary app windows from a window list, front to back as listed, without `excludingPID`'s own.
    static func windows(from list: [[String: Any]], ownPID: pid_t) -> [PickableWindow] {
        list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                let id = info[kCGWindowNumber as String] as? Int,
                let pid = info[kCGWindowOwnerPID as String] as? Int,
                // This app's own windows below the menu bar, pins among them, stay in to hide what's behind them.
                layer == 0 || (pid_t(pid) == ownPID && layer < Int(CGWindowLevelForKey(.mainMenuWindow))),
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds),
                frame.width >= minimumCrop, frame.height >= minimumCrop
            else { return nil }
            return PickableWindow(
                id: CGWindowID(id), pid: pid_t(pid),
                appName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                frame: frame
            )
        }
    }

    /// The frontmost window containing `point`, unless it's one of this app's own, which can't be picked.
    static func window(at point: CGPoint, in windows: [PickableWindow], ownPID: pid_t) -> PickableWindow? {
        windows.first { $0.frame.contains(point) }.flatMap { $0.pid == ownPID ? nil : $0 }
    }

    /// A click selects the whole window; a drag selects the part of it dragged over. nil when the
    /// drag covers too little of the window.
    static func selection(of window: PickableWindow, from start: CGPoint, to end: CGPoint) -> WindowSelection? {
        guard hypot(end.x - start.x, end.y - start.y) >= dragThreshold else {
            return WindowSelection(window: window, crop: nil)
        }
        let dragged = rect(from: start, to: end).intersection(window.frame)
        guard !dragged.isNull, dragged.width >= minimumCrop, dragged.height >= minimumCrop else { return nil }
        let crop = dragged.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY).integral
        return WindowSelection(window: window, crop: crop)
    }

    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

/// Shows the picker; a protocol so tests don't show it.
protocol WindowPicker {
    /// The window or part of one picked, or nil when cancelled with Esc or `cancel()`.
    func pick() async -> WindowSelection?
    func cancel()
}

/// An overlay on every display that highlights the window under the pointer.
final class LiveWindowPicker: WindowPicker {
    /// Held while picking: the panels' views hold it unowned, and `cancel` ends it.
    private var session: PickerSession?

    func pick() async -> WindowSelection? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = WindowPicking.windows(from: list, ownPID: ownPID)
        guard session == nil, windows.contains(where: { $0.pid != ownPID }) else { return nil }
        let session = PickerSession(windows: windows, ownPID: ownPID)
        self.session = session
        let selection = await withCheckedContinuation { continuation in
            session.begin { continuation.resume(returning: $0) }
        }
        self.session = nil
        return selection
    }

    func cancel() {
        session?.finish(nil)
    }
}

/// One picking: the panels over each display and what's hovered or dragged.
private final class PickerSession {
    let windows: [PickableWindow]
    let ownPID: pid_t
    private(set) var hovered: PickableWindow?
    private(set) var dragStart: CGPoint?
    private(set) var dragEnd: CGPoint?
    private var panels: [PickerPanel] = []
    private var completion: ((WindowSelection?) -> Void)?

    init(windows: [PickableWindow], ownPID: pid_t) {
        self.windows = windows
        self.ownPID = ownPID
    }

    func begin(completion: @escaping (WindowSelection?) -> Void) {
        self.completion = completion
        panels = NSScreen.screens.map { PickerPanel(screen: $0, session: self) }
        for panel in panels { panel.orderFrontRegardless() }
        // Key without activating the app, so its own windows don't come forward over the ones to pick.
        let mouse = NSEvent.mouseLocation
        let current = panels.first { $0.frame.contains(mouse) } ?? panels.first
        current?.makeKey()
        hover(at: Displays.flip(mouse))
    }

    var draggedRect: CGRect? {
        guard let dragStart, let dragEnd, let hovered,
            hypot(dragEnd.x - dragStart.x, dragEnd.y - dragStart.y) >= WindowPicking.dragThreshold
        else { return nil }
        let rect = WindowPicking.rect(from: dragStart, to: dragEnd).intersection(hovered.frame)
        return rect.isNull ? nil : rect
    }

    func hover(at point: CGPoint) {
        guard dragStart == nil else { return }
        let window = WindowPicking.window(at: point, in: windows, ownPID: ownPID)
        guard window != hovered else { return }
        hovered = window
        redraw()
    }

    func mouseDown(at point: CGPoint) {
        hover(at: point)
        guard hovered != nil else { return }
        dragStart = point
        dragEnd = point
    }

    func mouseDragged(to point: CGPoint) {
        guard dragStart != nil else { return }
        dragEnd = point
        redraw()
    }

    func mouseUp(at point: CGPoint) {
        guard let start = dragStart, let window = hovered else { return }
        dragStart = nil
        dragEnd = nil
        if let selection = WindowPicking.selection(of: window, from: start, to: point) {
            finish(selection)
        } else {
            hover(at: point)
            redraw()
        }
    }

    func finish(_ selection: WindowSelection?) {
        guard let completion else { return }
        self.completion = nil
        for panel in panels { panel.orderOut(nil) }
        panels = []
        completion(selection)
    }

    private func redraw() {
        for panel in panels { panel.contentView?.needsDisplay = true }
    }
}

private final class PickerPanel: NSPanel {
    init(screen: NSScreen, session: PickerSession) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        setFrame(screen.frame, display: false)
        contentView = PickerView(screenOrigin: Displays.flip(screen.frame).origin, session: session)
    }

    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    /// This display's top left in global display coordinates.
    let screenOrigin: CGPoint
    unowned let session: PickerSession

    init(screenOrigin: CGPoint, session: PickerSession) {
        self.screenOrigin = screenOrigin
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

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        return Displays.flip(window.convertPoint(toScreen: event.locationInWindow))
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        // The pointer may have come from another display; keys follow it so Esc still works.
        if window?.isKeyWindow == false { window?.makeKey() }
        session.hover(at: globalPoint(event))
    }

    override func mouseDown(with event: NSEvent) { session.mouseDown(at: globalPoint(event)) }
    override func mouseDragged(with event: NSEvent) { session.mouseDragged(to: globalPoint(event)) }
    override func mouseUp(with event: NSEvent) { session.mouseUp(at: globalPoint(event)) }
    override func rightMouseDown(with event: NSEvent) { session.finish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            session.finish(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window = session.hovered else { return }
        let accent = NSColor.controlAccentColor
        let frame = local(window.frame)
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        outline.lineWidth = 2
        if let dragged = session.draggedRect.map(local) {
            accent.setStroke()
            outline.stroke()
            accent.withAlphaComponent(0.3).setFill()
            dragged.fill()
            let border = NSBezierPath(rect: dragged)
            border.lineWidth = 1.5
            border.stroke()
            drawLabel("\(Int(dragged.width)) × \(Int(dragged.height))", near: dragged)
        } else {
            accent.withAlphaComponent(0.18).setFill()
            outline.fill()
            accent.setStroke()
            outline.stroke()
            drawLabel("Click to pin · Drag to crop", near: frame)
        }
    }

    /// A small capsule centered at the top of `rect`.
    private func drawLabel(_ text: String, near rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let capsule = CGRect(x: rect.midX - size.width / 2 - 10, y: rect.minY + 10, width: size.width + 20, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: capsule.minX + 10, y: capsule.minY + 4), withAttributes: attributes)
    }
}
