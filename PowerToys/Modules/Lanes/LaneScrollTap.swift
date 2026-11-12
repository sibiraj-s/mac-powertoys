import AppKit
import Synchronization

/// Sideways two-finger swipes on the trackpad, and turns of a mouse wheel, made while certain
/// modifier keys are held. They're kept from the app under the pointer. A swipe goes to
/// `onScroll` as points moved, and keeps coming while it coasts after the fingers lift, even
/// once the keys are let go; `onLift` says the fingers lifted and `onFinish` that any coasting
/// is over. Some devices don't say where a swipe starts and ends, which `onScroll` is told.
/// The wheel goes to `onNotch` as -1 or 1, a few times a second at most. Listens while
/// Accessibility is allowed.
final class LaneScrollTap {
    private let tap: EventTap

    init(
        flags: CGEventFlags, isTrusted: @escaping () -> Bool,
        onScroll: @escaping @MainActor (_ distance: CGFloat, _ saysWhenItEnds: Bool) -> Void,
        onLift: @escaping @MainActor () -> Void, onFinish: @escaping @MainActor () -> Void,
        onNotch: @escaping @MainActor (Int) -> Void
    ) {
        // The tap answers on its own thread without waiting, so scrolling everywhere else never
        // waits on this app; the swipe itself is handled on the main thread a moment later.
        let deliver: @Sendable (LaneScroll) -> Void = { scroll in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch scroll {
                    case .swipe(let take, let saysWhenItEnds):
                        let distance = take()
                        if distance != 0 { onScroll(distance, saysWhenItEnds) }
                    case .lifted: onLift()
                    case .finished: onFinish()
                    case .notch(let direction): onNotch(direction)
                    }
                }
            }
        }
        let listener = LaneScrollListener(flags: flags, deliver: deliver)
        // At the tail, so it's always after Scroll & Mouse's tap at the head, whichever started
        // last, and scrolling here goes the way that module makes it go everywhere else.
        tap = EventTap(
            placement: .tailAppendEventTap, events: EventTap.mask(of: [.scrollWheel]), isTrusted: isTrusted,
            handler: .onOwnThread(name: "PowerToys lanes scrolling") { type, event in listener.process(type, event) })
    }

    func start() {
        tap.start()
    }

    func stop() {
        tap.stop()
    }
}

private nonisolated enum LaneScroll: Sendable {
    /// A swipe moved. The closure gives how far since it was last asked, so that when swipes
    /// come faster than they're handled, one answer covers all that's waiting.
    case swipe(@Sendable () -> CGFloat, saysWhenItEnds: Bool)
    /// The fingers lifted; the swipe may coast on.
    case lifted
    /// The coasting is over.
    case finished
    case notch(Int)
}

/// What the tap's thread keeps track of between scrolls.
private nonisolated final class LaneScrollListener: @unchecked Sendable {
    private let flags: CGEventFlags
    private let deliver: @Sendable (LaneScroll) -> Void
    /// Whether the swipe under way is this app's or the app's under the pointer. Only touched on the tap's thread.
    private var swipe = Swipe.undecided

    /// Whether the app under the pointer was let see this swipe start, before it was decided whose it is.
    private var appSawStart = false

    private enum Swipe {
        case undecided, taken, left
    }

    /// Phases of a swipe, as scroll events give them.
    private static let began: Int64 = 1
    private static let ended: Int64 = 4
    private static let cancelled: Int64 = 8
    private static let mayBegin: Int64 = 128
    /// The last phase of coasting.
    private static let coastingEnded: Int64 = 3
    /// When the wheel last counted, in seconds since startup. Only touched on the tap's thread.
    private var lastNotch: Double = 0
    /// How far swipes have moved that hasn't been handed over yet, and whether a handover is on its way.
    private let waiting = Mutex<(distance: CGFloat, isAsked: Bool)>((0, false))

    private static let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    init(flags: CGEventFlags, deliver: @escaping @Sendable (LaneScroll) -> Void) {
        self.flags = flags
        self.deliver = deliver
    }

    /// Returns whether the event goes on to apps.
    func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .scrollWheel:
            let isHeld = event.flags.intersection(Self.modifiers) == flags
            // Trackpads scroll continuously; a mouse wheel turns in notches.
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else {
                guard isHeld else { return true }
                let turn = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                let seconds = Double(event.timestamp) / 1_000_000_000
                // A fast spin sends many notches; each step along the row gets time to be seen.
                if turn != 0, seconds - lastNotch > 0.15 {
                    lastNotch = seconds
                    deliver(.notch(turn < 0 ? -1 : 1))
                }
                return false
            }
            let distance = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let upOrDown = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let coasting = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            let isCoasting = coasting != 0
            // A swipe is taken or left as a whole, coasting and all, so an app never gets half
            // of one. It's decided by the first of it that moves: taken if the keys are held and
            // it goes more sideways than up or down, which stays the app's, to zoom with for one.
            if phase == Self.began || phase == Self.mayBegin {
                swipe = .undecided
                appSawStart = false
            }
            if phase == 0, !isCoasting { swipe = .undecided }  // a device that doesn't say where swipes start and end
            if swipe == .undecided, !isCoasting, distance != 0 || upOrDown != 0 {
                swipe = isHeld && abs(distance) > abs(upOrDown) ? .taken : .left
            }
            guard swipe == .taken else {
                if swipe == .undecided, phase != 0 { appSawStart = true }
                return true
            }
            let asks = waiting.withLock { waiting in
                waiting.distance += distance
                defer { waiting.isAsked = true }
                return !waiting.isAsked
            }
            if asks {
                deliver(
                    .swipe(
                        { [self] in
                            waiting.withLock { waiting in
                                defer { waiting = (0, false) }
                                return waiting.distance
                            }
                        }, saysWhenItEnds: phase != 0 || isCoasting))
            }
            if phase == Self.ended || phase == Self.cancelled {
                deliver(.lifted)
                // An app that saw it start is let see it end, with nothing scrolled, so it isn't left waiting.
                if appSawStart {
                    appSawStart = false
                    for field in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2] {
                        event.setIntegerValueField(field, value: 0)
                    }
                    return true
                }
            }
            if coasting == Self.coastingEnded { deliver(.finished) }
            return false
        default:
            return true
        }
    }
}
