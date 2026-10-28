import Carbon.HIToolbox
import Foundation
import Testing
@testable import PowerToys

/// Keeps settings in memory instead of changing the Mac's.
final class FakeSystemSettings: SystemSettingsAccess {
    var values: [SystemToggle: Bool] = [:]
    var unavailable: Set<SystemToggle> = []
    var failing: Set<SystemToggle> = []
    /// Reads keep returning the old value, like the app's appearance right after a change.
    var readsLag = false
    private(set) var runs: [SystemToggle] = []
    /// Held actions don't finish until `release()`.
    var holdsActions = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var lagged: [SystemToggle: Bool] = [:]

    func isOn(_ toggle: SystemToggle) -> Bool? {
        guard !toggle.isAction, !unavailable.contains(toggle) else { return nil }
        if readsLag, let old = lagged[toggle] { return old }
        return values[toggle] ?? false
    }

    func set(_ toggle: SystemToggle, on: Bool) throws {
        if failing.contains(toggle) { throw SystemSettingsError(errorDescription: "Nope") }
        if lagged[toggle] == nil { lagged[toggle] = values[toggle] ?? false }
        values[toggle] = on
    }

    func run(_ action: SystemToggle) async throws {
        if failing.contains(action) { throw SystemSettingsError(errorDescription: "Nope") }
        runs.append(action)
        if holdsActions {
            await withCheckedContinuation { held.append($0) }
        }
    }

    func release() {
        held.forEach { $0.resume() }
        held = []
    }
}

/// Lets tasks the code under test started, such as a shortcut's, run until `condition` holds.
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

struct SystemToggleTests {
    @Test func everyToggleIsInExactlyOneGroup() {
        let grouped = SystemToggle.Group.allCases.flatMap(\.toggles)
        #expect(grouped.count == SystemToggle.allCases.count)
        #expect(Set(grouped) == Set(SystemToggle.allCases))
    }

    @Test func onlyActionsAreActions() {
        let actions = SystemToggle.allCases.filter { $0.isAction }
        #expect(actions == SystemToggle.Group.actions.toggles)
        #expect(SystemToggle.allCases.filter(\.needsConfirmation) == [.emptyTrash])
    }

    @Test func shortcuts() {
        let ids = SystemToggle.allCases.map(\.shortcut.id)
        #expect(Set(ids).count == ids.count)
        // Kept from before, so a customized dark mode shortcut survives.
        #expect(SystemToggle.darkMode.shortcut.id == "systemToggles.darkMode")
        #expect(SystemToggle.darkMode.shortcut.title == "Toggle dark mode")
        #expect(SystemToggle.wifi.shortcut.title == "Toggle Wi‑Fi")
        #expect(SystemToggle.emptyTrash.shortcut.title == "Empty Trash")
    }

    @Test func copyIsFilledIn() {
        for toggle in SystemToggle.allCases {
            #expect(!toggle.title.isEmpty && !toggle.shortTitle.isEmpty && !toggle.hint.isEmpty && !toggle.symbol.isEmpty)
        }
    }
}

struct SystemTogglesControllerTests {
    private let store = TestDefaults()
    private let system = FakeSystemSettings()

    private func controller(confirm: @escaping @MainActor (SystemToggle) -> Bool = { _ in true }) -> SystemTogglesController {
        SystemTogglesController(defaults: store.defaults, system: system, confirm: confirm)
    }

    @Test func refreshReadsToggles() {
        system.values = [.darkMode: true]
        system.unavailable = [.wifi]
        let toggles = controller()
        toggles.refresh()
        #expect(toggles.isOn(.darkMode))
        #expect(!toggles.isOn(.hideDock))
        #expect(toggles.states[.wifi] == nil)
        #expect(toggles.states[.emptyTrash] == nil)
    }

    @Test func performFlipsTheCurrentState() async {
        let toggles = controller()
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        await toggles.perform(.hideDock, now: start)
        #expect(system.values[.hideDock] == true)
        #expect(toggles.isOn(.hideDock))

        // Changed elsewhere since: once our write has settled, perform follows the real state.
        system.values[.hideDock] = false
        await toggles.perform(.hideDock, now: start.addingTimeInterval(SystemTogglesController.settleTime + 1))
        #expect(system.values[.hideDock] == true)
    }

    @Test func quickRepeatsDontTripOverLateReads() async {
        system.readsLag = true
        let toggles = controller()
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        await toggles.perform(.darkMode, now: start)
        await toggles.perform(.darkMode, now: start.addingTimeInterval(0.3))
        #expect(system.values[.darkMode] == false)   // on, then off again

        await toggles.perform(.darkMode, now: start.addingTimeInterval(0.6))
        toggles.refresh(now: start.addingTimeInterval(1))
        #expect(toggles.isOn(.darkMode))   // the lagging read doesn't undo what we just set
    }

    @Test func actionsRun() async {
        let toggles = controller()
        await toggles.perform(.sleepDisplay)
        await toggles.run(.ejectDisks)
        #expect(system.runs == [.sleepDisplay, .ejectDisks])
    }

    @Test func anActionDoesntStartTwice() async {
        system.holdsActions = true
        let toggles = controller()
        let first = Task { await toggles.run(.ejectDisks) }
        await waitUntil { toggles.running.contains(.ejectDisks) }
        #expect(toggles.status(of: .ejectDisks) == "Running…")

        await toggles.run(.ejectDisks)   // ignored while the first is running
        #expect(system.runs == [.ejectDisks])

        system.release()
        await first.value
        #expect(toggles.running.isEmpty)
        #expect(toggles.status(of: .ejectDisks) == "Run")
    }

    @Test func emptyTrashAsksFirst() async {
        final class Prompt {
            var asked: [SystemToggle] = []
            var answer = false
        }
        let prompt = Prompt()
        let toggles = controller { prompt.asked.append($0); return prompt.answer }
        await toggles.perform(.emptyTrash)
        #expect(system.runs.isEmpty)
        prompt.answer = true
        await toggles.perform(.emptyTrash)
        #expect(system.runs == [.emptyTrash])
        #expect(prompt.asked == [.emptyTrash, .emptyTrash])

        await toggles.perform(.startScreenSaver)
        #expect(prompt.asked.count == 2)
    }

    @Test func failedActionsAreShown() async {
        system.failing = [.ejectDisks]
        let toggles = controller()
        await toggles.run(.ejectDisks)
        #expect(toggles.errors[.ejectDisks] == "Nope")
        system.failing = []
        await toggles.run(.ejectDisks)
        #expect(toggles.errors[.ejectDisks] == nil)
    }

    @Test func failuresAreShownUntilItWorks() {
        system.failing = [.darkMode]
        let toggles = controller()
        toggles.set(.darkMode, on: true)
        #expect(toggles.errors[.darkMode] == "Nope")
        #expect(!toggles.isOn(.darkMode))

        system.failing = []
        toggles.set(.darkMode, on: true)
        #expect(toggles.errors[.darkMode] == nil)
        #expect(toggles.isOn(.darkMode))
    }

    @Test func menuBarItemsPersistInOrder() {
        let toggles = controller()
        #expect(toggles.menuBarItems == SystemToggle.defaultMenuBarItems)
        toggles.setInMenuBar(.wifi, true)
        toggles.setInMenuBar(.darkMode, false)
        toggles.setInMenuBar(.wifi, true)   // already there
        toggles.setInMenuBar(.emptyTrash, true)

        let reloaded = controller()
        #expect(reloaded.menuBarItems == [.hideDesktopIcons, .wifi, .emptyTrash])
        #expect(reloaded.isInMenuBar(.wifi))
        #expect(!reloaded.isInMenuBar(.darkMode))
    }

    @Test func tileStatus() {
        system.values = [.wifi: true]
        let toggles = controller()
        toggles.refresh()
        #expect(toggles.status(of: .wifi) == "On")
        #expect(toggles.status(of: .hideDock) == "Off")
        #expect(toggles.status(of: .emptyTrash) == "Run")
    }

    @Test func shortcutsRunTogglesWhileTheModuleIsOn() async throws {
        let center = FakeHotKeys()
        let state = AppState.testing(defaults: store.defaults, hotKeys: center, system: system)
        let keys = HotKey(keyCode: kVK_ANSI_D, modifiers: [.control, .option], key: "D")
        state.shortcuts.set(keys, for: SystemToggle.darkMode.shortcut)
        state.setEnabled(.systemToggles, true)
        center.press(keys)
        await waitUntil { system.values[.darkMode] == true }
        #expect(system.values[.darkMode] == true)
        center.press(keys)
        await waitUntil { system.values[.darkMode] == false }
        #expect(system.values[.darkMode] == false)

        state.setEnabled(.systemToggles, false)
        center.press(keys)
        await waitUntil { system.values[.darkMode] == true }
        #expect(system.values[.darkMode] == false)
    }
}

struct PreferencesTests {
    @Test func readsAndWritesAnotherDomain() {
        let domain = "dev.sibiraj.powertoys.tests.\(UUID().uuidString)"
        #expect(Preferences.bool("flag", in: domain) == nil)
        Preferences.set(true, for: "flag", in: domain)
        #expect(Preferences.bool("flag", in: domain) == true)
        Preferences.set(false, for: "flag", in: domain)
        #expect(Preferences.bool("flag", in: domain) == false)
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
    }
}
