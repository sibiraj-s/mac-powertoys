import Foundation
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
        }
    }

    var lastDuration: Duration = .indefinitely

    private let defaults: UserDefaults
    static let keepsDisplayOnKey = "awake.keepsDisplayOn"

    private var assertionID: IOPMAssertionID = 0
    private var expiryTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepsDisplayOn = defaults.bool(forKey: Self.keepsDisplayOnKey)
    }

    func toggle() {
        isActive ? stop() : start(lastDuration)
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

        let type = keepsDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "PowerToys Awake" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            NSLog("Awake: IOPMAssertionCreateWithName failed (\(result))")
            return
        }
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
