import Foundation

/// A display, in Accessibility coordinates.
nonisolated struct LaneDisplay: Equatable {
    let key: String
    let frame: CGRect
    /// The part windows can use, without the menu bar and Dock.
    let area: CGRect
}

/// What's on screen at one moment.
nonisolated struct LaneSnapshot {
    struct Window: Equatable {
        let id: Int
        let frame: CGRect
    }

    var displays: [LaneDisplay]
    /// The windows that can be arranged and are on the Spaces showing now.
    var windows: [Window]
    /// The window with the keyboard, if it's one of `windows`.
    var focused: Int?
    /// The display with the keyboard.
    var mainDisplay: String?
    /// Where the pointer is, when that's known.
    var pointer: CGPoint?
}

/// A window to move, and whether its size changes too.
nonisolated struct LaneMove: Equatable {
    /// The way a window's top left travels as the row scrolls, which can start or end off screen.
    struct Slide: Equatable {
        let from: CGPoint
        let to: CGPoint
    }

    let id: Int
    /// Where the window comes to rest. For a hidden one that's its corner, not its place in the row.
    let frame: CGRect
    let resizes: Bool
    /// nil when the window jumps straight to `frame`.
    var slide: Slide?
}

/// Every lane and where its windows belong. A display has a lane for each Space it has shown
/// windows on; macOS doesn't name Spaces, so a display's lane for the Space showing now is the
/// one whose windows are on screen.
nonisolated struct LaneBoard {
    enum Step: Equatable {
        /// Focus the window this many places along the row.
        case focus(Int)
        /// Focus the window this many places down the focused one's stack.
        case focusStack(Int)
        /// Swap the focused window's column with the one this many places along.
        case move(Int)
        case cycleWidth
        /// Put the focused window under the one on its left.
        case stack
        /// Take the focused window out of its stack, into a column of its own.
        case unstack
    }

    private(set) var lanes: [Lane] = []
    /// Where each window was before it joined a lane, to put it back.
    private(set) var originals: [Int: CGRect] = [:]
    /// Windows that kept going back to where they were, and are left alone.
    private(set) var ignored: Set<Int> = []

    /// Each display's lane for the Space showing now, as an index into `lanes`.
    private var active: [String: Int] = [:]
    /// The frame last asked of each window, and the one it took.
    private var requested: [Int: CGRect] = [:]
    private var settled: [Int: CGRect] = [:]
    /// How often a window was sent to the same frame, and since when.
    private var tries: [Int: (since: Date, count: Int)] = [:]
    /// Where each window was in its row at the last layout: in view, or out of it at a place it
    /// can slide back from (nil when it can only jump).
    private var last: [Int: Spot] = [:]

    /// Where windows sat when they left the screen, by being minimized or hidden with their
    /// app, to put them back there when they return.
    private var seats: [Int: Lane.Seat] = [:]

    /// The width a window took when asked for another, for as long as it hasn't since taken
    /// the width asked.
    private var insists: [Int: CGFloat] = [:]
    /// The size a window took when asked for another: what was asked and what it took.
    private var refused: [Int: (asked: CGSize, took: CGSize)] = [:]

    /// Displays whose row is being scrolled by hand, and so doesn't follow the focused window.
    private var scrolling: Set<String> = []
    /// The displays there were at the last look.
    private var displays: [LaneDisplay] = []

    private enum Spot {
        case shown
        case hidden(row: CGPoint?)
    }

    func lane(on displayKey: String) -> Lane? {
        active[displayKey].map { lanes[$0] }
    }

    // MARK: Following the screen

    /// Whether a lane's display isn't among those there are now. Waking the Mac, or a display
    /// being found again, can leave one out for a moment; looking at the windows then would
    /// drop its rows, which there's no getting back.
    func isMissingADisplay(in snapshot: LaneSnapshot) -> Bool {
        lanes.contains { lane in !snapshot.displays.contains { $0.key == lane.displayKey } }
    }

    /// Brings the lanes in line with what's on screen: windows that opened, closed, were resized
    /// or moved to another display, and which window has the keyboard. `afterDrag` says the
    /// mouse was used since the last look: only then, and only for a window the pointer is
    /// still on and that went some way, is a change of place within its display taken as a drag
    /// and not as its app nudging it.
    mutating func sync(_ snapshot: LaneSnapshot, afterDrag: Bool = false) {
        displays = snapshot.displays
        let windows = snapshot.windows.filter { !ignored.contains($0.id) }
        let present = Set(windows.map(\.id))
        lanes.removeAll { lane in lane.isEmpty || !snapshot.displays.contains { $0.key == lane.displayKey } }

        // A window that isn't where it was put was moved by hand or by its app.
        for window in windows {
            guard let was = settled[window.id], !Self.near(window.frame, was),
                let index = lanes.firstIndex(where: { $0.contains(window.id) })
            else { continue }
            if let display = Self.home(of: window.frame, in: snapshot.displays), display.key != lanes[index].displayKey {
                lanes[index].remove(window.id)
                requested[window.id] = nil
                settled[window.id] = nil
                last[window.id] = nil
            } else if abs(window.frame.width - was.width) > 1 {
                lanes[index].setWidth(window.frame.width, of: window.id)
            } else if afterDrag, Self.isUnderPointer(window.frame, in: snapshot),
                hypot(window.frame.minX - was.minX, window.frame.minY - was.minY) >= Self.dragDistance,
                abs(window.frame.height - was.height) <= 1, case .shown = last[window.id],
                let display = snapshot.displays.first(where: { $0.key == lanes[index].displayKey })
            {
                // Dragged without being resized: it's dropped into the row where it was let go.
                lanes[index].drop(window.id, at: window.frame.midX - display.area.minX)
            }
        }

        // More than one lane has windows on screen when some were moved between Spaces. They
        // joined the Space showing now, so its lane is the one with the fewest windows away.
        active = [:]
        for display in snapshot.displays {
            var best: (index: Int, away: Int, shared: Int)?
            for index in lanes.indices where lanes[index].displayKey == display.key {
                let shared = lanes[index].ids.count { present.contains($0) }
                let away = lanes[index].ids.count - shared
                guard shared > 0 else { continue }
                if best.map({ (away, -shared) < ($0.away, -$0.shared) }) ?? true { best = (index, away, shared) }
            }
            if let best { active[display.key] = best.index }
        }
        // A showing lane loses windows that left the screen; another Space's lane loses any that came to this one.
        let showing = Set(active.values)
        for index in lanes.indices {
            let leaving = lanes[index].ids.filter { present.contains($0) != showing.contains(index) }
            if showing.contains(index) {
                // Minimized, or hidden with its app: its place is kept for when it's back.
                for id in leaving {
                    seats[id] = lanes[index].seat(of: id)
                }
            }
            for id in leaving {
                lanes[index].remove(id)
                last[id] = nil
            }
        }

        // Windows that were away go back to their places, leftmost first so each finds the ones
        // it sat beside. New ones open beside the focused window, and a lane's first windows
        // keep their left-to-right order.
        let known = Set(lanes.flatMap(\.ids))
        var anchors: [Int: Int] = [:]
        let fresh = windows.filter { !known.contains($0.id) }.sorted { a, b in
            switch (seats[a.id], seats[b.id]) {
            case (let a?, let b?): a.before.count < b.before.count
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.frame.minX < b.frame.minX
            }
        }
        for window in fresh {
            // One that's on no display at all joins the first.
            guard let display = Self.home(of: window.frame, in: snapshot.displays) ?? snapshot.displays.first else { continue }
            if originals[window.id] == nil { originals[window.id] = window.frame }
            let index: Int
            if let existing = active[display.key] {
                index = existing
            } else {
                lanes.append(Lane(displayKey: display.key))
                index = lanes.count - 1
                active[display.key] = index
            }
            // A seat from another row, as when the window was moved to another Space, means nothing here.
            if let seat = seats.removeValue(forKey: window.id), lanes[index].knows(seat) {
                lanes[index].insert(window.id, at: seat, orAfter: anchors[index] ?? lanes[index].focus)
            } else {
                lanes[index].insert(
                    window.id, width: min(window.frame.width, display.area.width), after: anchors[index] ?? lanes[index].focus)
                anchors[index] = window.id
            }
        }

        if let focused = snapshot.focused, let index = lanes.firstIndex(where: { $0.contains(focused) }) {
            lanes[index].setFocus(focused)
        }
    }

    /// Changes the lane with the keyboard. Returns the window to bring forward, when the step
    /// changes which one is focused.
    mutating func perform(_ step: Step, in snapshot: LaneSnapshot) -> Int? {
        guard let focused = snapshot.focused, let index = active.values.first(where: { lanes[$0].contains(focused) }) else {
            // A window outside the lanes has the keyboard: go back to the lane's own.
            guard case .focus = step, let key = snapshot.mainDisplay else { return nil }
            return lane(on: key)?.focus
        }
        switch step {
        case .focus(let places):
            guard let next = lanes[index].neighbor(of: focused, step: places) else { return nil }
            lanes[index].setFocus(next)
            return next
        case .focusStack(let places):
            guard let next = lanes[index].stackNeighbor(of: focused, step: places) else { return nil }
            lanes[index].setFocus(next)
            return next
        case .move(let places):
            lanes[index].move(focused, by: places)
        case .stack:
            lanes[index].stack(focused)
        case .unstack:
            lanes[index].unstack(focused)
        case .cycleWidth:
            guard let width = lanes[index].width(of: focused),
                let display = snapshot.displays.first(where: { $0.key == lanes[index].displayKey })
            else { return nil }
            lanes[index].setWidth(Lane.nextWidth(after: width, viewWidth: display.area.width), of: focused)
        }
        return nil
    }

    /// Moves the focus `places` along a display's row, whichever display has the keyboard.
    /// Returns the window to bring forward.
    mutating func stepFocus(by places: Int, on displayKey: String) -> Int? {
        guard let index = active[displayKey], let focus = lanes[index].focus,
            let next = lanes[index].neighbor(of: focus, step: places)
        else { return nil }
        lanes[index].setFocus(next)
        return next
    }

    /// Scrolls a display's row by hand. Says whether there's a row there to scroll.
    mutating func scroll(on displayKey: String, by distance: CGFloat) -> Bool {
        guard let index = active[displayKey] else { return false }
        scrolling.insert(displayKey)
        lanes[index].scroll(by: distance)
        return true
    }

    /// Ends scrolling by hand. The row stays where it was left if the focused window is still
    /// wholly in view; otherwise the window with the most in view takes the focus, and this
    /// returns it to be brought forward.
    mutating func endScroll(in snapshot: LaneSnapshot) -> Int? {
        var forward: Int?
        for display in snapshot.displays where scrolling.contains(display.key) {
            guard let index = active[display.key] else { continue }
            if let focus = lanes[index].focus, lanes[index].isWhollyVisible(focus, viewWidth: display.area.width) { continue }
            guard let next = lanes[index].mostVisible(viewWidth: display.area.width) else { continue }
            lanes[index].setFocus(next)
            forward = next
        }
        scrolling = []
        return forward
    }

    // MARK: Placing windows

    /// The windows that aren't where their lane puts them. Call after `sync`, and tell `settle`
    /// where each one ended up. `afterDrag` says the mouse was used since the last layout, so a
    /// window that isn't where it was put may have been moved by hand.
    mutating func layout(_ snapshot: LaneSnapshot, afterDrag: Bool = false, now: Date = .now) -> [LaneMove] {
        let frames = Dictionary(snapshot.windows.map { ($0.id, $0.frame) }) { first, _ in first }
        var released: [LaneMove] = []
        while true {
            let targets = targets(in: snapshot, frames: frames)
            let pending = targets.filter { target in
                requested[target.id] != target.frame || !(settled[target.id].map { Self.near(target.current, $0) } ?? false)
            }
            // Sent to the same frame before and it didn't stay, with nobody dragging it: its app
            // put it back. One that does so over and over is left alone, back where it started.
            let stubborn = pending.filter { target in
                !(afterDrag && Self.isUnderPointer(target.current, in: snapshot))
                    && requested[target.id] == target.frame && recentTries(of: target.id, now: now) >= 4
            }
            guard stubborn.isEmpty else {
                for target in stubborn {
                    if let move = release(target.id) { released.append(move) }
                    ignored.insert(target.id)
                }
                // The rest close the gap, so they're placed again.
                continue
            }
            let moves = pending.map { target in
                if requested[target.id] != target.frame {
                    tries[target.id] = nil
                } else if !(afterDrag && Self.isUnderPointer(target.current, in: snapshot)) {
                    tries[target.id] = (now, recentTries(of: target.id, now: now) + 1)
                }
                requested[target.id] = target.frame
                settled[target.id] = target.frame
                return LaneMove(
                    id: target.id, frame: target.frame, resizes: needsResize(target), slide: slide(for: target))
            }
            for target in targets {
                last[target.id] = target.isShown ? .shown : .hidden(row: target.slides ? target.row : nil)
            }
            return released + moves
        }
    }

    /// Whether a window has to be given a size as well as a place. One that took another size
    /// than the one asked, a height of its app's own for one, would only do so again.
    private func needsResize(_ target: Target) -> Bool {
        guard !Self.sizeNear(target.current.size, target.frame.size) else { return false }
        guard let refused = refused[target.id] else { return true }
        return !(Self.sizeNear(refused.asked, target.frame.size) && Self.sizeNear(refused.took, target.current.size))
    }

    /// How a window travels to its new place. One in view, or new, starts where it is; one out
    /// of view starts where it sat in the row. Nothing slides between two places out of view.
    private func slide(for target: Target) -> LaneMove.Slide? {
        let from: CGPoint?
        switch last[target.id] {
        case .hidden(let row): from = target.isShown ? row : nil
        case .shown: from = target.current.origin
        case nil: from = target.isShown ? target.current.origin : nil
        }
        guard let from, target.isShown || target.slides else { return nil }
        guard abs(from.x - target.row.x) > 1 || abs(from.y - target.row.y) > 1 else { return nil }
        return LaneMove.Slide(from: from, to: target.row)
    }

    /// How many times in a row, and lately, a window was sent to the frame it's being sent to again.
    private func recentTries(of id: Int, now: Date) -> Int {
        guard let attempt = tries[id], now.timeIntervalSince(attempt.since) <= 2 else { return 0 }
        return attempt.count
    }

    private struct Target {
        let id: Int
        /// Where it comes to rest.
        let frame: CGRect
        let current: CGRect
        /// Its place in the row, on screen or off.
        let row: CGPoint
        let isShown: Bool
        /// Whether it can travel to or from its place in the row without showing on another display.
        let slides: Bool
    }

    /// Where every window in a showing lane belongs, with where it is now.
    private mutating func targets(in snapshot: LaneSnapshot, frames: [Int: CGRect]) -> [Target] {
        var targets: [Target] = []
        for display in snapshot.displays {
            guard let index = active[display.key] else { continue }
            // A window hanging over an edge would show on a display next to it, so it's hidden instead.
            let others = snapshot.displays.filter { $0.key != display.key }.map(\.frame)
            let beside = others.filter { $0.minY < display.frame.maxY && $0.maxY > display.frame.minY }
            let peeksLeft = !beside.contains { $0.midX < display.frame.minX }
            let peeksRight = !beside.contains { $0.midX > display.frame.maxX }
            lanes[index].fit(viewWidth: display.area.width, followsFocus: !scrolling.contains(display.key))
            for place in lanes[index].placements(viewWidth: display.area.width, peeksLeft: peeksLeft, peeksRight: peeksRight) {
                guard let current = frames[place.id] else { continue }
                // Stacked windows share the height evenly; the bottom one takes what's left over.
                let height = (display.area.height / CGFloat(place.rows)).rounded(.down)
                let y = display.area.minY + CGFloat(place.row) * height
                let row = CGPoint(x: display.area.minX + place.x, y: y)
                switch place.placement {
                case .shown:
                    let size = CGSize(width: place.width, height: place.row == place.rows - 1 ? display.area.maxY - y : height)
                    targets.append(
                        Target(
                            id: place.id, frame: CGRect(origin: row, size: size), current: current, row: row, isShown: true, slides: true))
                case .hidden(let side):
                    let origin = Self.tuckOrigin(
                        size: current.size, side: side, display: display.frame, top: display.area.minY, others: others)
                    targets.append(
                        Target(
                            id: place.id, frame: CGRect(origin: origin, size: current.size), current: current, row: row, isShown: false,
                            slides: side == .left ? peeksLeft : peeksRight))
                }
            }
        }
        return targets
    }

    /// Takes back a move that couldn't be made, so the window is sent there again at the next layout.
    mutating func missed(_ id: Int) {
        requested[id] = nil
        settled[id] = nil
    }

    /// Records where a window ended up after a move. An app can refuse a width, by having a
    /// narrowest or widest one or sizing in steps; the lane takes the width it got, and this
    /// returns true because the windows after it then belong somewhere else. In a stack, where
    /// windows share a width, one that insists on a width another there won't take is moved out
    /// into a column of its own: together they'd be resized back and forth for good.
    @discardableResult
    mutating func settle(_ id: Int, at actual: CGRect) -> Bool {
        guard let asked = requested[id] else { return false }
        settled[id] = actual
        refused[id] = Self.sizeNear(actual.size, asked.size) ? nil : (asked.size, actual.size)
        guard abs(actual.width - asked.width) > 1, let index = lanes.firstIndex(where: { $0.contains(id) }) else {
            insists[id] = nil
            return false
        }
        insists[id] = actual.width
        let mates = lanes[index].seat(of: id)?.mates ?? []
        if mates.contains(where: { mate in insists[mate].map { abs($0 - actual.width) > 1 } ?? false }) {
            lanes[index].unstack(id)
        }
        lanes[index].setWidth(actual.width, of: id)
        return true
    }

    /// Drops everything known about a window that has closed.
    mutating func forget(_ id: Int) {
        for index in lanes.indices {
            lanes[index].remove(id)
        }
        originals[id] = nil
        requested[id] = nil
        settled[id] = nil
        tries[id] = nil
        last[id] = nil
        seats[id] = nil
        insists[id] = nil
        refused[id] = nil
        ignored.remove(id)
    }

    /// Lets go of a window that's being left out of the lanes. Returns the move that puts it
    /// back where it was before it joined one.
    mutating func release(_ id: Int) -> LaneMove? {
        let original = originals[id]
        forget(id)
        return original.map { LaneMove(id: id, frame: Self.onScreen($0, displays: displays), resizes: true, slide: nil) }
    }

    /// The moves that put every window back where it was before it joined a lane, those that
    /// are minimized or hidden with their app for now included.
    func restorations() -> [LaneMove] {
        originals.sorted { $0.key < $1.key }.map {
            LaneMove(id: $0.key, frame: Self.onScreen($0.value, displays: displays), resizes: true, slide: nil)
        }
    }

    /// `frame` as it is if enough of it shows on a display to take hold of. One that doesn't,
    /// as when its display was unplugged, or it was hidden at an edge when an earlier run went
    /// away, is moved onto its display, or else the nearest, and made to fit it.
    static func onScreen(_ frame: CGRect, displays: [LaneDisplay]) -> CGRect {
        guard !displays.isEmpty else { return frame }
        let shows = displays.contains { display in
            let visible = display.frame.intersection(frame)
            return !visible.isNull && visible.width >= min(frame.width, Self.grip) && visible.height >= min(frame.height, Self.grip)
        }
        guard !shows else { return frame }
        func distance(_ display: LaneDisplay) -> CGFloat {
            hypot(display.frame.midX - frame.midX, display.frame.midY - frame.midY)
        }
        guard let nearest = (home(of: frame, in: displays) ?? displays.min(by: { distance($0) < distance($1) }))?.area else {
            return frame
        }
        let size = CGSize(width: min(frame.width, nearest.width), height: min(frame.height, nearest.height))
        return CGRect(
            x: min(max(frame.minX, nearest.minX), nearest.maxX - size.width),
            y: min(max(frame.minY, nearest.minY), nearest.maxY - size.height), width: size.width, height: size.height)
    }

    /// Where each arranged window was put, with where it was before, to recover from if the
    /// app goes away without putting them back.
    var records: [(id: Int, placed: CGRect, original: CGRect)] {
        originals.sorted { $0.key < $1.key }.compactMap { id, original in settled[id].map { (id, $0, original) } }
    }

    /// Takes `original` as where a window was before it joined a lane, for one found already
    /// arranged from before.
    mutating func adopt(_ original: CGRect, for id: Int) {
        if originals[id] == nil { originals[id] = original }
    }

    // MARK: Geometry

    /// How far a window has to have gone for it to count as dragged, in points.
    static let dragDistance: CGFloat = 20

    /// Whether the pointer is on a window, as it is on one just dragged. True when it isn't
    /// known where the pointer is.
    static func isUnderPointer(_ frame: CGRect, in snapshot: LaneSnapshot) -> Bool {
        snapshot.pointer.map(frame.contains) ?? true
    }

    /// Whether two frames match to within a point, as frames read back from apps do.
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    /// The display holding most of `frame`; nil when it's on none of them.
    static func display(holding frame: CGRect, in displays: [LaneDisplay]) -> LaneDisplay? {
        let best = displays.max { area(of: $0.frame.intersection(frame)) < area(of: $1.frame.intersection(frame)) }
        guard let best, area(of: best.frame.intersection(frame)) > 0 else { return nil }
        return best
    }

    /// Where a hidden window's top left goes. macOS keeps windows from leaving the screen
    /// altogether, so one point of it stays at a bottom corner of its display: the corner on the
    /// side it scrolled off, unless less of it would show on another display from the other.
    /// With a display below as well, it hangs off a side instead, showing a line one point wide.
    static func tuckOrigin(size: CGSize, side: Lane.Side, display: CGRect, top: CGFloat, others: [CGRect]) -> CGPoint {
        let candidates = tuckOrigins(size: size, nearSide: side, display: display, top: top)
        func spill(_ origin: CGPoint) -> CGFloat {
            others.reduce(0) { $0 + area(of: $1.intersection(CGRect(origin: origin, size: size))) }
        }
        // The first of those that show least elsewhere.
        return candidates.min { spill($0) < spill($1) } ?? candidates[0]
    }

    /// Everywhere a hidden window of a display may be put, the likeliest first.
    private static func tuckOrigins(size: CGSize, nearSide: Lane.Side, display: CGRect, top: CGFloat) -> [CGPoint] {
        let left = display.minX + 1 - size.width
        let right = display.maxX - 1
        let (near, far) = nearSide == .left ? (left, right) : (right, left)
        return [
            CGPoint(x: near, y: display.maxY - 1), CGPoint(x: far, y: display.maxY - 1),
            CGPoint(x: near, y: top), CGPoint(x: far, y: top),
        ]
    }

    /// The display a window belongs to: the one it's hidden at the edge of, if it's where a
    /// hidden window would be, or else the one holding most of it. A hidden window has only a
    /// point on its own display, and can have more than that on the one next to it.
    static func home(of frame: CGRect, in displays: [LaneDisplay]) -> LaneDisplay? {
        displays.first { isTucked(frame, at: $0, among: displays) } ?? display(holding: frame, in: displays)
    }

    /// Whether `frame` is where a hidden window of `display` goes, or went: macOS pulls one
    /// left at a bottom corner partly back up in time, so that strip of it shows. One pulled up
    /// counts only while it's on no other display, as hidden windows are wherever they can be,
    /// so that a window simply at the edge of the display next door isn't taken for one.
    private static func isTucked(_ frame: CGRect, at display: LaneDisplay, among displays: [LaneDisplay]) -> Bool {
        tuckOrigins(size: frame.size, nearSide: .left, display: display.frame, top: display.area.minY).contains { origin in
            guard abs(origin.x - frame.minX) <= 1 else { return false }
            if abs(origin.y - frame.minY) <= 1 { return true }
            return origin.y == display.frame.maxY - 1 && frame.minY < origin.y && frame.minY >= display.frame.maxY - Self.pullBack
                && !displays.contains { $0.key != display.key && area(of: $0.frame.intersection(frame)) > 0 }
        }
    }

    /// Whether a window found at `frame` is one an earlier run put at `placed`: there still,
    /// or hidden at the same edge, where macOS may have moved it up or down since.
    static func isSamePlace(_ placed: CGRect, _ frame: CGRect, in displays: [LaneDisplay]) -> Bool {
        near(placed, frame)
            || (abs(placed.minX - frame.minX) <= 1 && sizeNear(placed.size, frame.size)
                && displays.contains { isTucked(placed, at: $0, among: displays) && isTucked(frame, at: $0, among: displays) })
    }

    /// How far macOS may have pulled a window hidden at a bottom corner back up, in points.
    private static let pullBack: CGFloat = 200

    /// How much of a window has to show, across and down, for it to be taken hold of, in points.
    private static let grip: CGFloat = 40

    static func sizeNear(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
