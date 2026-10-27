import AppKit
import Observation

/// The state of each system toggle, what the menu bar shows, and running toggles and actions.
@Observable
final class SystemTogglesController {
    /// Last known state of each toggle; refreshed when settings or the menu bar are shown.
    private(set) var states: [SystemToggle: Bool] = [:]

    /// Toggles shown as tiles in the menu bar, in order.
    private(set) var menuBarItems: [SystemToggle]

    /// What went wrong last, by toggle, until it next works.
    private(set) var errors: [SystemToggle: String] = [:]

    /// Actions still running, such as ejecting slow disks.
    private(set) var running: Set<SystemToggle> = []

    static let menuBarItemsKey = "systemToggles.menuBarItems"

    /// How long a value we just wrote beats reading it back. Some settings read back late:
    /// the app's appearance updates after a moment, and Finder settings only once it restarts.
    static let settleTime: TimeInterval = 3

    private let defaults: UserDefaults
    @ObservationIgnored private let system: any SystemSettingsAccess
    /// Asks before an action that can't be undone; returns whether to go ahead.
    @ObservationIgnored private let confirm: @MainActor (SystemToggle) -> Bool
    @ObservationIgnored private var recentWrites: [SystemToggle: (on: Bool, at: Date)] = [:]
    @ObservationIgnored private var themeObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        system: any SystemSettingsAccess = LiveSystemSettings(),
        confirm: @escaping @MainActor (SystemToggle) -> Bool = SystemTogglesController.confirmWithAlert
    ) {
        self.defaults = defaults
        self.system = system
        self.confirm = confirm
        menuBarItems = defaults.stringArray(forKey: Self.menuBarItemsKey)?.compactMap(SystemToggle.init(rawValue:))
            ?? SystemToggle.defaultMenuBarItems
        // Dark mode also changes from Control Center and on a schedule.
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh(now: Date = .now) {
        var states: [SystemToggle: Bool] = [:]
        for toggle in SystemToggle.allCases where !toggle.isAction {
            states[toggle] = currentState(of: toggle, now: now)
        }
        self.states = states
    }

    func isOn(_ toggle: SystemToggle) -> Bool {
        states[toggle] ?? false
    }

    /// The system's value, unless we changed it moments ago and it may not read back yet.
    private func currentState(of toggle: SystemToggle, now: Date) -> Bool? {
        if let write = recentWrites[toggle], now.timeIntervalSince(write.at) < Self.settleTime {
            return write.on
        }
        return system.isOn(toggle)
    }

    /// Flips a toggle or runs an action, as a shortcut or menu bar tile does.
    func perform(_ toggle: SystemToggle, now: Date = .now) async {
        if toggle.isAction {
            await run(toggle)
        } else {
            set(toggle, on: !(currentState(of: toggle, now: now) ?? isOn(toggle)), now: now)
        }
    }

    func set(_ toggle: SystemToggle, on: Bool, now: Date = .now) {
        do {
            try system.set(toggle, on: on)
            states[toggle] = on
            recentWrites[toggle] = (on, now)
            errors[toggle] = nil
        } catch {
            fail(toggle, error)
        }
    }

    func run(_ action: SystemToggle) async {
        guard !running.contains(action), !action.needsConfirmation || confirm(action) else { return }
        running.insert(action)
        defer { running.remove(action) }
        do {
            try await system.run(action)
            errors[action] = nil
        } catch {
            fail(action, error)
        }
    }

    private func fail(_ toggle: SystemToggle, _ error: Error) {
        errors[toggle] = error.localizedDescription
        NSSound.beep()
    }

    // MARK: Menu bar

    func isInMenuBar(_ toggle: SystemToggle) -> Bool {
        menuBarItems.contains(toggle)
    }

    func setInMenuBar(_ toggle: SystemToggle, _ shown: Bool) {
        if shown {
            guard !menuBarItems.contains(toggle) else { return }
            menuBarItems.append(toggle)
        } else {
            menuBarItems.removeAll { $0 == toggle }
        }
        defaults.set(menuBarItems.map(\.rawValue), forKey: Self.menuBarItemsKey)
    }

    /// What a menu bar tile says under its title.
    func status(of toggle: SystemToggle) -> String {
        if toggle.isAction { return running.contains(toggle) ? "Running…" : "Run" }
        return isOn(toggle) ? "On" : "Off"
    }

    static func confirmWithAlert(_ action: SystemToggle) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "Everything in the Trash is deleted for good. This can't be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
