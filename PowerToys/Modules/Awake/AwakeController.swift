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

    private(set) var isActive = false {
        didSet { if isActive != oldValue { updateLidSleep() } }
    }
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
    private(set) var isHeldByDisplay = false {
        didSet { if isHeldByDisplay != oldValue { updateLidSleep() } }
    }

    /// Keeps a laptop awake with its lid closed too, while Awake is keeping it awake. Turned on
    /// with `setKeepsAwakeWithLidClosed`, which registers the helper that does it.
    private(set) var keepsAwakeWithLidClosed: Bool
    /// Why the lid-closed setting couldn't be turned on or applied, until it next works.
    private(set) var lidClosedProblem: String?
    /// Whether the lid-closed setting is held off during a session because the battery is low, until the Mac is plugged in.
    private(set) var isLidClosedPausedForBattery = false
    /// The battery went low with the setting on; lasts across sessions until the Mac is on power.
    @ObservationIgnored private var isBatteryPaused = false
    /// Whether Awake has system sleep turned off right now.
    @ObservationIgnored private var isSleepDisabled = false
    /// Below this charge on battery, the Mac can sleep with its lid closed again, so it isn't run flat in a bag.
    static let lowBatteryPercent = 20

    /// Whether the Mac is being kept awake for any reason, by a session or by a display.
    var isKeepingAwake: Bool { isActive || isHeldByDisplay }

    var lastDuration: Duration = .indefinitely

    private let defaults: UserDefaults
    static let keepsDisplayOnKey = "awake.keepsDisplayOn"
    static let whileDisplayConnectedKey = "awake.whileDisplayConnected"
    static let keepsAwakeWithLidClosedKey = "awake.keepsAwakeWithLidClosed"

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
    @ObservationIgnored private let lidSleep: any LidSleepControl
    @ObservationIgnored private let batteryPercent: () -> Int?
    @ObservationIgnored private let sleepIfLidClosed: () -> Void
    @ObservationIgnored private var powerWatcher: PowerSourceWatcher?
    /// Tries a failed release again, for when no power change comes along to.
    @ObservationIgnored private var releaseRetry: Task<Void, Never>?
    @ObservationIgnored private let releaseRetryDelay: Swift.Duration

    init(
        defaults: UserDefaults = .standard,
        // No default, so a test can't reach the real helper (and unregister it) by accident.
        lidSleep: any LidSleepControl,
        hasExternalDisplay: @escaping () -> Bool = Hardware.hasExternalDisplay,
        isLaptop: Bool = Hardware.isLaptop,
        unplugGrace: TimeInterval = 5,
        batteryPercent: @escaping () -> Int? = Hardware.batteryPercentOnBattery,
        sleepIfLidClosed: @escaping () -> Void = Hardware.sleepIfLidClosed,
        releaseRetryDelay: Swift.Duration = .seconds(30)
    ) {
        self.releaseRetryDelay = releaseRetryDelay
        self.unplugGrace = unplugGrace
        self.defaults = defaults
        self.hasExternalDisplay = hasExternalDisplay
        self.isLaptop = isLaptop
        self.lidSleep = lidSleep
        self.batteryPercent = batteryPercent
        self.sleepIfLidClosed = sleepIfLidClosed
        keepsDisplayOn = defaults.bool(forKey: Self.keepsDisplayOnKey)
        whileDisplayConnected = defaults.bool(forKey: Self.whileDisplayConnectedKey)
        keepsAwakeWithLidClosed = defaults.bool(forKey: Self.keepsAwakeWithLidClosedKey)
        // Removed or turned off in System Settings since: the switch shows off rather than failing every session.
        if keepsAwakeWithLidClosed, !lidSleep.isAllowed {
            keepsAwakeWithLidClosed = false
            defaults.set(false, forKey: Self.keepsAwakeWithLidClosedKey)
        }
        // With the switch off, no root helper stays registered, such as one approved in System Settings
        // without the switch being turned on again afterwards.
        if !keepsAwakeWithLidClosed { lidSleep.disallow() }
        lidSleep.onInterrupted = { [weak self] in self?.helperRestarted() }
    }

    /// Turning it on registers the helper, which stays off until it's allowed in System Settings;
    /// turning it off unregisters it. The helper itself turns sleep back on if the app quits or crashes.
    func setKeepsAwakeWithLidClosed(_ on: Bool) {
        lidClosedProblem = nil
        if on, !lidSleep.isAllowed {
            do {
                try lidSleep.allow()
            } catch {
                lidClosedProblem = error.localizedDescription
                return
            }
        }
        let wasHolding = isSleepDisabled
        keepsAwakeWithLidClosed = on
        defaults.set(on, forKey: Self.keepsAwakeWithLidClosedKey)
        updateLidSleep()
        // A hold is let go first, and `updateLidSleep` unregisters once that works, since only the
        // helper can turn sleep back on.
        if !on, !wasHolding { lidSleep.disallow() }
    }

    /// Follows the battery only while the lid-closed setting is in use.
    private func updatePowerWatcher(_ applies: Bool) {
        if applies {
            if powerWatcher == nil { powerWatcher = PowerSourceWatcher { [weak self] in self?.powerSourceChanged() } }
        } else {
            powerWatcher = nil
        }
    }

    func powerSourceChanged() {
        updateLidSleep()
    }

    /// A restarted helper turns sleep back on, so it's taken again if Awake still wants it.
    func helperRestarted() {
        isSleepDisabled = false
        if !lidSleep.isAllowed, keepsAwakeWithLidClosed {
            // Turned off in System Settings, which stops the helper.
            keepsAwakeWithLidClosed = false
            defaults.set(false, forKey: Self.keepsAwakeWithLidClosedKey)
            lidClosedProblem = "The helper was turned off in System Settings, so this is off too."
        }
        updateLidSleep()
        // A release still waiting for a retry when the switch was turned off is done now.
        if !keepsAwakeWithLidClosed { lidSleep.disallow() }
    }

    /// Turns sleep off while Awake is keeping the Mac awake with the lid-closed setting on, and back
    /// on otherwise, or when the battery runs low.
    private func updateLidSleep() {
        let applies = isLaptop && keepsAwakeWithLidClosed && isKeepingAwake
        // Once paused, it stays paused until the Mac is on power, not when a reading creeps back up
        // or a new session starts.
        if isLaptop, keepsAwakeWithLidClosed {
            let percent = batteryPercent()
            isBatteryPaused = percent.map { $0 < Self.lowBatteryPercent || isBatteryPaused } ?? false
        }
        let lowBattery = applies && isBatteryPaused
        if isLidClosedPausedForBattery != lowBattery { isLidClosedPausedForBattery = lowBattery }
        let wanted = applies && !lowBattery
        // Power changes also retry a release that failed, so the watcher stays until one works.
        defer { updatePowerWatcher(applies || isSleepDisabled) }
        guard wanted != isSleepDisabled else { return }
        let worked = lidSleep.setSleepDisabled(wanted)
        // Failing to take the hold leaves sleep on, to be tried afresh next time. Failing to let go
        // may have left it off, so letting go is retried on each power change until it works.
        isSleepDisabled = worked ? wanted : !wanted
        releaseRetry?.cancel()
        releaseRetry = nil
        if !worked, !wanted {
            releaseRetry = Task { [weak self, releaseRetryDelay] in
                try? await Task.sleep(for: releaseRetryDelay)
                guard !Task.isCancelled, let self else { return }
                releaseRetry = nil
                // A helper that's gone turned sleep back on as it went, so there's nothing left to retry.
                if lidSleep.isAllowed { updateLidSleep() } else { helperRestarted() }
            }
        }
        lidClosedProblem =
            worked
            ? nil
            : wanted
                ? "Couldn't keep the Mac awake with the lid closed. Check that \(AppInfo.name) is allowed under Login Items & Extensions in System Settings."
                : "Couldn't confirm the Mac can sleep with its lid closed again. If it doesn't, run `sudo pmset -a disablesleep 0` in Terminal."
        guard !wanted else { return }
        // Letting it sleep again doesn't send an already closed laptop to sleep on its own, whether the
        // session ended or the battery ran low. A failed release usually still lets it, as the dropped
        // connection ends the hold. Not when the switch was only turned off mid-session: the session
        // goes on. With an external display it's in clamshell use, so it stays up.
        if !isKeepingAwake || lowBattery, !hasExternalDisplay() { sleepIfLidClosed() }
        // The switch was turned off while the hold was still out.
        if worked, !keepsAwakeWithLidClosed { lidSleep.disallow() }
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

    /// Replaces a running session without stopping it first, so the lid-closed hold isn't let go in between.
    private func begin(until deadline: Date?) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let id = makeAssertion() else {
            stop()
            return
        }
        if isActive { IOPMAssertionRelease(assertionID) }
        assertionID = id
        endsAt = deadline
        isActive = true

        if let deadline {
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
