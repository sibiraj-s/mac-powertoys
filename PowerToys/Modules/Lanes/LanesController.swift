import AppKit
import Observation

/// Keeps each display's windows in one row that scrolls sideways. New windows open beside the
/// focused one, and the row scrolls to whichever window has the keyboard.
@Observable
final class LanesController {
    enum Action: CaseIterable, Identifiable {
        case focusLeft, focusRight, focusUp, focusDown, moveLeft, moveRight, stack, unstack, cycleWidth, toggleFloating

        var id: Self { self }

        var title: String {
            switch self {
            case .focusLeft: "Focus window to the left"
            case .focusRight: "Focus window to the right"
            case .focusUp: "Focus window above"
            case .focusDown: "Focus window below"
            case .moveLeft: "Move window left"
            case .moveRight: "Move window right"
            case .stack: "Stack under window on the left"
            case .unstack: "Move window out of its stack"
            case .cycleWidth: "Switch to next width"
            case .toggleFloating: "Leave window out, or let it back in"
            }
        }

        var shortcut: ShortcutDefinition {
            ShortcutDefinition(id: "lanes.\(self)", module: .lanes, title: title, defaultHotKey: nil)
        }

        fileprivate var step: LaneBoard.Step? {
            switch self {
            case .focusLeft: .focus(-1)
            case .focusRight: .focus(1)
            case .focusUp: .focusStack(-1)
            case .focusDown: .focusStack(1)
            case .moveLeft: .move(-1)
            case .moveRight: .move(1)
            case .stack: .stack
            case .unstack: .unstack
            case .cycleWidth: .cycleWidth
            case .toggleFloating: nil
            }
        }
    }

    /// The keys to hold while swiping sideways with two fingers, or turning the mouse wheel, to scroll a row.
    enum ScrollModifier: String, CaseIterable, Identifiable {
        case off, option, control, command, controlOption, commandOption

        var id: Self { self }

        var title: String {
            switch self {
            case .off: "Off"
            case .option: "⌥ Option"
            case .control: "⌃ Control"
            case .command: "⌘ Command"
            case .controlOption: "⌃⌥ Control and Option"
            case .commandOption: "⌥⌘ Option and Command"
            }
        }

        fileprivate var flags: CGEventFlags? {
            switch self {
            case .off: nil
            case .option: .maskAlternate
            case .control: .maskControl
            case .command: .maskCommand
            case .controlOption: [.maskControl, .maskAlternate]
            case .commandOption: [.maskAlternate, .maskCommand]
            }
        }
    }

    private(set) var isRunning = false

    /// Off until the user picks keys: held with a swipe, they're taken from every app.
    var scrollModifier: ScrollModifier {
        didSet {
            defaults.set(scrollModifier.rawValue, forKey: Self.scrollModifierKey)
            updateScrollTap()
        }
    }

    static let scrollModifierKey = "lanes.scrollModifier"

    /// Where a picture of the whole row shows while it's scrolled with a swipe or the wheel.
    var overviewPosition: LaneOverview.Position {
        didSet {
            defaults.set(overviewPosition.rawValue, forKey: Self.overviewPositionKey)
            if overviewPosition == .off { hideOverview() }
        }
    }

    static let overviewPositionKey = "lanes.overview"
    static let placesKey = "lanes.places"

    /// Where a window was put and where it was before, kept on disk while Lanes runs. If the
    /// app goes away without putting windows back, the next start finds them by these.
    private struct SavedPlace: Codable, Equatable {
        let pid: pid_t
        /// When the process started: after a restart the same number is some other app's.
        let started: Date
        let placed: CGRect
        let original: CGRect
    }

    let shortcuts: Shortcuts
    private let defaults: UserDefaults

    @ObservationIgnored private let windows: any LaneWindowSystem
    @ObservationIgnored private let isMouseDown: () -> Bool
    @ObservationIgnored private var board = LaneBoard()
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    /// A window just brought forward by a shortcut. macOS takes a moment to say it has the
    /// keyboard; until then the old one still seems to, and the row would scroll back to it.
    @ObservationIgnored private var awaitedFocus: (id: Int, until: Date)?
    /// How long windows take to slide to their new places; zero makes them jump.
    @ObservationIgnored private let slideDuration: Duration
    /// The windows sliding now, and the task moving them.
    @ObservationIgnored private var sliding: [LaneMove] = []
    @ObservationIgnored private var slideTask: Task<Void, Never>?
    @ObservationIgnored private let isTrusted: () -> Bool
    @ObservationIgnored private let pointerDisplay: () -> String?
    @ObservationIgnored private var scrollTap: LaneScrollTap?
    @ObservationIgnored private let overview: (any LaneOverviewPresenting)?
    /// Shows where a window being dragged along its row would land.
    @ObservationIgnored private let dropZone: (any LaneDropPresenting)?
    @ObservationIgnored private let pointer: () -> CGPoint?
    /// Where the pointer was at the last look for a drop target, while the mouse is held, and
    /// how many looks since it stopped there.
    @ObservationIgnored private var dragPointer: CGPoint?
    @ObservationIgnored private var looksSinceStill = 0
    /// The app of the window being dragged didn't answer in time, and isn't asked again until
    /// the drag ends.
    @ObservationIgnored private var dragGaveUp = false
    /// Waiting to put the overview away once scrolling has stopped.
    @ObservationIgnored private var overviewHide: Task<Void, Never>?
    /// The row being scrolled by hand, with the windows as they are now. Looking them all up
    /// again for every bit of a swipe would be too slow, so their frames are kept up here.
    @ObservationIgnored private var swipe: (display: String, snapshot: LaneSnapshot)?
    @ObservationIgnored private var swipeEnd: Task<Void, Never>?
    /// Windows that weren't where they were sent when last moved: what was asked, where they
    /// were when last looked at, and how many looks so far. An app that animates is still on
    /// its way there; one that won't take the frame stays put. Until a window has stopped
    /// changing it counts as where it was sent.
    @ObservationIgnored private var unsettled: [Int: (asked: CGRect, seen: CGRect, looks: Int)] = [:]
    @ObservationIgnored private var widthCheck: Task<Void, Never>?
    /// Waiting for Accessibility to be allowed, to arrange the windows once it is.
    @ObservationIgnored private var readyCheck: Task<Void, Never>?
    /// Waiting to ask an app that wasn't answering again.
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// A swipe is under way where there's no row to scroll, and is let go by.
    @ObservationIgnored private var swipeIsIdle = false
    /// Whether the mouse button was down since the windows were last arranged.
    @ObservationIgnored private var wasDragging = false
    /// Places saved by a run that never put its windows back, not yet matched to a window.
    @ObservationIgnored private var recovering: [SavedPlace] = []
    /// What was last written down, to leave the disk alone while nothing has changed.
    @ObservationIgnored private var saved: [SavedPlace]?
    @ObservationIgnored private let startTime: (pid_t) -> Date?
    /// How long a display can be gone before its rows are given up, in seconds.
    @ObservationIgnored private let displayGrace: TimeInterval
    /// Since when a display with a row has been missing.
    @ObservationIgnored private var displayGoneAt: Date?
    /// How long after waking a display with a row is waited for, in seconds: one coming out of
    /// sleep can take a good while longer to be found than one that only blinked.
    @ObservationIgnored private let wakeGrace: TimeInterval
    /// Whether the Mac or its displays are asleep, when displays come and go and nothing is arranged.
    @ObservationIgnored private var isAsleep = false
    /// When the Mac or its displays last woke.
    @ObservationIgnored private var wokeAt = Date.distantPast
    @ObservationIgnored private let now: () -> Date
    /// When each process with an arranged window started, which doesn't change, asked once.
    @ObservationIgnored private var starts: [pid_t: Date] = [:]

    init(
        defaults: UserDefaults = .standard, shortcuts: Shortcuts, windows: any LaneWindowSystem = LiveLaneWindows(),
        isTrusted: @escaping () -> Bool = { false }, overview: (any LaneOverviewPresenting)? = nil,
        dropZone: (any LaneDropPresenting)? = nil,
        isMouseDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
        pointer: @escaping () -> CGPoint? = { Displays.flip(NSEvent.mouseLocation) },
        pointerDisplay: (() -> String?)? = nil,
        startTime: @escaping (pid_t) -> Date? = { ProcessStart.read($0) },
        slideDuration: Duration = .milliseconds(220), displayGrace: TimeInterval = 3, wakeGrace: TimeInterval = 20,
        now: @escaping () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.shortcuts = shortcuts
        self.windows = windows
        self.isTrusted = isTrusted
        self.overview = overview
        self.dropZone = dropZone
        self.isMouseDown = isMouseDown
        self.pointer = pointer
        // The display under the pointer, unless told otherwise.
        self.pointerDisplay =
            pointerDisplay ?? {
                pointer().flatMap { Displays.screen(at: $0) }.map { Displays.key(for: $0) }
            }
        self.startTime = startTime
        self.slideDuration = slideDuration
        self.displayGrace = displayGrace
        self.wakeGrace = wakeGrace
        self.now = now
        scrollModifier = defaults.string(forKey: Self.scrollModifierKey).flatMap(ScrollModifier.init(rawValue:)) ?? .off
        overviewPosition =
            defaults.string(forKey: Self.overviewPositionKey).flatMap(LaneOverview.Position.init(rawValue:)) ?? .bottom
    }

    // MARK: Lifecycle

    /// - Parameter lookingNow: Whether to arrange the windows before returning. Looking at
    ///   every app's windows takes a moment, which the app's own launch needn't wait for.
    func start(lookingNow: Bool = true) {
        guard !isRunning else { return }
        isRunning = true
        for action in Action.allCases {
            shortcuts.activate(action.shortcut) { [weak self] in self?.perform(action) }
        }
        windows.onChange = { [weak self] in self?.setNeedsRefresh() }
        windows.onClose = { [weak self] id in
            self?.board.forget(id)
            self?.unsettled[id] = nil
            // Its process may be gone too, and its number given to another in time.
            self?.starts = [:]
        }
        windows.onSleep = { [weak self] in self?.fallAsleep() }
        windows.onWake = { [weak self] in self?.wakeUp() }
        windows.start()
        updateScrollTap()
        // Places kept from a run that didn't put its windows back. Those of apps that have since
        // quit are no use, and nor are those whose number now belongs to another process.
        let kept = defaults.data(forKey: Self.placesKey).flatMap { try? JSONDecoder().decode([SavedPlace].self, from: $0) } ?? []
        recovering = kept.filter { ProcessStart.isSame($0.pid, startedAt: $0.started, read: startTime) }
        starts = [:]
        saved = nil
        if lookingNow {
            refresh()
        } else {
            setNeedsRefresh()
        }
    }

    /// Stops arranging and puts every window back where it was.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        updateScrollTap()
        for action in Action.allCases {
            shortcuts.deactivate(action.shortcut)
        }
        // A swipe or slide under way is dropped where it is: every window is about to move anyway.
        swipeEnd?.cancel()
        swipeEnd = nil
        swipe = nil
        swipeIsIdle = false
        hideOverview()
        endDrag()
        slideTask?.cancel()
        slideTask = nil
        sliding = []
        pendingRefresh?.cancel()
        pendingRefresh = nil
        widthCheck?.cancel()
        widthCheck = nil
        readyCheck?.cancel()
        readyCheck = nil
        retry?.cancel()
        retry = nil
        unsettled = [:]
        awaitedFocus = nil
        isAsleep = false
        wokeAt = .distantPast
        displayGoneAt = nil
        // Every window is to go back, those of apps that weren't answering a moment ago too.
        windows.askAgain()
        // A window that can't be put back now, its app not answering, is kept to be found later.
        var unmoved: [SavedPlace] = []
        let records = Dictionary(board.records.map { ($0.id, $0) }) { first, _ in first }
        for move in board.restorations() where windows.apply(move) == nil {
            // Only one held up by its app: a window that's simply gone has nowhere to go back to.
            if windows.isHeldUp(move.id), let record = records[move.id], let place = place(of: record) {
                unmoved.append(place)
            }
        }
        board = LaneBoard()
        // So are windows an earlier run left arranged on a Space not shown since.
        write(recovering + unmoved)
        recovering = []
        windows.stop()
    }

    // MARK: Shortcuts

    func perform(_ action: Action) {
        guard isRunning, windows.isReady, !wokeByHand() else { return }
        endScroll()
        finishSlide()
        guard let step = action.step else {
            guard let left = windows.toggleFloating() else {
                refresh()
                return
            }
            // A window left out goes back to where it was before it joined a row. One that can't
            // be moved now, its app not answering, stays in the row, with its place to go back to kept.
            if windows.isHeldUp(left) {
                _ = windows.toggleFloating()
            } else if let move = board.release(left) {
                _ = windows.apply(move)
            }
            refresh()
            return
        }
        change { board, snapshot in board.perform(step, in: snapshot) }
    }

    /// Steps the focus along the row under the pointer, as the mouse wheel does.
    func stepFocus(by places: Int) {
        guard isRunning, windows.isReady, !wokeByHand(), let display = pointerDisplay() else { return }
        endScroll()
        finishSlide()
        guard let snapshot = change({ board, _ in board.stepFocus(by: places, on: display) }) else { return }
        // There's no telling when the wheel has stopped, so the overview stays a moment after each notch.
        showOverview(on: display, in: snapshot, settling: false, animated: true)
        hideOverview(after: .milliseconds(900))
    }

    /// Makes a change to the lanes as they are now and arranges the windows to match, bringing
    /// forward the window the change returns. Returns the windows as they were found, unless
    /// they're being left be.
    @discardableResult
    private func change(_ make: (inout LaneBoard, LaneSnapshot) -> Int?) -> LaneSnapshot? {
        let snapshot = current()
        guard !waitsForADisplay(snapshot) else { return nil }
        board.sync(snapshot, afterDrag: wasDragging)
        arrange(snapshot, bringing: make(&board, snapshot))
        return snapshot
    }

    /// Arranges the windows, then brings `forward` to the front if there is one.
    private func arrange(_ snapshot: LaneSnapshot, bringing forward: Int?) {
        var snapshot = snapshot
        if let forward {
            awaitedFocus = (forward, Date.now.addingTimeInterval(0.5))
            snapshot.focused = forward
        }
        arrange(snapshot)
        if let forward { windows.focus(forward) }
    }

    // MARK: Arranging

    /// Looks at the windows again soon. Changes come in bursts, and each of the app's own moves
    /// comes back as one, so they're gathered up; and windows aren't moved under a drag or
    /// looked at mid-slide or mid-swipe.
    private func setNeedsRefresh() {
        if isMouseDown() { wasDragging = true }
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            repeat {
                try? await Task.sleep(for: .milliseconds(50))
                if self?.isMouseDown() == true {
                    self?.wasDragging = true
                    self?.showDropTarget()
                } else {
                    // Let go: the place goes at once, though a slide may keep the windows waiting.
                    self?.endDrag()
                }
            } while !Task.isCancelled && self?.isBusy == true
            guard !Task.isCancelled, let self else { return }
            pendingRefresh = nil
            endDrag()
            refresh()
        }
    }

    /// Shows where the window being dragged would land if let go now, or puts the place away
    /// when no window is being dragged along its row. The window being dragged has the keyboard.
    /// The mouse is held for all sorts besides, so its app is asked only while the pointer is
    /// moving, and only over a display with a row. Apps say where a window is a moment behind
    /// the pointer, so it's asked a few more times once the pointer stops. One that doesn't
    /// answer in time isn't asked again during the drag, which then shows no place.
    private func showDropTarget() {
        guard let dropZone else { return }
        // What can be told without asking any app is seen to at every look.
        guard isRunning, !isAsleep, !dragGaveUp, swipe == nil, slideTask == nil, let display = pointerDisplay(),
            board.lane(on: display) != nil
        else {
            hideDropTarget()
            return
        }
        let point = pointer()
        if let point, point == dragPointer {
            guard looksSinceStill < Self.looksOnceStill else { return }
            looksSinceStill += 1
        } else {
            looksSinceStill = 0
        }
        dragPointer = point
        switch windows.draggedWindow() {
        case .window(let id, let frame):
            if let target = board.dropTarget(of: id, at: frame, pointer: point) {
                dropZone.show(at: target)
            } else {
                dropZone.hide()
            }
        case .none:
            dropZone.hide()
        case .notAnswering:
            dragGaveUp = true
            dropZone.hide()
        }
    }

    private func hideDropTarget() {
        dragPointer = nil
        looksSinceStill = 0
        dropZone?.hide()
    }

    /// The mouse is up, or Lanes is stopping or sleeping: the next drag starts afresh.
    private func endDrag() {
        dragGaveUp = false
        hideDropTarget()
    }

    /// How many times the window being dragged is looked at after the pointer stops, 50ms
    /// apart: long enough for an app slow to say where the window went.
    private static let looksOnceStill = 6

    /// Whether windows are being moved by hand or are on their way somewhere, when they aren't
    /// to be looked at or moved from here.
    private var isBusy: Bool { isMouseDown() || slideTask != nil || swipe != nil }

    /// Brings the lanes in line with the screen, and the windows in line with their lanes.
    func refresh() {
        guard isRunning else { return }
        guard windows.isReady else {
            waitUntilReady()
            return
        }
        // Nothing is looked at while asleep: waking looks at everything.
        guard !isAsleep else { return }
        endScroll()
        finishSlide()
        let snapshot = current()
        guard !waitsForADisplay(snapshot) else { return }
        board.sync(snapshot, afterDrag: wasDragging)
        arrange(snapshot)
        askSilentAppsAgain()
    }

    /// Whether to leave the windows be: the Mac is asleep, or a display with a row has only
    /// just gone. It's looked for again in a moment; one still gone after a few seconds, or
    /// longer just after waking, has its rows given up. With no display at all there's nowhere
    /// for the rows to go, and they're kept however long that lasts.
    private func waitsForADisplay(_ snapshot: LaneSnapshot) -> Bool {
        // Waking looks at everything afresh.
        guard !isAsleep else { return true }
        guard board.isMissingADisplay(in: snapshot) else {
            displayGoneAt = nil
            return false
        }
        // With none at all, there's nothing to time, nor to look again for: one turning up is
        // heard of as a change, and the wait for any still missing starts then.
        guard !snapshot.displays.isEmpty else {
            displayGoneAt = nil
            return true
        }
        let since = displayGoneAt ?? now()
        displayGoneAt = since
        let time = now()
        guard time.timeIntervalSince(since) < displayGrace || time.timeIntervalSince(wokeAt) < wakeGrace else { return false }
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            retry = nil
            setNeedsRefresh()
        }
        return true
    }

    /// The Mac or its displays went to sleep. Displays drop out and windows are shuffled about
    /// until they wake, none of which is to change the rows.
    private func fallAsleep() {
        guard isRunning else { return }
        // A swipe or slide under way is finished first, while windows can still be arranged.
        endScroll()
        finishSlide()
        hideOverview()
        endDrag()
        isAsleep = true
        // Where windows are found now isn't where their apps would have them.
        widthCheck?.cancel()
        widthCheck = nil
        unsettled = [:]
        pendingRefresh?.cancel()
        pendingRefresh = nil
        retry?.cancel()
        retry = nil
    }

    /// The Mac or its displays woke. A display missing since before the sleep is waited for
    /// from now, not from when it went.
    private func wakeUp() {
        guard isRunning else { return }
        isAsleep = false
        wokeAt = now()
        displayGoneAt = nil
        // Apps asked while the Mac was going to sleep may not have answered.
        windows.askAgain()
        setNeedsRefresh()
    }

    /// Whether a shortcut, wheel or swipe came while asleep, which it can't have: a wake went
    /// unheard of, or the keys beat it here. It wakes Lanes, and is let go by.
    private func wokeByHand() -> Bool {
        guard isAsleep else { return false }
        wakeUp()
        return true
    }

    /// An app that didn't answer is asked again when it's next due, without waiting for some
    /// other window to change: until then its windows may not be where they belong.
    private func askSilentAppsAgain() {
        retry?.cancel()
        retry = nil
        guard let due = windows.askAgainAt else { return }
        retry = Task { [weak self] in
            // Never at once, whatever is said to be due: a look that changes nothing mustn't bring on the next.
            try? await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0.5) + 0.05))
            guard !Task.isCancelled, let self else { return }
            retry = nil
            setNeedsRefresh()
        }
    }

    /// Accessibility may be allowed later, in System Settings; the windows are arranged once it is.
    private func waitUntilReady() {
        guard readyCheck == nil else { return }
        readyCheck = Task { [weak self] in
            while !Task.isCancelled, self?.windows.isReady == false {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled, let self else { return }
            readyCheck = nil
            // Apps asked before it was allowed couldn't answer; they're asked afresh.
            windows.askAgain()
            refresh()
        }
    }

    private func current() -> LaneSnapshot {
        var snapshot = windows.snapshot()
        recover(in: snapshot)
        for index in snapshot.windows.indices {
            if let asked = unsettled[snapshot.windows[index].id]?.asked {
                snapshot.windows[index] = LaneSnapshot.Window(id: snapshot.windows[index].id, frame: asked)
            }
        }
        if let awaited = awaitedFocus {
            if awaited.until < .now || snapshot.focused == awaited.id {
                awaitedFocus = nil
            } else if snapshot.windows.contains(where: { $0.id == awaited.id }) {
                snapshot.focused = awaited.id
            }
        }
        return snapshot
    }

    private func arrange(_ snapshot: LaneSnapshot) {
        let moves = board.layout(snapshot, afterDrag: wasDragging)
        wasDragging = false
        if slideDuration > .zero, moves.contains(where: { $0.slide != nil }) {
            slide(moves)
            return
        }
        for move in moves {
            apply(move)
        }
        if !moves.isEmpty { save() }
    }

    /// Makes a move and records how it went.
    private func apply(_ move: LaneMove) {
        if let actual = windows.apply(move) {
            settle(move, at: actual)
        } else if windows.isHeldUp(move.id) {
            // Its app isn't answering: the window isn't there yet, and is sent again later.
            board.missed(move.id)
        }
    }

    /// Records where a moved window ended up. Anywhere other than where it was sent isn't
    /// believed yet: the window counts as being there until it has stopped changing.
    private func settle(_ move: LaneMove, at actual: CGRect) {
        guard !LaneBoard.near(actual, move.frame) else {
            unsettled[move.id] = nil
            board.settle(move.id, at: actual)
            return
        }
        board.settle(move.id, at: move.frame)
        unsettled[move.id] = (move.frame, actual, 0)
        guard widthCheck == nil else { return }
        widthCheck = Task { [weak self] in
            while !Task.isCancelled, self?.unsettled.isEmpty == false {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self?.confirmPlaces()
            }
            self?.widthCheck = nil
        }
    }

    /// Looks again at the windows that weren't where they were sent. One that's where it was
    /// at the last look has stopped. If that's where it was sent, it was only on its way. If
    /// not, that's where its app will have it: commonly a width or height of the app's own,
    /// which the row then makes room for. One still changing is looked at again, a second's
    /// worth of times at most.
    func confirmPlaces() {
        guard isRunning, !isAsleep, !unsettled.isEmpty else { return }
        var stopped = false
        for (id, doubt) in unsettled {
            let frame = windows.frame(of: id)
            if let frame, !LaneBoard.near(frame, doubt.seen), doubt.looks < 8 {
                unsettled[id] = (doubt.asked, frame, doubt.looks + 1)
                continue
            }
            unsettled[id] = nil
            if let frame { board.settle(id, at: frame) }
            stopped = true
        }
        guard stopped, unsettled.isEmpty else { return }
        // Not under a drag, a swipe or a slide, which it would cut short.
        if isBusy { setNeedsRefresh() } else { refresh() }
    }

    // MARK: Recovering

    /// Writes down where every arranged window was put and where it was before.
    private func save() {
        write(board.records.compactMap(place(of:)) + recovering)
    }

    private func place(of record: (id: Int, placed: CGRect, original: CGRect)) -> SavedPlace? {
        guard let pid = windows.owner(of: record.id), let started = starts[pid] ?? startTime(pid) else { return nil }
        starts[pid] = started
        return SavedPlace(pid: pid, started: started, placed: record.placed, original: record.original)
    }

    private func write(_ places: [SavedPlace]) {
        guard places != saved else { return }
        saved = places
        if places.isEmpty {
            defaults.removeObject(forKey: Self.placesKey)
        } else {
            defaults.set(try? JSONEncoder().encode(places), forKey: Self.placesKey)
        }
    }

    /// Windows still where an earlier run left them get back the places they had before it.
    private func recover(in snapshot: LaneSnapshot) {
        guard !recovering.isEmpty else { return }
        for window in snapshot.windows where board.originals[window.id] == nil {
            guard let pid = windows.owner(of: window.id),
                let index = recovering.firstIndex(where: {
                    $0.pid == pid && LaneBoard.isSamePlace($0.placed, window.frame, in: snapshot.displays)
                })
            else { continue }
            board.adopt(recovering.remove(at: index).original, for: window.id)
        }
    }

    // MARK: Scrolling by hand

    private func updateScrollTap() {
        scrollTap?.stop()
        scrollTap = nil
        guard isRunning, let flags = scrollModifier.flags else { return }
        // Swiping left moves what's on screen left, as scrolling does everywhere else.
        scrollTap = LaneScrollTap(
            flags: flags, isTrusted: isTrusted,
            onScroll: { [weak self] distance, saysWhenItEnds in self?.scroll(by: -distance, saysWhenItEnds: saysWhenItEnds) },
            onLift: { [weak self] in self?.swipeLifted() },
            onFinish: { [weak self] in self?.endScroll() },
            // Turning the wheel towards you goes on along the row, as it goes on down a page.
            onNotch: { [weak self] notch in self?.stepFocus(by: notch < 0 ? 1 : -1) })
        scrollTap?.start()
    }

    /// Scrolls the row under the pointer along by `distance`, its windows following at once.
    /// A swipe that says when it ends goes on, through any pause with the fingers down, until
    /// it does. One that doesn't is over when nothing more comes for a moment.
    func scroll(by distance: CGFloat, saysWhenItEnds: Bool = false) {
        guard isRunning, windows.isReady, !wokeByHand() else { return }
        // Even one that says when it ends is given up on in time, should its end go missing.
        endSwipe(after: saysWhenItEnds ? .seconds(3) : .milliseconds(150))
        guard !swipeIsIdle else { return }
        if swipe == nil {
            finishSlide()
            // Looking at every window is slow, so it's done once a swipe, even one over a
            // display with no row, which is then let go by until it ends.
            guard let display = pointerDisplay() else {
                swipeIsIdle = true
                return
            }
            var snapshot = current()
            guard !waitsForADisplay(snapshot) else {
                swipeIsIdle = true
                return
            }
            // A window dragged just before the swipe is dropped where it was let go first.
            board.sync(snapshot, afterDrag: wasDragging)
            wasDragging = false
            // During a swipe every window in the row is moved by hand, wherever the pointer is.
            snapshot.pointer = nil
            swipe = (display, snapshot)
        }
        guard var swipe, board.scroll(on: swipe.display, by: distance) else {
            self.swipe = nil
            swipeIsIdle = true
            return
        }
        for move in board.layout(swipe.snapshot, afterDrag: true) {
            // A window only changing place is sent on its way without waiting to hear back.
            let actual: CGRect
            if move.resizes {
                guard let applied = windows.apply(move) else { continue }
                actual = applied
            } else {
                windows.slide(move.id, to: move.frame.origin)
                actual = move.frame
            }
            board.settle(move.id, at: actual)
            if let index = swipe.snapshot.windows.firstIndex(where: { $0.id == move.id }) {
                swipe.snapshot.windows[index] = LaneSnapshot.Window(id: move.id, frame: actual)
            }
        }
        self.swipe = swipe
        showOverview(on: swipe.display, in: swipe.snapshot, settling: true, animated: false)
    }

    /// The fingers lifted. The swipe is over unless it coasts on, which it starts to at once.
    func swipeLifted() {
        guard swipe != nil || swipeIsIdle else { return }
        endSwipe(after: .milliseconds(80))
    }

    private func endSwipe(after wait: Duration) {
        swipeEnd?.cancel()
        swipeEnd = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.endScroll()
        }
    }

    /// Ends a swipe: the row settles on whichever window it was left on, which gets the keyboard.
    func endScroll() {
        swipeEnd?.cancel()
        swipeEnd = nil
        swipeIsIdle = false
        guard let display = swipe?.display else { return }
        swipe = nil
        hideOverview(after: .milliseconds(600))
        // Windows were sent on their way without hearing back; now they're looked at, and any
        // that didn't end up where it was sent is put right.
        let snapshot = current()
        guard !waitsForADisplay(snapshot) else { return }
        board.sync(snapshot)
        arrange(snapshot, bringing: board.endScroll(in: snapshot))
        // The row settled on a window; the overview shows which, on its way out.
        showOverview(on: display, in: snapshot, settling: false, animated: true, staying: true)
        // Anything that changed during the swipe is caught up on.
        setNeedsRefresh()
    }

    // MARK: Overview

    /// Shows the picture of a display's row as it is now, picking out the focused window, or
    /// while `settling` the one the row would settle on if let go. Unless `staying`, a wait to
    /// put it away is called off.
    private func showOverview(on displayKey: String, in snapshot: LaneSnapshot, settling: Bool, animated: Bool, staying: Bool = false) {
        guard overviewPosition != .off, let overview, let lane = board.lane(on: displayKey),
            let display = snapshot.displays.first(where: { $0.key == displayKey })
        else { return }
        if !staying {
            overviewHide?.cancel()
            overviewHide = nil
        }
        let width = display.area.width
        let picture = LaneOverview(
            lane: lane, area: display.area.size, current: settling ? lane.settlesOn(viewWidth: width) : lane.focus,
            fitting: LaneOverview.bounds(in: display.area))
        let sources = lane.ids.compactMap { id in
            windows.owner(of: id).map { LaneOverview.Window(id: id, pid: $0, number: windows.number(of: id)) }
        }
        overview.show(
            picture, at: LaneOverview.frame(of: picture.size, in: display.area, at: overviewPosition), windows: sources, animated: animated)
    }

    /// Puts the overview away after `wait`, or at once.
    private func hideOverview(after wait: Duration = .zero) {
        overviewHide?.cancel()
        overviewHide = nil
        guard let overview else { return }
        guard wait > .zero else {
            overview.hide()
            return
        }
        overviewHide = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.overviewHide = nil
            overview.hide()
        }
    }

    // MARK: Sliding

    /// Moves windows to their new places over a moment rather than at once. Sizes change first,
    /// then every window's position is stepped along its way, easing out.
    private func slide(_ moves: [LaneMove]) {
        for move in moves {
            guard let slide = move.slide else {
                apply(move)
                continue
            }
            if move.resizes {
                _ = windows.apply(LaneMove(id: move.id, frame: CGRect(origin: slide.from, size: move.frame.size), resizes: true))
            }
            sliding.append(move)
        }
        let duration = slideDuration
        let start = ContinuousClock.now
        slideTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                let progress = min(1, (ContinuousClock.now - start) / duration)
                guard progress < 1 else { break }
                let eased = 1 - pow(1 - progress, 3)
                for move in sliding {
                    guard let slide = move.slide else { continue }
                    let origin = CGPoint(
                        x: (slide.from.x + (slide.to.x - slide.from.x) * eased).rounded(),
                        y: (slide.from.y + (slide.to.y - slide.from.y) * eased).rounded())
                    windows.slide(move.id, to: origin)
                }
                // Moving a window waits on its app, which sets the pace; this only yields in between.
                try? await Task.sleep(for: .milliseconds(4))
            }
            guard !Task.isCancelled else { return }
            self?.finishSlide()
        }
    }

    /// Puts sliding windows where they were headed at once: the slide is over, or something
    /// else is about to move them.
    private func finishSlide() {
        guard slideTask != nil else { return }
        slideTask?.cancel()
        slideTask = nil
        let moves = sliding
        sliding = []
        for move in moves {
            apply(LaneMove(id: move.id, frame: move.frame, resizes: false))
        }
        save()
    }
}
