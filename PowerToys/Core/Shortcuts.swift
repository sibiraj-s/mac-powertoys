import AppKit
import Carbon.HIToolbox
import Observation

/// A shortcut a module offers, with the keys it starts out with.
struct ShortcutDefinition: Identifiable, Hashable {
    /// Stable across launches, such as "zones.nextZone"; customized keys are saved under it.
    let id: String
    let module: ModuleID
    let title: String
    /// nil when the shortcut starts out unset.
    let defaultHotKey: HotKey?
}

/// Every shortcut in the app, for spotting two actions on the same keys.
enum ShortcutCatalog {
    static var all: [ShortcutDefinition] {
        ZonesController.Action.allCases.map(\.shortcut)
            + ClipboardController.Action.allCases.map(\.shortcut)
            + [AwakeController.toggleShortcut]
            + SystemToggle.allCases.map(\.shortcut)
            + [ColorPickerController.pickShortcut]
    }
}

/// The keys for each shortcut, as customized, and their registration with the system while their
/// module is on.
@Observable
final class Shortcuts {
    /// Shortcut IDs whose keys another app already holds.
    private(set) var unavailable: Set<String> = []

    /// Customized keys by shortcut ID; a nil value means the user turned the shortcut off.
    private var overrides: [String: HotKey?]

    private let defaults: UserDefaults
    private let catalog: [ShortcutDefinition]
    @ObservationIgnored private let center: any HotKeyRegistering
    @ObservationIgnored private var active: [String: Active] = [:]
    @ObservationIgnored private var isSuspended = false

    private struct Active {
        let definition: ShortcutDefinition
        let action: () -> Void
        var registration: HotKeyCenter.Registration?
    }

    static let defaultsKey = "shortcuts"

    init(defaults: UserDefaults = .standard, catalog: [ShortcutDefinition] = ShortcutCatalog.all, center: any HotKeyRegistering = HotKeyCenter.shared) {
        self.defaults = defaults
        self.catalog = catalog
        self.center = center
        overrides = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: HotKey?].self, from: $0) }
            ?? [:]
    }

    // MARK: Keys

    func hotKey(for definition: ShortcutDefinition) -> HotKey? {
        if let override = overrides[definition.id] { return override }
        return definition.defaultHotKey
    }

    func isCustomized(_ definition: ShortcutDefinition) -> Bool {
        overrides.keys.contains(definition.id)
    }

    /// Sets new keys, or turns the shortcut off with nil.
    func set(_ hotKey: HotKey?, for definition: ShortcutDefinition) {
        if hotKey == definition.defaultHotKey {
            overrides.removeValue(forKey: definition.id)
        } else {
            overrides[definition.id] = .some(hotKey)
        }
        save()
        reregister(definition.id)
    }

    func reset(_ definition: ShortcutDefinition) {
        overrides.removeValue(forKey: definition.id)
        save()
        reregister(definition.id)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(overrides), forKey: Self.defaultsKey)
    }

    /// Why `hotKey` can't be used for `definition`, or nil if it can.
    func problem(with hotKey: HotKey, for definition: ShortcutDefinition) -> String? {
        let modifiers = hotKey.modifiers
        if modifiers.isDisjoint(with: [.command, .control, .option]) && !hotKey.isFunctionKey {
            return "Add ⌘, ⌃ or ⌥ so it doesn't get in the way of typing."
        }
        if let use = Self.systemShortcuts[hotKey] {
            return "macOS uses this for \(use)."
        }
        if modifiers == .command && !hotKey.isFunctionKey {
            return "Apps use ⌘ with a single key for their own commands. Add ⌃, ⌥ or ⇧."
        }
        if let other = catalog.first(where: { $0.id != definition.id && self.hotKey(for: $0) == hotKey }) {
            let module = ModuleCatalog.descriptor(other.module).name
            return "Already used for “\(other.title)” in \(module)."
        }
        return nil
    }

    /// What a row should say about its shortcut: a problem with just-recorded keys, or that
    /// another app holds them. nil when all is well.
    func hint(for definition: ShortcutDefinition, problem: String?) -> String? {
        if let problem { return problem }
        if unavailable.contains(definition.id) { return "Another app is using this shortcut." }
        return nil
    }

    private static let systemShortcuts: [HotKey: String] = [
        HotKey(keyCode: kVK_Space, modifiers: .command, key: "Space"): "Spotlight",
        HotKey(keyCode: kVK_Space, modifiers: .control, key: "Space"): "switching input sources",
        HotKey(keyCode: kVK_Space, modifiers: [.command, .option], key: "Space"): "Finder search",
        HotKey(keyCode: kVK_ANSI_3, modifiers: [.command, .shift], key: "3"): "screenshots",
        HotKey(keyCode: kVK_ANSI_4, modifiers: [.command, .shift], key: "4"): "screenshots",
        HotKey(keyCode: kVK_ANSI_5, modifiers: [.command, .shift], key: "5"): "screenshots",
        HotKey(keyCode: kVK_UpArrow, modifiers: .control, key: "↑"): "Mission Control",
        HotKey(keyCode: kVK_DownArrow, modifiers: .control, key: "↓"): "App Exposé",
        HotKey(keyCode: kVK_LeftArrow, modifiers: .control, key: "←"): "switching Spaces",
        HotKey(keyCode: kVK_RightArrow, modifiers: .control, key: "→"): "switching Spaces",
        HotKey(keyCode: kVK_ANSI_Q, modifiers: [.command, .control], key: "Q"): "locking the screen",
    ]

    // MARK: Registration

    /// Listens for the shortcut until `deactivate`, following any later changes to its keys.
    func activate(_ definition: ShortcutDefinition, action: @escaping () -> Void) {
        deactivate(definition)
        active[definition.id] = Active(definition: definition, action: action)
        register(definition.id)
    }

    func deactivate(_ definition: ShortcutDefinition) {
        unregister(definition.id)
        active[definition.id] = nil
        unavailable.remove(definition.id)
    }

    func isActive(_ definition: ShortcutDefinition) -> Bool {
        active[definition.id] != nil
    }

    /// Lets every shortcut through to the app while one is being recorded; otherwise pressing
    /// keys that are already taken would trigger them instead of recording them.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        active.keys.forEach(unregister)
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        active.keys.forEach(register)
    }

    private func reregister(_ id: String) {
        unregister(id)
        register(id)
    }

    private func register(_ id: String) {
        guard !isSuspended, let entry = active[id] else { return }
        guard let hotKey = hotKey(for: entry.definition) else {
            unavailable.remove(id)
            return
        }
        if let registration = center.register(hotKey, action: entry.action) {
            active[id]?.registration = registration
            unavailable.remove(id)
        } else {
            unavailable.insert(id)
        }
    }

    private func unregister(_ id: String) {
        guard let registration = active[id]?.registration else { return }
        center.unregister(registration)
        active[id]?.registration = nil
    }
}
