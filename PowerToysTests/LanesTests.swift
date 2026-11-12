import CoreGraphics
import Foundation
import Testing

@testable import PowerToys

struct LaneTests {
    private func lane(_ widths: [CGFloat], focus: Int? = nil) -> Lane {
        var lane = Lane(displayKey: "A")
        for (index, width) in widths.enumerated() {
            lane.insert(index + 1, width: width, after: nil)
        }
        if let focus { lane.setFocus(focus) }
        return lane
    }

    @Test func newWindowGoesBesideItsAnchorOrToTheEnd() {
        var lane = lane([400, 400, 400])
        lane.insert(9, width: 300, after: 1)
        lane.insert(8, width: 300, after: nil)
        lane.insert(9, width: 300, after: 3)  // already there
        #expect(lane.ids == [1, 9, 2, 3, 8])
        #expect(lane.focus == 1)
    }

    @Test func closingTheFocusedWindowFocusesItsLeftNeighbour() {
        var lane = lane([400, 400, 400], focus: 2)
        lane.remove(2)
        #expect(lane.focus == 1)
        lane.remove(1)
        #expect(lane.focus == 3)
        lane.remove(3)
        #expect(lane.focus == nil)
        #expect(lane.isEmpty)
    }

    @Test func closingAnotherWindowKeepsTheFocus() {
        var lane = lane([400, 400, 400], focus: 3)
        lane.remove(1)
        #expect(lane.focus == 3)
    }

    @Test func neighboursStopAtTheEnds() {
        let lane = lane([400, 400, 400])
        #expect(lane.neighbor(of: 1, step: 1) == 2)
        #expect(lane.neighbor(of: 1, step: -1) == nil)
        #expect(lane.neighbor(of: 3, step: 1) == nil)
        #expect(lane.neighbor(of: 7, step: 1) == nil)
    }

    @Test func movingSwapsWithTheNeighbour() {
        var lane = lane([400, 500, 600])
        let moved = lane.move(1, by: 1)
        #expect(moved)
        #expect(lane.ids == [2, 1, 3])
        let movedPastTheEnd = lane.move(3, by: 1)
        #expect(!movedPastTheEnd)
        #expect(lane.ids == [2, 1, 3])
    }

    @Test func scrollsJustFarEnoughToShowTheFocusedWindow() {
        var lane = lane([600, 600, 600, 600], focus: 1)
        lane.fit(viewWidth: 1000)
        #expect(lane.offset == 0)
        lane.setFocus(2)  // spans 600...1200
        lane.fit(viewWidth: 1000)
        #expect(lane.offset == 200)
        lane.setFocus(3)  // spans 1200...1800
        lane.fit(viewWidth: 1000)
        #expect(lane.offset == 800)
        lane.setFocus(2)  // already in view: no scroll
        lane.fit(viewWidth: 1000)
        #expect(lane.offset == 600)
    }

    @Test func neverScrollsPastTheEndsOfTheRow() {
        var lane = lane([600, 600, 600], focus: 3)
        lane.fit(viewWidth: 1000)
        #expect(lane.offset == 800)
        lane.remove(3)
        lane.fit(viewWidth: 1000)
        #expect(lane.offset == 200)
        lane.remove(2)  // the row is now narrower than the display
        lane.fit(viewWidth: 1000)
        #expect(lane.offset == 0)
    }

    @Test func noWindowIsWiderThanTheDisplay() {
        var lane = lane([1600, 400])
        lane.fit(viewWidth: 1000)
        #expect(lane.width(of: 1) == 1000)
    }

    @Test func windowsPastAnEdgeAreHiddenOnThatSide() {
        var lane = lane([600, 600, 600, 600], focus: 3)
        lane.fit(viewWidth: 1000)  // offset 800: 1 is gone, 2 hangs over the left edge, 4 is past the right
        let peeking = lane.placements(viewWidth: 1000, peeksLeft: true, peeksRight: true).map(\.placement)
        #expect(peeking == [.hidden(.left), .shown(x: -200), .shown(x: 400), .hidden(.right)])
        let tidy = lane.placements(viewWidth: 1000, peeksLeft: false, peeksRight: false).map(\.placement)
        #expect(tidy == [.hidden(.left), .hidden(.left), .shown(x: 400), .hidden(.right)])
    }

    @Test func windowHangingOverTheRightEdgeNeedsThatEdgeFree() {
        var lane = lane([600, 600], focus: 1)
        lane.fit(viewWidth: 1000)
        #expect(lane.placements(viewWidth: 1000, peeksLeft: false, peeksRight: true).map(\.placement) == [.shown(x: 0), .shown(x: 600)])
        #expect(lane.placements(viewWidth: 1000, peeksLeft: true, peeksRight: false).map(\.placement) == [.shown(x: 0), .hidden(.right)])
    }

    @Test func scrollingByHandLeavesTheFocusedWindowBehind() {
        var lane = lane([600, 600, 600], focus: 1)
        lane.scroll(by: 500)
        lane.fit(viewWidth: 1000, followsFocus: false)
        #expect(lane.offset == 500)
        #expect(!lane.isWhollyVisible(1, viewWidth: 1000))
        #expect(lane.isWhollyVisible(2, viewWidth: 1000))
        #expect(lane.mostVisible(viewWidth: 1000) == 2)
        // Never past either end.
        lane.scroll(by: 5000)
        lane.fit(viewWidth: 1000, followsFocus: false)
        #expect(lane.offset == 800)
        lane.scroll(by: -5000)
        lane.fit(viewWidth: 1000, followsFocus: false)
        #expect(lane.offset == 0)
        // Following the focus again brings it back.
        lane.scroll(by: 700)
        lane.fit(viewWidth: 1000)
        #expect(lane.offset == 0)
    }

    @Test func stackingPutsAWindowUnderItsLeftNeighbour() {
        var lane = lane([400, 500, 600], focus: 2)
        let stacked = lane.stack(2)
        #expect(stacked)
        #expect(lane.columns.map(\.ids) == [[1, 2], [3]])
        #expect(lane.width(of: 2) == 400)
        #expect(lane.focus == 2)
        let first = lane.stack(1)  // nothing on its left
        #expect(!first)
        lane.stack(3)
        #expect(lane.columns.map(\.ids) == [[1, 2, 3]])
        let places = lane.placements(viewWidth: 1000, peeksLeft: true, peeksRight: true)
        #expect(places.map(\.row) == [0, 1, 2])
        #expect(places.allSatisfy { $0.rows == 3 && $0.x == 0 })
    }

    @Test func unstackingGivesAWindowItsOwnColumnOnTheRight() {
        var lane = lane([400, 500, 600])
        lane.stack(2)
        let moved = lane.unstack(1)
        #expect(moved)
        #expect(lane.columns.map(\.ids) == [[2], [1], [3]])
        #expect(lane.width(of: 1) == 400)
        let alone = lane.unstack(3)
        #expect(!alone)
    }

    @Test func focusMovesThroughAStackAndAcrossColumns() {
        var lane = lane([400, 500, 600, 300])
        lane.stack(3)  // [1], [2, 3], [4]
        #expect(lane.stackNeighbor(of: 2, step: 1) == 3)
        #expect(lane.stackNeighbor(of: 3, step: 1) == nil)
        #expect(lane.stackNeighbor(of: 3, step: -1) == 2)
        #expect(lane.stackNeighbor(of: 1, step: 1) == nil)
        // Across columns, focus lands on the top of the stack.
        #expect(lane.neighbor(of: 4, step: -1) == 2)
        #expect(lane.neighbor(of: 3, step: 1) == 4)
        // A stack moves along the row as one.
        lane.move(3, by: 1)
        #expect(lane.columns.map(\.ids) == [[1], [4], [2, 3]])
    }

    @Test func closingAStackedWindowFocusesTheOneThatTakesItsPlace() {
        var lane = lane([400, 500, 600])
        lane.stack(2)
        lane.stack(3)  // [1, 2, 3]
        lane.setFocus(2)
        lane.remove(2)
        #expect(lane.focus == 3)
        lane.remove(3)
        #expect(lane.focus == 1)
    }

    @Test func droppedWindowGoesBetweenTheColumnsThere() {
        var lane = lane([400, 400, 400])
        // Let go past the middle of the last window: it goes to the end.
        let toTheEnd = lane.drop(1, at: 1100)
        #expect(toTheEnd)
        #expect(lane.ids == [2, 3, 1])
        // Before the middle of the first: it goes to the front.
        lane.drop(1, at: 100)
        #expect(lane.ids == [1, 2, 3])
        // Let go about where it already was: nothing changes.
        let stayed = lane.drop(2, at: 600)
        #expect(!stayed)
        // Dragged out of a stack, it gets a column of its own.
        lane.stack(2)
        lane.drop(2, at: 900)
        #expect(lane.columns.map(\.ids) == [[1], [3], [2]])
    }

    @Test func windowGoesBackToTheSeatItLeft() {
        var lane = lane([400, 500, 600, 300])
        lane.stack(3)  // [1], [2, 3], [4]
        let first = lane.seat(of: 1)!
        let stacked = lane.seat(of: 3)!
        let last = lane.seat(of: 4)!
        #expect(stacked == Lane.Seat(mates: [2], row: 1, before: [1], after: [4], width: 500))
        lane.remove(1)
        lane.remove(3)
        lane.remove(4)
        lane.insert(4, at: last, orAfter: nil)
        lane.insert(3, at: stacked, orAfter: nil)
        lane.insert(1, at: first, orAfter: nil)
        #expect(lane.columns.map(\.ids) == [[1], [2, 3], [4]])
        #expect(lane.width(of: 4) == 300)
    }

    @Test func seatFallsBackWhenItsNeighboursAreGone() {
        var lane = lane([400, 500, 600])
        let seat = lane.seat(of: 3)!  // sat right of 2, then 1
        lane.remove(3)
        lane.remove(2)
        lane.insert(3, at: seat, orAfter: nil)
        #expect(lane.ids == [1, 3])
        lane.remove(3)
        lane.remove(1)
        lane.insert(7, width: 200, after: nil)
        lane.insert(8, width: 200, after: nil)
        lane.insert(3, at: seat, orAfter: 7)  // nobody it knew is left: beside the given window
        #expect(lane.ids == [7, 3, 8])
    }

    @Test func widthsStepUpAndWrap() {
        #expect(Lane.nextWidth(after: 300, viewWidth: 1200) == 400)
        #expect(Lane.nextWidth(after: 400, viewWidth: 1200) == 600)
        #expect(Lane.nextWidth(after: 600, viewWidth: 1200) == 800)
        #expect(Lane.nextWidth(after: 800, viewWidth: 1200) == 1200)
        #expect(Lane.nextWidth(after: 1200, viewWidth: 1200) == 400)
        // A terminal a few points short of a half is at the half.
        #expect(Lane.nextWidth(after: 595, viewWidth: 1200) == 800)
    }
}

struct LaneBoardTests {
    /// A display 1000 wide with a 25-point menu bar.
    private let main = LaneDisplay(
        key: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), area: CGRect(x: 0, y: 25, width: 1000, height: 775))
    private let right = LaneDisplay(
        key: "B", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), area: CGRect(x: 1000, y: 25, width: 1000, height: 775))

    private func snapshot(_ frames: [Int: CGRect], focused: Int? = nil, displays: [LaneDisplay]? = nil) -> LaneSnapshot {
        LaneSnapshot(
            displays: displays ?? [main],
            windows: frames.sorted { $0.key < $1.key }.map { LaneSnapshot.Window(id: $0.key, frame: $0.value) },
            focused: focused, mainDisplay: "A")
    }

    /// Syncs and lays out, moving every window where it's sent, as a well-behaved app would.
    private func arrange(
        _ board: inout LaneBoard, _ frames: inout [Int: CGRect], focused: Int? = nil, displays: [LaneDisplay]? = nil,
        afterDrag: Bool = false
    ) {
        let snapshot = snapshot(frames, focused: focused, displays: displays)
        board.sync(snapshot, afterDrag: afterDrag)
        for move in board.layout(snapshot) {
            frames[move.id] = move.frame
            _ = board.settle(move.id, at: move.frame)
        }
    }

    @Test func windowsOnScreenBecomeARowInLeftToRightOrder() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 500, y: 100, width: 400, height: 300),
            2: CGRect(x: 50, y: 200, width: 300, height: 500),
        ]
        let before = frames
        arrange(&board, &frames, focused: 2)
        #expect(board.lane(on: "A")?.ids == [2, 1])
        #expect(frames[2] == CGRect(x: 0, y: 25, width: 300, height: 775))
        #expect(frames[1] == CGRect(x: 300, y: 25, width: 400, height: 775))
        #expect(board.originals == before)
    }

    @Test func settledWindowsAreNotMovedAgain() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 400, height: 300), 2: CGRect(x: 500, y: 0, width: 400, height: 300)]
        arrange(&board, &frames, focused: 1)
        let snapshot = snapshot(frames, focused: 1)
        board.sync(snapshot)
        let moves = board.layout(snapshot)
        #expect(moves.isEmpty)
    }

    @Test func newWindowOpensBesideTheFocusedOne() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 400, y: 0, width: 300, height: 300),
        ]
        arrange(&board, &frames, focused: 1)
        frames[3] = CGRect(x: 200, y: 200, width: 250, height: 200)
        arrange(&board, &frames, focused: 3)
        #expect(board.lane(on: "A")?.ids == [1, 3, 2])
        #expect(board.lane(on: "A")?.focus == 3)
        #expect(frames[3] == CGRect(x: 300, y: 25, width: 250, height: 775))
        #expect(frames[2] == CGRect(x: 550, y: 25, width: 300, height: 775))
    }

    @Test func closingAWindowClosesTheGap() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 400, y: 0, width: 300, height: 300),
            3: CGRect(x: 800, y: 0, width: 300, height: 300),
        ]
        arrange(&board, &frames, focused: 1)
        frames[2] = nil
        board.forget(2)
        arrange(&board, &frames, focused: 1)
        #expect(board.lane(on: "A")?.ids == [1, 3])
        #expect(frames[3]?.minX == 300)
        #expect(board.originals[2] == nil)
    }

    @Test func resizingByHandKeepsTheNewWidth() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 300, height: 300)]
        arrange(&board, &frames, focused: 1)
        frames[1] = CGRect(x: 0, y: 25, width: 450, height: 775)
        arrange(&board, &frames, focused: 1)
        #expect(board.lane(on: "A")?.width(of: 1) == 450)
        #expect(frames[2]?.minX == 450)
    }

    @Test func draggedWindowGoesBackToItsPlace() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 300, height: 300)]
        arrange(&board, &frames, focused: 1)
        frames[2] = CGRect(x: 600, y: 200, width: 300, height: 775)
        arrange(&board, &frames, focused: 2)
        #expect(frames[2] == CGRect(x: 300, y: 25, width: 300, height: 775))
    }

    @Test func draggingToAnotherDisplayJoinsItsRow() {
        var board = LaneBoard()
        let displays = [main, right]
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 400, y: 0, width: 300, height: 300),
            3: CGRect(x: 1200, y: 0, width: 300, height: 300),
        ]
        arrange(&board, &frames, focused: 1, displays: displays)
        #expect(board.lane(on: "A")?.ids == [1, 2])
        #expect(board.lane(on: "B")?.ids == [3])
        frames[2] = CGRect(x: 1500, y: 100, width: 300, height: 775)
        arrange(&board, &frames, focused: 2, displays: displays)
        #expect(board.lane(on: "A")?.ids == [1])
        #expect(board.lane(on: "B")?.ids == [3, 2])
        #expect(frames[2] == CGRect(x: 1300, y: 25, width: 300, height: 775))
    }

    @Test func eachSpaceHasItsOwnRow() {
        var board = LaneBoard()
        var first: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 300, height: 300)]
        arrange(&board, &first, focused: 2)
        // Another Space shows other windows; the first Space's aren't listed while it's away.
        var second: [Int: CGRect] = [3: CGRect(x: 100, y: 0, width: 500, height: 300)]
        arrange(&board, &second, focused: 3)
        #expect(board.lane(on: "A")?.ids == [3])
        #expect(board.lanes.map(\.ids) == [[1, 2], [3]])
        // Back on the first Space, its row is as it was.
        arrange(&board, &first, focused: 2)
        #expect(board.lane(on: "A")?.ids == [1, 2])
        #expect(board.lane(on: "A")?.focus == 2)
        #expect(board.lanes.map(\.ids) == [[1, 2], [3]])
    }

    @Test func windowMovedToAnotherSpaceChangesRows() {
        var board = LaneBoard()
        var first: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 300, height: 300)]
        arrange(&board, &first, focused: 1)
        var second: [Int: CGRect] = [3: CGRect(x: 100, y: 0, width: 500, height: 300)]
        arrange(&board, &second, focused: 3)
        second[2] = first.removeValue(forKey: 2)
        arrange(&board, &second, focused: 3)
        #expect(board.lanes.map(\.ids) == [[1], [3, 2]])
    }

    @Test func emptiedRowsAreDropped() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300)]
        arrange(&board, &frames)
        frames = [:]
        board.forget(1)
        arrange(&board, &frames)
        #expect(board.lanes.isEmpty)
        #expect(board.lane(on: "A") == nil)
    }

    @Test func windowsScrolledOffAreTuckedIntoABottomCorner() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 600, height: 300),
            2: CGRect(x: 100, y: 0, width: 600, height: 300),
            3: CGRect(x: 200, y: 0, width: 600, height: 300),
            4: CGRect(x: 300, y: 0, width: 600, height: 300),
        ]
        arrange(&board, &frames, focused: 3)
        // Scrolled 800 along: 2 hangs over the left edge, 3 fills the rest, 1 and 4 are out of sight.
        #expect(frames[2] == CGRect(x: -200, y: 25, width: 600, height: 775))
        #expect(frames[3] == CGRect(x: 400, y: 25, width: 600, height: 775))
        #expect(frames[1]?.origin == CGPoint(x: -599, y: 799))
        #expect(frames[4]?.origin == CGPoint(x: 999, y: 799))
        // Hidden windows keep their size, ready to come back.
        #expect(frames[4]?.size == CGSize(width: 600, height: 300))
    }

    @Test func nothingHangsOverOntoADisplayNextDoor() {
        var board = LaneBoard()
        let displays = [main, right]
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 600, height: 300),
            2: CGRect(x: 100, y: 0, width: 600, height: 300),
        ]
        arrange(&board, &frames, focused: 1, displays: displays)
        #expect(frames[1] == CGRect(x: 0, y: 25, width: 600, height: 775))
        // It would show 200 points of itself on the other display, so it waits in the far corner.
        #expect(frames[2]?.origin == CGPoint(x: -599, y: 799))
    }

    @Test func tuckedWindowPrefersTheSideItScrolledOff() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 400, height: 300)
        func tuck(_ side: Lane.Side, others: [CGRect]) -> CGPoint {
            LaneBoard.tuckOrigin(size: size, side: side, display: display, top: 25, others: others)
        }
        #expect(tuck(.left, others: []) == CGPoint(x: -399, y: 799))
        #expect(tuck(.right, others: []) == CGPoint(x: 999, y: 799))
        // A display below and to the right: the left corner shows nothing there.
        #expect(tuck(.right, others: [CGRect(x: 500, y: 800, width: 1000, height: 800)]) == CGPoint(x: -399, y: 799))
        // A wider display below both corners: it hangs off a side instead, clear of the one below.
        #expect(tuck(.right, others: [CGRect(x: -500, y: 800, width: 2000, height: 800)]) == CGPoint(x: 999, y: 25))
    }

    @Test func rowTakesTheWidthAnAppInsistsOn() {
        var board = LaneBoard()
        let frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 300, height: 300)]
        let snapshot = snapshot(frames, focused: 1)
        board.sync(snapshot)
        let moves = board.layout(snapshot)
        #expect(moves.map(\.id) == [1, 2])
        // The first window won't go narrower than 500.
        let shiftsTheRest = board.settle(1, at: CGRect(x: 0, y: 25, width: 500, height: 775))
        let secondShifts = board.settle(2, at: moves[1].frame)
        #expect(shiftsTheRest)
        #expect(!secondShifts)
        let after = self.snapshot([1: CGRect(x: 0, y: 25, width: 500, height: 775), 2: moves[1].frame], focused: 1)
        board.sync(after)
        let again = board.layout(after)
        #expect(again.first { $0.id == 2 }?.frame.minX == 500)
    }

    @Test func windowThatKeepsGoingBackIsLeftAlone() {
        var board = LaneBoard()
        let stuck = CGRect(x: 700, y: 300, width: 300, height: 300)
        var frames: [Int: CGRect] = [1: stuck, 2: CGRect(x: 0, y: 0, width: 300, height: 300)]
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var rounds = 0
        // The second window goes where it's sent; the first is back where it was every time.
        while !board.ignored.contains(1), rounds < 20 {
            let snapshot = snapshot(frames, focused: 2)
            board.sync(snapshot)
            for move in board.layout(snapshot, now: start.addingTimeInterval(Double(rounds) * 0.1)) {
                if move.id == 2 { frames[2] = move.frame }
                _ = board.settle(move.id, at: move.frame)
            }
            rounds += 1
        }
        #expect(board.ignored == [1])
        #expect(rounds <= 6)
        // It's no longer anything to put back: it's where its app wants it.
        #expect(board.restorations().map(\.id) == [2])
        #expect(board.lane(on: "A")?.ids == [2])
        // The gap it left is closed, and it stays left alone.
        #expect(frames[2] == CGRect(x: 0, y: 25, width: 300, height: 775))
        board.sync(snapshot(frames, focused: 2))
        #expect(board.lane(on: "A")?.ids == [2])
    }

    @Test func occasionalDragsAreNotMistakenForAStubbornApp() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300)]
        arrange(&board, &frames)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for drag in 1...8 {
            let dragged = snapshot([1: CGRect(x: 400, y: 300, width: 300, height: 775)])
            board.sync(dragged)
            let moves = board.layout(dragged, now: start.addingTimeInterval(Double(drag) * 5))
            #expect(moves.count == 1)
            for move in moves { _ = board.settle(move.id, at: move.frame) }
        }
        #expect(board.ignored.isEmpty)
    }

    @Test func focusStepsAlongTheRowAndStopsAtTheEnds() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 300, height: 300)]
        arrange(&board, &frames, focused: 1)
        let right = board.perform(.focus(1), in: snapshot(frames, focused: 1))
        #expect(right == 2)
        #expect(board.lane(on: "A")?.focus == 2)
        let pastTheEnd = board.perform(.focus(1), in: snapshot(frames, focused: 2))
        #expect(pastTheEnd == nil)
        let left = board.perform(.focus(-1), in: snapshot(frames, focused: 2))
        #expect(left == 1)
    }

    @Test func focusComesBackToTheRowFromAWindowOutsideIt() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 300, height: 300)]
        arrange(&board, &frames, focused: 2)
        let back = board.perform(.focus(1), in: snapshot(frames, focused: nil))
        #expect(back == 2)
        let moved = board.perform(.move(1), in: snapshot(frames, focused: nil))
        #expect(moved == nil)
        #expect(board.lane(on: "A")?.ids == [1, 2])
    }

    @Test func movingAndWidthsChangeTheFocusedWindow() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 300, height: 300)]
        arrange(&board, &frames, focused: 1)
        _ = board.perform(.move(1), in: snapshot(frames, focused: 1))
        #expect(board.lane(on: "A")?.ids == [2, 1])
        _ = board.perform(.cycleWidth, in: snapshot(frames, focused: 1))
        #expect(board.lane(on: "A")?.width(of: 1) == 333)
        arrange(&board, &frames, focused: 1)
        #expect(frames[1] == CGRect(x: 300, y: 25, width: 333, height: 775))
    }

    @Test func scrollingSlidesWindowsAlongTheRow() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 600, height: 300),
            2: CGRect(x: 100, y: 0, width: 600, height: 300),
            3: CGRect(x: 200, y: 0, width: 600, height: 300),
        ]
        arrange(&board, &frames, focused: 1)  // 1 at 0, 2 hangs over the right edge, 3 is out of view
        let snapshot = snapshot(frames, focused: 3)
        board.sync(snapshot)
        let slides = Dictionary(uniqueKeysWithValues: board.layout(snapshot).map { ($0.id, $0.slide) })
        // Scrolled 800 along. The first leaves to its place off the left, the last comes in from off the right.
        #expect(slides[1] == LaneMove.Slide(from: CGPoint(x: 0, y: 25), to: CGPoint(x: -800, y: 25)))
        #expect(slides[2] == LaneMove.Slide(from: CGPoint(x: 600, y: 25), to: CGPoint(x: -200, y: 25)))
        #expect(slides[3] == LaneMove.Slide(from: CGPoint(x: 1200, y: 25), to: CGPoint(x: 400, y: 25)))
    }

    @Test func newWindowSlidesFromWhereItOpened() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300)]
        arrange(&board, &frames, focused: 1)
        frames[2] = CGRect(x: 500, y: 200, width: 300, height: 300)
        let snapshot = snapshot(frames, focused: 2)
        board.sync(snapshot)
        let moves = board.layout(snapshot)
        #expect(moves.map(\.id) == [2])
        #expect(moves[0].slide == LaneMove.Slide(from: CGPoint(x: 500, y: 200), to: CGPoint(x: 300, y: 25)))
    }

    @Test func nothingSlidesAcrossADisplayNextDoor() {
        var board = LaneBoard()
        let displays = [main, right]
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 600, height: 300),
            2: CGRect(x: 100, y: 0, width: 600, height: 300),
        ]
        arrange(&board, &frames, focused: 1, displays: displays)
        let snapshot = snapshot(frames, focused: 2, displays: displays)
        board.sync(snapshot)
        let slides = Dictionary(uniqueKeysWithValues: board.layout(snapshot).map { ($0.id, $0.slide) })
        // The second window was waiting in a corner, and would cross the other display to slide in.
        #expect(slides[2] == .some(nil))
        // The first slides out to the left, where there's no display.
        #expect(slides[1] == LaneMove.Slide(from: CGPoint(x: 0, y: 25), to: CGPoint(x: -200, y: 25)))
    }

    @Test func stackedWindowsShareTheHeight() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 400, height: 300),
            2: CGRect(x: 450, y: 0, width: 300, height: 300),
            3: CGRect(x: 800, y: 0, width: 300, height: 300),
        ]
        arrange(&board, &frames, focused: 2)
        _ = board.perform(.stack, in: snapshot(frames, focused: 2))
        arrange(&board, &frames, focused: 2)
        #expect(frames[1] == CGRect(x: 0, y: 25, width: 400, height: 387))
        #expect(frames[2] == CGRect(x: 0, y: 412, width: 400, height: 388))
        #expect(frames[3] == CGRect(x: 400, y: 25, width: 300, height: 775))
        let above = board.perform(.focusStack(-1), in: snapshot(frames, focused: 2))
        #expect(above == 1)
        _ = board.perform(.unstack, in: snapshot(frames, focused: 1))
        arrange(&board, &frames, focused: 1)
        #expect(board.lane(on: "A")?.columns.map(\.ids) == [[2], [1], [3]])
        #expect(frames[2] == CGRect(x: 0, y: 25, width: 400, height: 775))
    }

    @Test func draggingAWindowAlongTheRowReordersIt() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 350, y: 0, width: 300, height: 300),
            3: CGRect(x: 700, y: 0, width: 300, height: 300),
        ]
        arrange(&board, &frames, focused: 1)
        // The first window is let go past the middle of the last.
        frames[1] = CGRect(x: 650, y: 120, width: 300, height: 775)
        arrange(&board, &frames, focused: 1, afterDrag: true)
        #expect(board.lane(on: "A")?.ids == [2, 3, 1])
        #expect(frames[2]?.minX == 0)
        #expect(frames[1] == CGRect(x: 600, y: 25, width: 300, height: 775))
    }

    @Test func minimizedWindowComesBackWhereItWas() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 350, y: 0, width: 300, height: 300),
            3: CGRect(x: 700, y: 0, width: 300, height: 300),
        ]
        arrange(&board, &frames, focused: 3)
        let minimized = frames.removeValue(forKey: 1)
        arrange(&board, &frames, focused: 3)
        #expect(board.lane(on: "A")?.ids == [2, 3])
        frames[1] = minimized
        arrange(&board, &frames, focused: 3)
        #expect(board.lane(on: "A")?.ids == [1, 2, 3])
        #expect(frames[1]?.minX == 0)
    }

    @Test func hiddenAppsWindowsComeBackInOrder() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 200, height: 300),
            2: CGRect(x: 250, y: 0, width: 200, height: 300),
            3: CGRect(x: 500, y: 0, width: 200, height: 300),
            4: CGRect(x: 750, y: 0, width: 200, height: 300),
        ]
        arrange(&board, &frames, focused: 4)
        _ = board.perform(.stack, in: snapshot(frames, focused: 4))  // [1], [2], [3, 4]
        arrange(&board, &frames, focused: 4)
        // An app with the first, second and last windows is hidden, then shown again.
        let hidden = [1, 2, 4].map { ($0, frames.removeValue(forKey: $0)!) }
        arrange(&board, &frames, focused: 3)
        #expect(board.lane(on: "A")?.ids == [3])
        for (id, frame) in hidden { frames[id] = frame }
        arrange(&board, &frames, focused: 3)
        #expect(board.lane(on: "A")?.columns.map(\.ids) == [[1], [2], [3, 4]])
    }

    @Test func minimizedWindowsAreRestoredToo() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 10, y: 40, width: 300, height: 300), 2: CGRect(x: 400, y: 60, width: 320, height: 240)]
        let before = frames
        arrange(&board, &frames, focused: 1)
        frames[2] = nil  // minimized: out of its row, but still to be put back
        arrange(&board, &frames, focused: 1)
        #expect(board.lane(on: "A")?.ids == [1])
        #expect(Dictionary(uniqueKeysWithValues: board.restorations().map { ($0.id, $0.frame) }) == before)
    }

    @Test func releasedWindowGoesBackWhereItWas() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 10, y: 40, width: 300, height: 300), 2: CGRect(x: 400, y: 60, width: 320, height: 240)]
        arrange(&board, &frames, focused: 1)
        let move = board.release(2)
        #expect(move == LaneMove(id: 2, frame: CGRect(x: 400, y: 60, width: 320, height: 240), resizes: true))
        #expect(board.lane(on: "A")?.ids == [1])
        #expect(board.restorations().map(\.id) == [1])
        let again = board.release(2)
        #expect(again == nil)
    }

    @Test func seatFromAnotherRowIsNotUsed() {
        var board = LaneBoard()
        var first: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 300, height: 300)]
        arrange(&board, &first, focused: 2)
        // The first window is sent to another Space, where it then shows up beside others.
        var second: [Int: CGRect] = [3: CGRect(x: 0, y: 0, width: 400, height: 300), 4: CGRect(x: 500, y: 0, width: 400, height: 300)]
        let moved = first.removeValue(forKey: 1)
        arrange(&board, &first, focused: 2)
        arrange(&board, &second, focused: 3)
        second[1] = moved
        arrange(&board, &second, focused: 3)
        // Beside the focused window, not at the front as it was in its old row.
        #expect(board.lane(on: "A")?.ids == [3, 1, 4])
    }

    @Test func repeatedDraggingIsNotTakenForAStubbornApp() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 300, height: 300)]
        arrange(&board, &frames)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for drag in 1...8 {
            let dragged = snapshot([1: CGRect(x: 400, y: 300, width: 300, height: 775)])
            board.sync(dragged)
            // Quick drags, one after another, each with the mouse.
            for move in board.layout(dragged, afterDrag: true, now: start.addingTimeInterval(Double(drag) * 0.2)) {
                _ = board.settle(move.id, at: move.frame)
            }
        }
        #expect(board.ignored.isEmpty)
        #expect(board.lane(on: "A")?.ids == [1])
    }

    @Test func windowOnNoDisplayStaysInItsRow() {
        var board = LaneBoard()
        let displays = [main, right]
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 1200, y: 0, width: 300, height: 300),
            3: CGRect(x: 1600, y: 0, width: 300, height: 300),
        ]
        arrange(&board, &frames, focused: 1, displays: displays)
        // Its app parks it somewhere off every display.
        frames[3] = CGRect(x: 5000, y: 5000, width: 300, height: 775)
        arrange(&board, &frames, focused: 1, displays: displays)
        #expect(board.lane(on: "B")?.ids == [2, 3])
        #expect(board.lane(on: "A")?.ids == [1])
    }

    @Test func windowMovedWithoutTheMouseIsNotReordered() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 350, y: 0, width: 300, height: 300),
            3: CGRect(x: 700, y: 0, width: 300, height: 300),
        ]
        arrange(&board, &frames, focused: 1)
        _ = board.perform(.stack, in: snapshot(frames, focused: 2))  // [1, 2], [3]
        arrange(&board, &frames, focused: 2)
        // Its app moves the stacked window across the screen by itself.
        frames[2]?.origin.x = 650
        arrange(&board, &frames, focused: 2)
        #expect(board.lane(on: "A")?.columns.map(\.ids) == [[1, 2], [3]])
        #expect(frames[2]?.minX == 0)
    }

    @Test func onlyAWindowUnderThePointerThatWentSomeWayCountsAsDragged() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 350, y: 0, width: 300, height: 300),
            3: CGRect(x: 700, y: 0, width: 300, height: 300),
        ]
        arrange(&board, &frames, focused: 1)
        func look(pointer: CGPoint) {
            var snapshot = snapshot(frames, focused: 1)
            snapshot.pointer = pointer
            board.sync(snapshot, afterDrag: true)
            for move in board.layout(snapshot, afterDrag: true) {
                frames[move.id] = move.frame
                _ = board.settle(move.id, at: move.frame)
            }
        }
        // The mouse is in use elsewhere when the first window's app moves it across the screen.
        frames[1]?.origin.x = 650
        look(pointer: CGPoint(x: 100, y: 700))
        #expect(board.lane(on: "A")?.ids == [1, 2, 3])
        // A click on it, and its app shifts it a few points.
        frames[1]?.origin.x = 12
        look(pointer: CGPoint(x: 100, y: 100))
        #expect(board.lane(on: "A")?.ids == [1, 2, 3])
        // Dragged by its title bar past the last window.
        frames[1]?.origin.x = 650
        look(pointer: CGPoint(x: 800, y: 40))
        #expect(board.lane(on: "A")?.ids == [2, 3, 1])
    }

    @Test func silentAppsAreLeftAloneForLongerEachTime() {
        #expect(LiveLaneWindows.wait(afterSilences: 1) == 1)
        #expect(LiveLaneWindows.wait(afterSilences: 2) == 2)
        #expect(LiveLaneWindows.wait(afterSilences: 4) == 8)
        #expect(LiveLaneWindows.wait(afterSilences: 12) == 30)
    }

    @Test func windowsFromAnUnpluggedDisplayAreRestoredOntoOneThatIsLeft() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 100, y: 100, width: 300, height: 300),
            2: CGRect(x: 1500, y: 200, width: 400, height: 1200),
        ]
        arrange(&board, &frames, focused: 1, displays: [main, right])
        frames[2] = CGRect(x: 200, y: 25, width: 400, height: 775)
        arrange(&board, &frames, focused: 1)
        let back = Dictionary(uniqueKeysWithValues: board.restorations().map { ($0.id, $0.frame) })
        #expect(back[1] == CGRect(x: 100, y: 100, width: 300, height: 300))
        // Onto the display that's left, as near where it was as fits, and no taller than it.
        #expect(back[2] == CGRect(x: 600, y: 25, width: 400, height: 775))
    }

    @Test func stackedWindowsThatCantShareAWidthAreParted() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 500, height: 300), 2: CGRect(x: 550, y: 0, width: 400, height: 300)]
        arrange(&board, &frames, focused: 2)
        _ = board.perform(.stack, in: snapshot(frames, focused: 2))  // [1, 2] at the first's width, 500
        // The first goes no wider than 500 and the second no narrower than 600.
        func limited(_ move: LaneMove) -> CGRect {
            var frame = move.frame
            frame.size.width = move.id == 1 ? min(frame.width, 500) : max(frame.width, 600)
            return frame
        }
        var rounds = 0
        var moved = true
        while moved, rounds < 12 {
            let snapshot = snapshot(frames, focused: 2)
            board.sync(snapshot)
            let moves = board.layout(snapshot)
            for move in moves {
                frames[move.id] = limited(move)
                board.settle(move.id, at: limited(move))
            }
            moved = !moves.isEmpty
            rounds += 1
        }
        #expect(rounds < 12)
        // The one that couldn't follow is moved out to the right.
        #expect(board.lane(on: "A")?.columns.map(\.ids) == [[2], [1]])
        #expect(frames[1]?.width == 500)
        #expect(frames[2]?.width == 600)
    }

    @Test func refusedHeightIsNotAskedForAgainOnEveryMove() {
        var board = LaneBoard()
        let frames: [Int: CGRect] = [1: CGRect(x: 100, y: 0, width: 300, height: 300)]
        let first = snapshot(frames, focused: 1)
        board.sync(first)
        let moves = board.layout(first)
        #expect(moves.first?.resizes == true)
        // A terminal takes a height a few points short, in whole lines.
        let took = CGRect(x: 0, y: 25, width: 300, height: 770)
        board.settle(1, at: took)
        _ = board.scroll(on: "A", by: 0)
        var next = self.snapshot([1: took, 2: CGRect(x: 0, y: 0, width: 900, height: 300)], focused: 2)
        next.pointer = nil
        board.sync(next)
        // A second window joins and the first moves along; it isn't resized again.
        let again = board.layout(next)
        #expect(again.first { $0.id == 1 }.map(\.resizes) != true)
    }

    @Test func hiddenWindowBelongsToTheDisplayItIsTuckedAt() {
        let left = LaneDisplay(
            key: "L", frame: CGRect(x: -1000, y: 0, width: 1000, height: 800), area: CGRect(x: -1000, y: 25, width: 1000, height: 775))
        let displays = [left, main, right]
        // Tucked at the middle display's bottom right, nearly all of it lies over the display on the right.
        let tucked = CGRect(x: 999, y: 799, width: 600, height: 300)
        #expect(LaneBoard.display(holding: tucked, in: displays)?.key == "B")
        #expect(LaneBoard.home(of: tucked, in: displays)?.key == "A")
        // A window in the open belongs where most of it is.
        #expect(LaneBoard.home(of: CGRect(x: 1100, y: 100, width: 600, height: 300), in: displays)?.key == "B")
    }

    @Test func restoringSendsEveryWindowBack() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [1: CGRect(x: 10, y: 40, width: 300, height: 300), 2: CGRect(x: 400, y: 60, width: 320, height: 240)]
        let before = frames
        arrange(&board, &frames, focused: 1)
        let moves = board.restorations()
        #expect(Dictionary(uniqueKeysWithValues: moves.map { ($0.id, $0.frame) }) == before)
        #expect(moves.allSatisfy { $0.resizes })
    }

    @Test func disconnectedDisplaysWindowsJoinTheOneLeft() {
        var board = LaneBoard()
        var frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 1200, y: 0, width: 300, height: 300),
        ]
        arrange(&board, &frames, focused: 1, displays: [main, right])
        // macOS moves the second display's window onto the first.
        frames[2] = CGRect(x: 200, y: 25, width: 300, height: 775)
        arrange(&board, &frames, focused: 1)
        #expect(board.lanes.map(\.ids) == [[1, 2]])
        #expect(board.originals[2] == CGRect(x: 1200, y: 0, width: 300, height: 300))
    }
}

/// Windows that go where they're sent, except that some have a narrowest width.
final class FakeLaneWindows: LaneWindowSystem {
    var onChange: () -> Void = {}
    var onClose: (Int) -> Void = { _ in }

    var displays = [
        LaneDisplay(key: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), area: CGRect(x: 0, y: 25, width: 1000, height: 775))
    ]
    var frames: [Int: CGRect] = [:]
    var focused: Int?
    var narrowest: [Int: CGFloat] = [:]
    /// Widths that windows report while still on their way to the one asked for.
    var lag: [Int: CGFloat] = [:]
    /// How far short of where they're sent windows stop, for apps that animate moves.
    var short: [Int: CGFloat] = [:]
    /// Windows whose app isn't answering, and so can't be moved.
    var stuck: Set<Int> = []
    /// How many times the windows were looked at.
    private(set) var looks = 0
    private(set) var floating: Set<Int> = []
    private(set) var isStarted = false
    private(set) var raised: [Int] = []
    /// Every place each window was put, in order.
    private(set) var trail: [Int: [CGPoint]] = [:]

    func start() { isStarted = true }
    func stop() { isStarted = false }

    func snapshot() -> LaneSnapshot {
        looks += 1
        let windows = frames.filter { !floating.contains($0.key) }.sorted { $0.key < $1.key }
        return LaneSnapshot(
            displays: displays, windows: windows.map { LaneSnapshot.Window(id: $0.key, frame: $0.value) },
            focused: focused.flatMap { floating.contains($0) ? nil : $0 }, mainDisplay: "A")
    }

    func apply(_ move: LaneMove) -> CGRect? {
        guard let current = frames[move.id], !stuck.contains(move.id) else { return nil }
        var frame = move.resizes ? move.frame : CGRect(origin: move.frame.origin, size: current.size)
        frame.size.width = max(frame.width, narrowest[move.id] ?? 0)
        if let short = short[move.id] { frame.origin.x += short }
        frames[move.id] = frame
        trail[move.id, default: []].append(frame.origin)
        if move.resizes, let width = lag[move.id] { frame.size.width = width }
        return frame
    }

    func slide(_ id: Int, to origin: CGPoint) {
        guard let current = frames[id] else { return }
        frames[id] = CGRect(origin: origin, size: current.size)
        trail[id, default: []].append(origin)
    }

    func owner(of id: Int) -> pid_t? {
        frames[id] == nil ? nil : 100 + pid_t(id)
    }

    func isHeldUp(_ id: Int) -> Bool {
        stuck.contains(id)
    }

    var isReady = true
    private(set) var askedAgain = 0
    var askAgainAt: Date?

    func frame(of id: Int) -> CGRect? {
        stuck.contains(id) ? nil : frames[id]
    }

    func askAgain() {
        askedAgain += 1
    }

    func focus(_ id: Int) {
        raised.append(id)
        focused = id
    }

    func toggleFloating() -> Int? {
        guard let focused else { return nil }
        if floating.remove(focused) != nil { return nil }
        floating.insert(focused)
        return focused
    }
}

struct LanesControllerTests {
    private let store = TestDefaults()
    private let windows = FakeLaneWindows()

    private func makeController() -> LanesController {
        LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { false },
            pointerDisplay: { "A" }, startTime: { _ in Date(timeIntervalSinceReferenceDate: 0) }, slideDuration: .zero)
    }

    private func threeWindows() -> [Int: CGRect] {
        [
            1: CGRect(x: 20, y: 40, width: 600, height: 300),
            2: CGRect(x: 300, y: 80, width: 600, height: 400),
            3: CGRect(x: 500, y: 120, width: 600, height: 500),
        ]
    }

    @Test func startsOffAndTouchesNothing() {
        windows.frames = threeWindows()
        let lanes = makeController()
        #expect(!lanes.isRunning)
        lanes.refresh()
        lanes.perform(.focusRight)
        #expect(windows.frames == threeWindows())
        #expect(!windows.isStarted)
    }

    @Test func startingArrangesAndStoppingPutsWindowsBack() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        #expect(lanes.isRunning)
        #expect(windows.isStarted)
        #expect(windows.frames[1] == CGRect(x: 0, y: 25, width: 600, height: 775))
        #expect(windows.frames[2] == CGRect(x: 600, y: 25, width: 600, height: 775))
        lanes.stop()
        #expect(!lanes.isRunning)
        #expect(!windows.isStarted)
        #expect(windows.frames == threeWindows())
    }

    @Test func focusShortcutBringsTheNeighbourForwardAndScrollsToIt() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        lanes.perform(.focusRight)
        #expect(windows.raised == [2])
        // Scrolled 200 along, so the second window is wholly in view.
        #expect(windows.frames[1]?.minX == -200)
        #expect(windows.frames[2] == CGRect(x: 400, y: 25, width: 600, height: 775))
        lanes.perform(.focusRight)
        lanes.perform(.focusRight)  // already at the end
        #expect(windows.raised == [2, 3])
    }

    @Test func rowKeepsToTheWindowJustBroughtForwardUntilItHasTheKeyboard() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        lanes.perform(.focusRight)
        // macOS still reports the old window for a moment; the row doesn't scroll back to it.
        windows.focused = 1
        lanes.refresh()
        #expect(windows.frames[2]?.minX == 400)
    }

    @Test func moveAndWidthShortcutsRearrangeTheRow() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        lanes.perform(.moveRight)
        // Swapped with the second window, and scrolled 200 along to stay wholly in view.
        #expect(windows.frames[2]?.minX == -200)
        #expect(windows.frames[1]?.minX == 400)
        lanes.perform(.cycleWidth)  // 600 is past the half, so two thirds comes next
        #expect(windows.frames[1]?.width == 667)
        #expect(windows.raised.isEmpty)
    }

    @Test func rowMakesRoomForAWindowThatWontShrink() {
        windows.frames = [1: CGRect(x: 0, y: 0, width: 500, height: 300), 2: CGRect(x: 600, y: 0, width: 300, height: 300)]
        windows.narrowest = [1: 500]
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        lanes.perform(.cycleWidth)  // asks for two thirds, 667
        lanes.perform(.cycleWidth)  // full width
        lanes.perform(.cycleWidth)  // back to a third, 333, which it refuses
        // Still that width at the next look, it's the one the row goes by.
        lanes.confirmPlaces()
        #expect(windows.frames[1]?.width == 500)
        #expect(windows.frames[2]?.minX == 500)
    }

    @Test func windowLeftOutGoesBackWhereItWasAndRejoinsWhenLetIn() {
        windows.frames = threeWindows()
        windows.focused = 2
        let lanes = makeController()
        lanes.start()
        lanes.perform(.toggleFloating)
        #expect(windows.frames[2] == threeWindows()[2])
        #expect(windows.frames[3]?.minX == 600)
        // Moved by hand while left out, then let back in.
        let moved = CGRect(x: 120, y: 90, width: 500, height: 400)
        windows.frames[2] = moved
        lanes.perform(.toggleFloating)
        #expect(windows.frames[2]?.height == 775)
        lanes.stop()
        #expect(windows.frames[1] == threeWindows()[1])
        #expect(windows.frames[2] == moved)
    }

    @Test func minimizedWindowIsPutBackWhenLanesStops() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        // The third window is out of view in its corner when it's minimized.
        let tucked = windows.frames.removeValue(forKey: 3)
        lanes.refresh()
        windows.frames[3] = tucked
        lanes.stop()
        #expect(windows.frames == threeWindows())
    }

    @Test func wheelStepsAlongTheRowUnderThePointer() {
        let second = LaneDisplay(
            key: "B", frame: CGRect(x: 0, y: 800, width: 1000, height: 800), area: CGRect(x: 0, y: 800, width: 1000, height: 800))
        windows.displays.append(second)
        windows.frames = [
            1: CGRect(x: 0, y: 100, width: 400, height: 300),
            2: CGRect(x: 500, y: 100, width: 400, height: 300),
            3: CGRect(x: 0, y: 900, width: 400, height: 300),
            4: CGRect(x: 500, y: 900, width: 400, height: 300),
        ]
        windows.focused = 1  // the keyboard is on the first display
        let lanes = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { false }, pointerDisplay: { "B" }, slideDuration: .zero)
        lanes.start()
        lanes.stepFocus(by: 1)
        #expect(windows.raised == [4])
        lanes.stepFocus(by: 1)  // the end of that row
        lanes.stepFocus(by: -1)
        #expect(windows.raised == [4, 3])
    }

    @Test func stoppingMidSwipeOnlyPutsWindowsBack() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        lanes.scroll(by: 500)
        lanes.stop()
        #expect(windows.frames == threeWindows())
        // No window was brought forward on the way out.
        #expect(windows.raised.isEmpty)
    }

    @Test func recoveryOutlastsAStopBeforeTheWindowIsSeen() {
        windows.frames = threeWindows()
        windows.focused = 1
        makeController().start()  // went away with windows arranged
        let arranged = windows.frames
        // The next run only ever sees the first window: the others are on a Space not shown.
        windows.frames = [1: arranged[1]!]
        let second = makeController()
        second.start()
        second.stop()
        #expect(windows.frames[1] == threeWindows()[1])
        // A later run comes across the rest and puts them back too.
        windows.frames = arranged.filter { $0.key != 1 }
        let third = makeController()
        third.start()
        third.stop()
        #expect(windows.frames[2] == threeWindows()[2])
        #expect(windows.frames[3] == threeWindows()[3])
        #expect(store.defaults.data(forKey: LanesController.placesKey) == nil)
    }

    @Test func placesOfAppsThatQuitAreDropped() {
        windows.frames = threeWindows()
        windows.focused = 1
        makeController().start()
        let relaunched = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { false }, startTime: { _ in nil }, slideDuration: .zero)
        let arranged = windows.frames
        relaunched.start()
        relaunched.stop()
        // Nothing was recovered, so the windows count as having started where they were found.
        #expect(windows.frames == arranged)
    }

    @Test func windowsLeftArrangedByACrashAreStillPutBack() {
        windows.frames = threeWindows()
        windows.focused = 1
        makeController().start()  // never stopped: the app went away with windows arranged
        #expect(windows.frames != threeWindows())
        let relaunched = makeController()
        relaunched.start()
        relaunched.stop()
        #expect(windows.frames == threeWindows())
        // A clean stop leaves nothing to recover.
        #expect(store.defaults.data(forKey: LanesController.placesKey) == nil)
    }

    @Test func closedWindowIsForgottenAndTheRowCloses() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        windows.frames[1] = nil
        windows.onClose(1)
        lanes.refresh()
        #expect(windows.frames[2]?.minX == 0)
        #expect(windows.frames[3]?.minX == 600)
    }

    @Test func swipeScrollsTheRowAndSettlesOnTheWindowLeftInView() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        lanes.scroll(by: 150)
        #expect(windows.frames[1]?.minX == -150)
        #expect(windows.frames[2]?.minX == 450)
        lanes.scroll(by: 350)
        // The third window has come in from its corner.
        #expect(windows.frames[2]?.minX == 100)
        #expect(windows.frames[3]?.minX == 700)
        lanes.endScroll()
        // The second window has the most in view: it takes the keyboard and the row settles on it.
        #expect(windows.raised == [2])
        #expect(windows.frames[2] == CGRect(x: 100, y: 25, width: 600, height: 775))
    }

    @Test func shortSwipeLeavesTheRowWhereItIs() {
        windows.frames = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 900, height: 300)]
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        lanes.scroll(by: 100)  // the row is 1200 long on a display 1000 wide
        lanes.scroll(by: 500)  // stops at the end
        #expect(windows.frames[2]?.minX == 100)
        lanes.scroll(by: -200)
        lanes.endScroll()
        // The focused window is wholly in view again, so nothing else happens.
        #expect(windows.frames[1]?.minX == 0)
        #expect(windows.raised.isEmpty)
    }

    @Test func widthStillOnItsWayIsNotTakenForARefusal() {
        windows.frames = [1: CGRect(x: 0, y: 0, width: 500, height: 300), 2: CGRect(x: 600, y: 0, width: 300, height: 300)]
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        // The app animates: asked for two thirds, it reads back part of the way there.
        windows.lag = [1: 580]
        lanes.perform(.cycleWidth)
        windows.lag = [:]
        #expect(windows.frames[2]?.minX == 667)
        // Looked at while still growing, its width of the moment isn't taken for its own.
        windows.frames[1]?.size.width = 620
        lanes.refresh()
        #expect(windows.frames[2]?.minX == 667)
        lanes.confirmPlaces()
        windows.frames[1]?.size.width = 667
        lanes.confirmPlaces()
        lanes.confirmPlaces()  // the same twice running: it has stopped, where it was sent
        #expect(windows.frames[1]?.width == 667)
        #expect(windows.frames[2]?.minX == 667)
    }

    @Test func nothingIsArrangedUntilAccessibilityIsAllowed() {
        windows.frames = threeWindows()
        windows.focused = 1
        windows.isReady = false
        let lanes = makeController()
        lanes.start()
        lanes.perform(.cycleWidth)
        #expect(windows.frames == threeWindows())
        #expect(windows.looks == 0)
        windows.isReady = true
        lanes.refresh()
        #expect(windows.frames[1] == CGRect(x: 0, y: 25, width: 600, height: 775))
        lanes.stop()
    }

    @Test func stoppingGivesSilentAppsAnotherChance() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        let before = windows.askedAgain
        lanes.stop()
        #expect(windows.askedAgain == before + 1)
        #expect(windows.frames == threeWindows())
    }

    @Test func dragJustBeforeASwipeStillCounts() async {
        windows.frames = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 350, y: 0, width: 300, height: 300),
            3: CGRect(x: 700, y: 0, width: 300, height: 300),
        ]
        windows.focused = 1
        var mouseDown = false
        let lanes = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { mouseDown }, pointerDisplay: { "A" }, slideDuration: .zero)
        lanes.start()
        // Dragged past the last window and let go, then swiped at once.
        mouseDown = true
        windows.frames[1]?.origin.x = 650
        windows.onChange()
        mouseDown = false
        lanes.scroll(by: 1)
        lanes.endScroll()
        #expect(windows.frames[2]?.minX == 0)
        #expect(windows.frames[1]?.minX == 600)
        lanes.stop()
    }

    @Test func windowOfASilentAppIsSentAgainOnceItAnswers() {
        windows.frames = threeWindows()
        windows.focused = 1
        windows.stuck = [2]
        let lanes = makeController()
        lanes.start()
        #expect(windows.frames[2] == threeWindows()[2])
        // Nothing else changes; its app answers, and at the next look it's put in its place.
        windows.stuck = []
        lanes.refresh()
        #expect(windows.frames[2] == CGRect(x: 600, y: 25, width: 600, height: 775))
        lanes.stop()
    }

    @Test func silentAppIsAskedAgainWhenDueWithoutAnythingElseChanging() async {
        windows.frames = threeWindows()
        windows.focused = 1
        windows.stuck = [2]
        windows.askAgainAt = Date.now.addingTimeInterval(0.1)
        let lanes = makeController()
        lanes.start()
        windows.stuck = []
        windows.askAgainAt = nil
        for _ in 0..<300 where windows.frames[2]?.minX != 600 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(windows.frames[2]?.minX == 600)
        lanes.stop()
    }

    @Test func pausingASwipeThatSaysWhenItEndsDoesNotEndIt() async {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        lanes.scroll(by: 500, saysWhenItEnds: true)
        try? await Task.sleep(for: .milliseconds(400))  // fingers resting
        #expect(windows.raised.isEmpty)
        #expect(windows.frames[2]?.minX == 100)
        lanes.scroll(by: 100, saysWhenItEnds: true)
        #expect(windows.frames[2]?.minX == 0)
        lanes.swipeLifted()
        for _ in 0..<300 where windows.raised.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(windows.raised == [2])
        lanes.stop()
    }

    @Test func secondWidthChangeIsNotUndoneByTheFirstStillInDoubt() {
        windows.frames = [1: CGRect(x: 0, y: 0, width: 300, height: 300), 2: CGRect(x: 400, y: 0, width: 300, height: 300)]
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        windows.lag = [1: 320]
        lanes.perform(.cycleWidth)  // a third, 333: read back short, so in doubt
        windows.lag = [:]
        lanes.perform(.cycleWidth)  // a half, 500: taken at once
        lanes.refresh()
        #expect(windows.frames[1]?.width == 500)
        #expect(windows.frames[2]?.minX == 500)
        lanes.stop()
    }

    @Test func windowStillSlidingIntoPlaceIsNotTakenForAStubbornOne() {
        windows.frames = threeWindows()
        windows.focused = 1
        // Its app animates moves: sent to its place, the second window is found short of it.
        windows.short = [2: 40]
        let lanes = makeController()
        lanes.start()
        windows.short = [:]
        #expect(windows.frames[2]?.minX == 640)
        let sent = windows.trail[2]?.count
        // Each look on its way finds it a little nearer; it isn't sent again, or given up on.
        for _ in 1...8 {
            windows.frames[2]?.origin.x -= 4
            lanes.refresh()
        }
        #expect(windows.trail[2]?.count == sent)
        windows.frames[2]?.origin.x = 600
        lanes.confirmPlaces()
        lanes.confirmPlaces()
        // It's still in the row: scrolling along moves it with the rest.
        lanes.perform(.focusRight)
        #expect(windows.frames[2]?.minX == 400)
        lanes.stop()
        #expect(windows.frames == threeWindows())
    }

    @Test func placesFromBeforeARestartAreDropped() {
        windows.frames = threeWindows()
        windows.focused = 1
        makeController().start()
        let arranged = windows.frames
        // The same process numbers, but the processes started at another time.
        let later = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { false }, startTime: { _ in Date(timeIntervalSinceReferenceDate: 5000) }, slideDuration: .zero)
        later.start()
        later.stop()
        #expect(windows.frames == arranged)
    }

    @Test func windowThatDidNotLandWhereASwipePutItIsPutRightAfterwards() {
        windows.frames = [
            1: CGRect(x: 0, y: 0, width: 300, height: 300),
            2: CGRect(x: 310, y: 0, width: 300, height: 300),
            3: CGRect(x: 620, y: 0, width: 300, height: 300),
            4: CGRect(x: 930, y: 0, width: 300, height: 300),
        ]
        windows.focused = 2
        let lanes = makeController()
        lanes.start()
        lanes.scroll(by: 100)
        #expect(windows.frames[3]?.minX == 500)
        // Its app left the third window short of where it was sent.
        windows.frames[3]?.origin.x = 560
        lanes.endScroll()
        // The focused window is still wholly in view, so the row stays; only that window is put right.
        #expect(windows.frames[2]?.minX == 200)
        #expect(windows.frames[3]?.minX == 500)
        #expect(windows.raised.isEmpty)
        lanes.stop()
    }

    @Test func confirmingAPlaceWaitsForADragToEnd() {
        windows.frames = [1: CGRect(x: 0, y: 0, width: 500, height: 300), 2: CGRect(x: 600, y: 0, width: 300, height: 300)]
        windows.narrowest = [1: 500]
        windows.focused = 1
        var mouseDown = false
        let lanes = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { mouseDown }, slideDuration: .zero)
        lanes.start()
        lanes.perform(.cycleWidth)
        lanes.perform(.cycleWidth)
        lanes.perform(.cycleWidth)  // a third, which it refuses: in doubt
        mouseDown = true
        let looks = windows.looks
        lanes.confirmPlaces()
        // Nothing is looked at or moved while the button is down.
        #expect(windows.looks == looks)
        lanes.stop()
    }

    @Test func rowsOutlastADisplayGoneForAMoment() {
        let second = LaneDisplay(
            key: "B", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), area: CGRect(x: 1000, y: 25, width: 1000, height: 775))
        windows.displays.append(second)
        windows.frames = [
            1: CGRect(x: 0, y: 100, width: 400, height: 300),
            2: CGRect(x: 1500, y: 100, width: 400, height: 300),
            3: CGRect(x: 1100, y: 100, width: 300, height: 300),
        ]
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        let arranged = windows.frames
        // The second display drops out, as on waking, and macOS shoves its windows onto the first.
        windows.displays.removeLast()
        windows.frames[2] = CGRect(x: 100, y: 100, width: 400, height: 775)
        windows.frames[3] = CGRect(x: 200, y: 100, width: 300, height: 775)
        lanes.refresh()
        lanes.perform(.cycleWidth)
        #expect(windows.frames[2] == CGRect(x: 100, y: 100, width: 400, height: 775))
        // It's back: its row is as it was, in the same order.
        windows.displays.append(second)
        windows.frames[2] = arranged[2]
        windows.frames[3] = arranged[3]
        lanes.refresh()
        #expect(windows.frames == arranged)
        lanes.stop()
    }

    @Test func displayGoneForGoodHasItsWindowsJoinTheOneLeft() {
        let second = LaneDisplay(
            key: "B", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), area: CGRect(x: 1000, y: 25, width: 1000, height: 775))
        windows.displays.append(second)
        windows.frames = [1: CGRect(x: 0, y: 100, width: 400, height: 300), 2: CGRect(x: 1500, y: 100, width: 400, height: 300)]
        windows.focused = 1
        let lanes = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { false }, slideDuration: .zero, displayGrace: 0)
        lanes.start()
        windows.displays.removeLast()
        windows.frames[2] = CGRect(x: 100, y: 100, width: 400, height: 775)
        lanes.refresh()
        #expect(windows.frames[2] == CGRect(x: 400, y: 25, width: 400, height: 775))
        lanes.stop()
    }

    @Test func windowThatCantBeMovedIsNotLeftOut() {
        windows.frames = threeWindows()
        windows.focused = 2
        let lanes = makeController()
        lanes.start()
        let placed = windows.frames[2]
        windows.stuck = [2]
        lanes.perform(.toggleFloating)
        // Still in the row: once its app answers it moves along with the rest.
        windows.stuck = []
        lanes.perform(.focusRight)
        #expect(windows.frames[2] != placed)
        #expect(windows.frames[2]?.height == 775)
        // And it's still put back at the end.
        lanes.stop()
        #expect(windows.frames == threeWindows())
    }

    @Test func windowThatHasGoneIsNotKeptToPutBack() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        windows.frames[3] = nil  // closed without a word
        lanes.stop()
        #expect(store.defaults.data(forKey: LanesController.placesKey) == nil)
    }

    @Test func swipeWhereThereIsNoRowLooksAtTheWindowsOnce() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { false }, pointerDisplay: { "B" }, slideDuration: .zero)
        lanes.start()
        let looks = windows.looks
        for _ in 0..<20 { lanes.scroll(by: 30) }
        #expect(windows.looks == looks + 1)
        lanes.endScroll()
        lanes.scroll(by: 30)  // a new swipe looks again
        #expect(windows.looks == looks + 2)
    }

    @Test func windowOfAnAppNotAnsweringIsKeptToPutBackLater() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = makeController()
        lanes.start()
        let arranged = windows.frames[3]
        windows.stuck = [3]
        lanes.stop()
        #expect(windows.frames[1] == threeWindows()[1])
        #expect(windows.frames[3] == arranged)
        // Once its app answers again, the next run finds it and puts it back.
        windows.stuck = []
        let next = makeController()
        next.start()
        next.stop()
        #expect(windows.frames[3] == threeWindows()[3])
    }

    @Test func swipeDoesNothingWhileOffOrWhereThereIsNoRow() {
        windows.frames = threeWindows()
        let lanes = makeController()
        lanes.scroll(by: 300)
        #expect(windows.frames == threeWindows())
        let elsewhere = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { false }, pointerDisplay: { "B" }, slideDuration: .zero)
        elsewhere.start()
        let arranged = windows.frames
        elsewhere.scroll(by: 300)
        elsewhere.endScroll()
        #expect(windows.frames == arranged)
    }

    @Test func stackShortcutsPutWindowsUnderEachOtherAndMoveBetweenThem() {
        windows.frames = [
            1: CGRect(x: 0, y: 0, width: 400, height: 300),
            2: CGRect(x: 450, y: 0, width: 300, height: 300),
        ]
        windows.focused = 2
        let lanes = makeController()
        lanes.start()
        lanes.perform(.stack)
        #expect(windows.frames[1] == CGRect(x: 0, y: 25, width: 400, height: 387))
        #expect(windows.frames[2] == CGRect(x: 0, y: 412, width: 400, height: 388))
        lanes.perform(.focusUp)
        #expect(windows.raised == [1])
        lanes.perform(.focusDown)
        lanes.perform(.focusDown)  // already at the bottom
        #expect(windows.raised == [1, 2])
        lanes.perform(.unstack)
        #expect(windows.frames[2] == CGRect(x: 400, y: 25, width: 400, height: 775))
        lanes.stop()
        #expect(windows.frames[1] == CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    @Test func swipeKeysStartOffAndPersist() {
        let lanes = makeController()
        #expect(lanes.scrollModifier == .off)
        lanes.scrollModifier = .controlOption
        #expect(makeController().scrollModifier == .controlOption)
    }

    @Test func moduleSwitchStartsAndStopsIt() {
        windows.frames = threeWindows()
        windows.focused = 1
        let state = AppState.testing(
            defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings(), laneWindows: windows)
        #expect(!state.lanes.isRunning)
        state.setEnabled(.lanes, true)
        #expect(state.lanes.isRunning)
        // Sized for the row at once; it slides into place from there.
        #expect(windows.frames[1]?.height == 775)
        state.setEnabled(.lanes, false)
        #expect(!state.lanes.isRunning)
        #expect(windows.frames == threeWindows())
    }

    @Test func windowsSlideToTheirPlacesAndEndUpExactlyThere() async {
        windows.frames = threeWindows()
        windows.focused = 1
        // Slow enough that the slide is still under way however busy the machine is.
        let lanes = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { false },
            slideDuration: .seconds(30))
        lanes.start()
        lanes.refresh()  // ends the opening slide at once
        #expect(windows.frames[2] == CGRect(x: 600, y: 25, width: 600, height: 775))
        lanes.perform(.focusRight)
        func isPartWay() -> Bool { (windows.trail[2] ?? []).contains { $0.x > 400 && $0.x < 600 } }
        for _ in 0..<500 where !isPartWay() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(isPartWay())
        lanes.refresh()
        #expect(windows.frames[1]?.minX == -200)
        #expect(windows.frames[2] == CGRect(x: 400, y: 25, width: 600, height: 775))
    }

    @Test func nextShortcutFinishesASlideStillUnderWay() {
        windows.frames = threeWindows()
        windows.focused = 1
        let lanes = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { false },
            slideDuration: .seconds(5))
        lanes.start()
        lanes.perform(.focusRight)
        lanes.stop()
        // Stopping mid-slide still puts everything back.
        #expect(windows.frames == threeWindows())
    }

    @Test func changesAreGatheredIntoOneLookOnceTheMouseIsUp() async {
        windows.frames = threeWindows()
        windows.focused = 1
        var mouseDown = true
        let lanes = LanesController(
            defaults: store.defaults, shortcuts: Shortcuts(defaults: store.defaults, center: FakeHotKeys()), windows: windows,
            isMouseDown: { mouseDown },
            slideDuration: .zero)
        lanes.start()
        // Dragged while the button is held: left where it is.
        let dragged = CGRect(x: 300, y: 200, width: 600, height: 775)
        windows.frames[1] = dragged
        windows.onChange()
        windows.onChange()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(windows.frames[1] == dragged)
        mouseDown = false
        for _ in 0..<500 where windows.frames[1] == dragged {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(windows.frames[1] == CGRect(x: 0, y: 25, width: 600, height: 775))
    }
}
