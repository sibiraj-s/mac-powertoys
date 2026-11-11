import AppKit
import IOKit.pwr_mgt
import Observation

@Observable
final class AwakeController {
    /// Starts out unset; people pick their own keys.
    static let toggleShortcut = ShortcutDefinition(id: "awake.toggle", module: .awake, title: "Toggle Awake", defaultHotKey: nil)

    enum Duration: Hashable, CaseIterable, Identifiable {
        case indefinitely, minutes15, minutes30, hour1, hours2, hours4

        var id: Self { self }

        var title: String {
            switch self {
            case .indefinitely: "Indefinitely"
            case .minutes15: "15 minutes"
            case .minutes30: "30 minutes"
            case .hour1: "1 hour"
            case .hours2: "2 hours"
            case .hours4: "4 hours"
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .indefinitely: nil
            case .minutes15: 15 * 60
            case .minutes30: 30 * 60
            case .hour1: 60 * 60
            case .hours2: 2 * 60 * 60
            case .hours4: 4 * 60 * 60
            }
        }
    }

    private(set) var isActive = false
    private(set) var endsAt: Date?

    /// Also stops the display from sleeping, not just the system.
    var keepsDisplayOn: Bool {
        didSet {
            defaults.set(keepsDisplayOn, forKey: Self.keepsDisplayOnKey)
            if isActive { restart() }
            // Swaps the hold to the new type, keeping the old one if macOS refuses; with no hold, this retries one.
            if isHeldByDisplay, let id = makeAssertion() {
                IOPMAssertionRelease(displayAssertionID)
                displayAssertionID = id
            } else {
                updateDisplayHold()
            }
        }
    }

    /// Keeps the Mac awake on its own whenever an external display is connected, apart from any timed session.
    var whileDisplayConnected: Bool {
        didSet {
            defaults.set(whileDisplayConnected, forKey: Self.whileDisplayConnectedKey)
            isDisplayHoldPaused = false
            updateDisplayHold()
        }
    }

    /// Whether a connected external display is what's keeping the Mac awake right now.
    private(set) var isHeldByDisplay = false

    /// Whether the Mac is being kept awake for any reason, by a session or by a display.
    var isKeepingAwake: Bool { isActive || isHeldByDisplay }

    var lastDuration: Duration = .indefinitely

    private let defaults: UserDefaults
    static let keepsDisplayOnKey = "awake.keepsDisplayOn"
    static let whileDisplayConnectedKey = "awake.whileDisplayConnected"

    @ObservationIgnored private let hasExternalDisplay: () -> Bool
    /// A desktop Mac's screens are all external, so holding for them would mean never sleeping.
    @ObservationIgnored let isLaptop: Bool
    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var displayAssertionID: IOPMAssertionID = 0
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var isWatchingDisplays = false
    /// Set when the hold is turned off by hand; lasts until no external display is connected, so
    /// the hold comes back the next time one is plugged in.
    private(set) var isDisplayHoldPaused = false
    /// How long no external display must be seen before it counts as unplugged.
    @ObservationIgnored private let unplugGrace: TimeInterval
    @ObservationIgnored private var unplugCheck: Task<Void, Never>?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    init(
        defaults: UserDefaults = .standard,
        hasExternalDisplay: @escaping () -> Bool = Hardware.hasExternalDisplay,
        isLaptop: Bool = Hardware.isLaptop,
        unplugGrace: TimeInterval = 5
    ) {
        self.unplugGrace = unplugGrace
        self.defaults = defaults
        self.hasExternalDisplay = hasExternalDisplay
        self.isLaptop = isLaptop
        keepsDisplayOn = defaults.bool(forKey: Self.keepsDisplayOnKey)
        whileDisplayConnected = defaults.bool(forKey: Self.whileDisplayConnectedKey)
    }

    /// Follows displays coming and going while the module is on. Also checks again on wake, since a
    /// display unplugged while the Mac slept may not be reported as a screen change.
    func startWatchingDisplays() {
        guard !isWatchingDisplays else { return }
        isWatchingDisplays = true
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didChangeScreenParametersNotification),
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
        ]
        observers = events.map { center, name in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDisplayHold() }
            }
            return (center, token)
        }
        updateDisplayHold()
    }

    func stopWatchingDisplays() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        isWatchingDisplays = false
        isDisplayHoldPaused = false
        unplugCheck?.cancel()
        unplugCheck = nil
        releaseDisplayHold()
    }

    /// Takes or drops the display hold to match the setting and what's connected now.
    func updateDisplayHold() {
        let connected = hasExternalDisplay()
        if connected {
            unplugCheck?.cancel()
            unplugCheck = nil
        } else if isDisplayHoldPaused, unplugCheck == nil {
            // A display can be missing for a moment after wake or a mode change; only a lasting
            // absence counts as unplugged.
            unplugCheck = Task { [weak self, unplugGrace] in
                try? await Task.sleep(for: .seconds(unplugGrace))
                guard !Task.isCancelled, let self else { return }
                unplugCheck = nil
                if !hasExternalDisplay() { isDisplayHoldPaused = false }
            }
        }
        let wanted = isWatchingDisplays && isLaptop && whileDisplayConnected && connected && !isDisplayHoldPaused
        if wanted, !isHeldByDisplay, let id = makeAssertion() {
            displayAssertionID = id
            isHeldByDisplay = true
        } else if !wanted {
            releaseDisplayHold()
        }
    }

    private func releaseDisplayHold() {
        guard isHeldByDisplay else { return }
        IOPMAssertionRelease(displayAssertionID)
        displayAssertionID = 0
        isHeldByDisplay = false
    }

    private func makeAssertion() -> IOPMAssertionID? {
        let type = keepsDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "\(AppInfo.name) Awake" as CFString, &id)
        guard result == kIOReturnSuccess else {
            NSLog("Awake: IOPMAssertionCreateWithName failed (\(result))")
            return nil
        }
        return id
    }

    func toggle() {
        isKeepingAwake ? turnOff() : start(lastDuration)
    }

    /// Lets the Mac sleep again: ends any session and pauses the display hold until the display is unplugged.
    func turnOff() {
        stop()
        // Releases rather than re-evaluating the hold, which could retry one macOS refused earlier.
        if isHeldByDisplay { isDisplayHoldPaused = true }
        releaseDisplayHold()
    }

    func start(_ duration: Duration) {
        lastDuration = duration
        begin(until: duration.interval.map { Date.now.addingTimeInterval($0) })
    }

    /// Stays awake until the next time the clock reads `time`'s hour and minute: today, or tomorrow if that has passed.
    func start(untilTimeOfDay time: Date) {
        begin(until: Self.nextOccurrence(of: time, after: .now))
    }

    static func nextOccurrence(of time: Date, after now: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) ?? now
    }

    private func begin(until deadline: Date?) {
        stop()

        guard let id = makeAssertion() else { return }
        assertionID = id
        isActive = true

        if let deadline {
            endsAt = deadline
            expiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
    }

    func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        if isActive {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        isActive = false
        endsAt = nil
    }

    /// Re-creates the assertion with the current display setting, keeping the original end time.
    private func restart() {
        begin(until: endsAt)
    }
}
