import AppKit
import Observation

/// Changes scroll direction per device, smooths wheel scrolling and gives extra mouse buttons
/// other jobs, through an event tap that sees scroll and button events before apps do.
@Observable
final class ScrollMouseController {
    /// Flip the scroll direction set in System Settings for wheel mice.
    var reversesMouse: Bool {
        didSet { defaults.set(reversesMouse, forKey: Self.reversesMouseKey) }
    }

    /// Flip it for trackpads and other devices that scroll continuously, such as Magic Mouse.
    var reversesTrackpad: Bool {
        didSet { defaults.set(reversesTrackpad, forKey: Self.reversesTrackpadKey) }
    }

    /// Glide between wheel notches instead of jumping a line at a time.
    var smoothsWheel: Bool {
        didSet {
            defaults.set(smoothsWheel, forKey: Self.smoothsWheelKey)
            if !smoothsWheel { stopSmoothing() }
        }
    }

    private(set) var buttonActions: [MouseButton: ButtonAction]

    private(set) var isRunning = false

    static let reversesMouseKey = "scrollMouse.reversesMouse"
    static let reversesTrackpadKey = "scrollMouse.reversesTrackpad"
    static let smoothsWheelKey = "scrollMouse.smoothsWheel"
    static let buttonActionsKey = "scrollMouse.buttonActions"

    /// Marks events this controller posts, so its own tap lets them through untouched.
    static let syntheticMarker: Int64 = 0x5054_534D  // "PTSM"

    private let defaults: UserDefaults
    /// Whether Accessibility is allowed, which the event tap needs; asked afresh each time.
    @ObservationIgnored private let isTrusted: () -> Bool
    @ObservationIgnored private var tap: EventTap?
    @ObservationIgnored private var smoother = ScrollSmoother()
    @ObservationIgnored private var smoothingTimer: Timer?
    /// Buttons whose press was turned into keys, so their drags and release are swallowed too.
    @ObservationIgnored private var remappedButtons: Set<Int64> = []

    init(defaults: UserDefaults = .standard, isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.defaults = defaults
        self.isTrusted = isTrusted
        reversesMouse = defaults.bool(forKey: Self.reversesMouseKey)
        reversesTrackpad = defaults.bool(forKey: Self.reversesTrackpadKey)
        smoothsWheel = defaults.bool(forKey: Self.smoothsWheelKey)
        let stored =
            defaults.data(forKey: Self.buttonActionsKey)
            .flatMap { try? JSONDecoder().decode([MouseButton: ButtonAction].self, from: $0) }
        buttonActions = stored ?? [:]
    }

    isolated deinit {
        stop()
    }

    // MARK: Settings

    func action(for button: MouseButton) -> ButtonAction {
        buttonActions[button] ?? .standard
    }

    func setAction(_ action: ButtonAction, for button: MouseButton) {
        buttonActions[button] = action == .standard ? nil : action
        defaults.set(try? JSONEncoder().encode(buttonActions), forKey: Self.buttonActionsKey)
    }

    /// Wheel mice scroll in discrete notches; trackpads and Magic Mouse scroll continuously.
    func reverses(isContinuous: Bool) -> Bool {
        isContinuous ? reversesTrackpad : reversesMouse
    }

    /// Only wheel notches are smoothed, and not while a modifier is held, since apps give ⌘ or ⌥
    /// with the wheel other meanings, such as zooming.
    func smooths(isContinuous: Bool, flags: CGEventFlags) -> Bool {
        smoothsWheel && !isContinuous && flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl, .maskShift])
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let tap = EventTap(
            events: EventTap.mask(of: [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]), isTrusted: isTrusted,
            handler: .onMain { [weak self] type, event in self?.handle(type, event) ?? true })
        self.tap = tap
        tap.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopSmoothing()
        remappedButtons = []
        tap?.stop()
        tap = nil
    }

    // MARK: Events

    /// Returns whether the event goes on to apps; it may have been changed on the way.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return true
        case _ where event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker:
            return true
        case .scrollWheel:
            return handleScroll(event)
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return handleButton(type, event)
        default:
            return true
        }
    }

    private func handleScroll(_ event: CGEvent) -> Bool {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let reverses = reverses(isContinuous: isContinuous)
        if smooths(isContinuous: isContinuous, flags: event.flags) {
            // Point deltas are the pixels the system would scroll, its wheel acceleration included.
            let sign = reverses ? -1.0 : 1.0
            smoother.add(
                pointsX: sign * Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                pointsY: sign * Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)))
            startSmoothing()
            return false
        }
        // Scrolling that isn't smoothed, such as ⌘ with the wheel to zoom, ends any glide still going.
        if smoothingTimer != nil { stopSmoothing() }
        if reverses { Self.reverse(event) }
        return true
    }

    /// Flips both axes. The line delta goes first, since setting it recalculates the others.
    private static func reverse(_ event: CGEvent) {
        let pairs: [(CGEventField, CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
        ]
        for (lines, fixed, points) in pairs {
            let lineValue = event.getIntegerValueField(lines)
            let fixedValue = event.getDoubleValueField(fixed)
            let pointValue = event.getIntegerValueField(points)
            event.setIntegerValueField(lines, value: -lineValue)
            event.setDoubleValueField(fixed, value: -fixedValue)
            event.setIntegerValueField(points, value: -pointValue)
        }
    }

    private func handleButton(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        switch type {
        case .otherMouseDown:
            guard let button = MouseButton(rawValue: Int(number)), let hotKey = action(for: button).hotKey else { return true }
            remappedButtons.insert(number)
            hotKey.press(marker: Self.syntheticMarker)
            return false
        case .otherMouseUp:
            return remappedButtons.remove(number) == nil
        default:
            return !remappedButtons.contains(number)
        }
    }

    // MARK: Smoothing

    private func startSmoothing() {
        guard smoothingTimer == nil else { return }
        let timer = Timer(timeInterval: ScrollSmoother.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.postSmoothedFrame() }
        }
        // Common modes, so scrolling keeps gliding while a menu or a drag is tracking the mouse.
        RunLoop.main.add(timer, forMode: .common)
        smoothingTimer = timer
        postSmoothedFrame()
    }

    private func stopSmoothing() {
        smoothingTimer?.invalidate()
        smoothingTimer = nil
        smoother.stop()
    }

    private func postSmoothedFrame() {
        let (x, y) = smoother.step()
        if x != 0 || y != 0,
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
        {
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cgSessionEventTap)
        }
        if smoother.isIdle { stopSmoothing() }
    }
}
