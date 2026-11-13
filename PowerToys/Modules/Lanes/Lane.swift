import CoreGraphics

/// One display's row of windows, left to right, and how far along it's scrolled. The row is made
/// of columns: a window on its own, or several stacked top to bottom and sharing a width.
/// Windows are known by the numbers the window system gives them. Distances are in points.
nonisolated struct Lane: Equatable {
    struct Column: Equatable {
        /// Top to bottom.
        var ids: [Int]
        var width: CGFloat
    }

    enum Side: Equatable {
        case left, right
    }

    /// Whether a window is in view, or out of sight on one side.
    enum Placement: Equatable {
        case shown(x: CGFloat)
        case hidden(Side)
    }

    /// Where a window goes: `x` points from the display's left edge, on screen or off, and
    /// which of its column's `rows` it takes, counting from the top.
    struct Place: Equatable {
        let id: Int
        let width: CGFloat
        let x: CGFloat
        let row: Int
        let rows: Int
        let placement: Placement
    }

    /// Where a window sat, to put it back there after it's been away.
    struct Seat: Equatable {
        /// The other windows in its column, and which row it had.
        let mates: [Int]
        let row: Int
        /// The windows in the columns to its left, nearest first, and to its right.
        let before: [Int]
        let after: [Int]
        let width: CGFloat
    }

    let displayKey: String
    private(set) var columns: [Column] = []
    /// The window the row scrolls to keep in view.
    private(set) var focus: Int?
    /// The distance from the start of the row to the display's left edge.
    private(set) var offset: CGFloat = 0

    init(displayKey: String) {
        self.displayKey = displayKey
    }

    var ids: [Int] { columns.flatMap(\.ids) }
    var isEmpty: Bool { columns.isEmpty }

    func contains(_ id: Int) -> Bool {
        column(of: id) != nil
    }

    func width(of id: Int) -> CGFloat? {
        column(of: id).map { columns[$0].width }
    }

    private func column(of id: Int) -> Int? {
        columns.firstIndex { $0.ids.contains(id) }
    }

    // MARK: Changes

    /// Adds a window as a column of its own just right of `anchor`'s, or at the end of the row without one.
    mutating func insert(_ id: Int, width: CGFloat, after anchor: Int?) {
        guard !contains(id) else { return }
        let index = anchor.flatMap(column(of:)).map { $0 + 1 } ?? columns.count
        columns.insert(Column(ids: [id], width: width), at: index)
        if focus == nil { focus = id }
    }

    /// Where a window sits now.
    func seat(of id: Int) -> Seat? {
        guard let index = column(of: id), let row = columns[index].ids.firstIndex(of: id) else { return nil }
        return Seat(
            mates: columns[index].ids.filter { $0 != id }, row: row,
            before: columns[..<index].reversed().flatMap(\.ids), after: columns[(index + 1)...].flatMap(\.ids),
            width: columns[index].width)
    }

    /// Whether any window a seat was among is in this row, so the seat means something here.
    func knows(_ seat: Seat) -> Bool {
        (seat.mates + seat.before + seat.after).contains(where: contains)
    }

    /// Puts a window back where it sat: into its old stack if any of it is left, or else right
    /// of the nearest window that was on its left. Without either it goes beside `anchor`, unless
    /// it was the first in the row, which it is again.
    mutating func insert(_ id: Int, at seat: Seat, orAfter anchor: Int?) {
        guard !contains(id) else { return }
        if let index = seat.mates.compactMap(column(of:)).first {
            columns[index].ids.insert(id, at: min(seat.row, columns[index].ids.count))
        } else if let left = seat.before.first(where: contains) {
            insert(id, width: seat.width, after: left)
        } else if seat.before.isEmpty {
            columns.insert(Column(ids: [id], width: seat.width), at: 0)
        } else {
            insert(id, width: seat.width, after: anchor)
        }
        if focus == nil { focus = id }
    }

    /// Takes a window out. If it had the focus, that goes to the window that takes its place in
    /// its stack, or else to the column on its left, or else to the new first window.
    mutating func remove(_ id: Int) {
        guard let index = column(of: id), let row = columns[index].ids.firstIndex(of: id) else { return }
        columns[index].ids.remove(at: row)
        let stack = columns[index].ids
        if stack.isEmpty { columns.remove(at: index) }
        guard focus == id else { return }
        if !stack.isEmpty {
            focus = stack[min(row, stack.count - 1)]
        } else {
            focus = columns.isEmpty ? nil : columns[max(index - 1, 0)].ids.first
        }
    }

    mutating func setFocus(_ id: Int) {
        if contains(id) { focus = id }
    }

    /// Sets the width of a window's column, and so of everything stacked with it.
    mutating func setWidth(_ width: CGFloat, of id: Int) {
        guard let index = column(of: id) else { return }
        columns[index].width = width
    }

    /// The top window of the column `step` places along from `id`'s; nil past either end of the row.
    func neighbor(of id: Int, step: Int) -> Int? {
        guard let index = column(of: id), columns.indices.contains(index + step) else { return nil }
        return columns[index + step].ids.first
    }

    /// The window `step` places down `id`'s stack; nil past its top or bottom.
    func stackNeighbor(of id: Int, step: Int) -> Int? {
        guard let index = column(of: id), let row = columns[index].ids.firstIndex(of: id),
            columns[index].ids.indices.contains(row + step)
        else { return nil }
        return columns[index].ids[row + step]
    }

    /// Swaps a window's column with the one `step` places along. Says whether anything moved.
    @discardableResult
    mutating func move(_ id: Int, by step: Int) -> Bool {
        guard let index = column(of: id), columns.indices.contains(index + step) else { return false }
        columns.swapAt(index, index + step)
        return true
    }

    /// Moves a window to the bottom of the column on its left. Says whether anything moved.
    @discardableResult
    mutating func stack(_ id: Int) -> Bool {
        guard let index = column(of: id), index > 0 else { return false }
        columns[index].ids.removeAll { $0 == id }
        columns[index - 1].ids.append(id)
        if columns[index].ids.isEmpty { columns.remove(at: index) }
        return true
    }

    /// Moves a window out of its stack into a column of its own on the right. Says whether anything moved.
    @discardableResult
    mutating func unstack(_ id: Int) -> Bool {
        guard let index = column(of: id), columns[index].ids.count > 1 else { return false }
        columns[index].ids.removeAll { $0 == id }
        columns.insert(Column(ids: [id], width: columns[index].width), at: index + 1)
        return true
    }

    /// Moves a window to where it was dropped, `x` points from the display's left edge, as a
    /// column of its own: after every other column whose middle is left of there. Says whether
    /// the row changed.
    @discardableResult
    mutating func drop(_ id: Int, at x: CGFloat) -> Bool {
        guard let index = column(of: id) else { return false }
        let before = columns
        let width = columns[index].width
        var start: CGFloat = 0
        var target = 0
        for column in columns {
            // Its own column counts while anything else is stacked in it.
            if column.ids != [id], start + column.width / 2 < x + offset { target += 1 }
            start += column.width
        }
        columns[index].ids.removeAll { $0 == id }
        if columns[index].ids.isEmpty { columns.remove(at: index) }
        columns.insert(Column(ids: [id], width: width), at: target)
        return columns != before
    }

    // MARK: Layout

    /// Scrolls the row along by `distance`; `fit` then keeps it within its ends.
    mutating func scroll(by distance: CGFloat) {
        offset += distance
    }

    /// The window to settle on in the column with the most of itself in view on a display
    /// `viewWidth` wide: the focused one if it's there, or else the column's top. The leftmost of equals.
    func mostVisible(viewWidth: CGFloat) -> Int? {
        var start: CGFloat = 0
        var best: (column: Column, visible: CGFloat)?
        for column in columns {
            let visible = min(start + column.width, offset + viewWidth) - max(start, offset)
            if visible > (best?.visible ?? 0) { best = (column, visible) }
            start += column.width
        }
        guard let column = best?.column else { return nil }
        return focus.flatMap { column.ids.contains($0) ? $0 : nil } ?? column.ids.first
    }

    /// Whether all of a window is in view on a display `viewWidth` wide.
    func isWhollyVisible(_ id: Int, viewWidth: CGFloat) -> Bool {
        var start: CGFloat = 0
        for column in columns {
            if column.ids.contains(id) { return start >= offset - 1 && start + column.width <= offset + viewWidth + 1 }
            start += column.width
        }
        return false
    }

    /// The window a row scrolled by hand settles on when let go, on a display `viewWidth` wide:
    /// the focused one while it's wholly in view, or else the one with the most in view.
    func settlesOn(viewWidth: CGFloat) -> Int? {
        if let focus, isWhollyVisible(focus, viewWidth: viewWidth) { return focus }
        return mostVisible(viewWidth: viewWidth)
    }

    /// Makes the row fit a display `viewWidth` wide: no column is wider than the display, and
    /// the row never scrolls past either end. Unless it's being scrolled by hand, the focused
    /// window is wholly in view after the shortest scroll that gets it there.
    mutating func fit(viewWidth: CGFloat, followsFocus: Bool = true) {
        for index in columns.indices {
            columns[index].width = min(columns[index].width, viewWidth)
        }
        var start: CGFloat = 0
        for column in columns {
            if followsFocus, let focus, column.ids.contains(focus) {
                if start < offset {
                    offset = start
                } else if start + column.width > offset + viewWidth {
                    offset = start + column.width - viewWidth
                }
            }
            start += column.width
        }
        offset = max(0, min(offset, start - viewWidth))
    }

    /// Where each window goes on a display `viewWidth` wide. A column partly past an edge shows
    /// only if that edge lets windows hang over it; otherwise it's hidden on that side.
    func placements(viewWidth: CGFloat, peeksLeft: Bool, peeksRight: Bool) -> [Place] {
        var start: CGFloat = 0
        return columns.flatMap { column in
            let x = start - offset
            let end = x + column.width
            start += column.width
            let placement: Placement =
                if end <= 0 || (x < 0 && !peeksLeft) {
                    .hidden(.left)
                } else if x >= viewWidth || (end > viewWidth && !peeksRight) {
                    .hidden(.right)
                } else {
                    .shown(x: x)
                }
            return column.ids.enumerated().map { row, id in
                Place(id: id, width: column.width, x: x, row: row, rows: column.ids.count, placement: placement)
            }
        }
    }

    // MARK: Widths

    /// The widths a window steps through, as parts of the display's width.
    static let widths: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3, 1]

    /// The next width up from `width`, going back to the narrowest after the widest.
    static func nextWidth(after width: CGFloat, viewWidth: CGFloat) -> CGFloat {
        let options = widths.map { ($0 * viewWidth).rounded() }
        // Apps round sizes to their own steps, so a window a few points short of a width is at it.
        return options.first { $0 > width + 8 } ?? options[0]
    }
}
