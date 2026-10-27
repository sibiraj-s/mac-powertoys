import Foundation
import Observation
import ServiceManagement
import SwiftUI

@Observable
final class AppState {
    let permissions = PermissionsService()
    let shortcuts: Shortcuts
    let awake: AwakeController
    let zones: ZonesController
    let clipboard: ClipboardController

    private(set) var enabledModules: Set<ModuleID>

    private let defaults: UserDefaults
    static let enabledModulesKey = "enabledModules"

    init(
        defaults: UserDefaults = .standard,
        clipboardStore: URL? = ClipboardController.defaultStoreDirectory,
        hotKeys: any HotKeyRegistering = HotKeyCenter.shared
    ) {
        self.defaults = defaults
        shortcuts = Shortcuts(defaults: defaults, center: hotKeys)
        awake = AwakeController(defaults: defaults)
        zones = ZonesController(defaults: defaults, shortcuts: shortcuts)
        clipboard = ClipboardController(defaults: defaults, storeDirectory: clipboardStore, shortcuts: shortcuts)
        if let stored = defaults.stringArray(forKey: Self.enabledModulesKey) {
            enabledModules = Set(stored.compactMap(ModuleID.init(rawValue:)))
        } else {
            // First launch: only modules that need no permission are on, so nothing prompts unasked.
            enabledModules = Set(ModuleCatalog.all.filter { $0.isImplemented && $0.permissions.isEmpty }.map(\.id))
        }
        if enabledModules.contains(.zones) { zones.start() }
        if enabledModules.contains(.clipboard) { clipboard.start() }
        updateModuleShortcuts()
    }

    /// Awake and System Toggles have no controller lifecycle of their own, so their shortcuts
    /// follow the module switch here.
    private func updateModuleShortcuts() {
        let simple: [(ModuleID, ShortcutDefinition, () -> Void)] = [
            (.awake, AwakeController.toggleShortcut, { [weak self] in self?.awake.toggle() }),
            (.systemToggles, SystemToggles.darkModeShortcut, { SystemToggles.toggleDarkMode() }),
        ]
        for (module, shortcut, action) in simple {
            if isEnabled(module) {
                if !shortcuts.isActive(shortcut) { shortcuts.activate(shortcut, action: action) }
            } else {
                shortcuts.deactivate(shortcut)
            }
        }
    }

    var enabledCount: Int { enabledModules.count }

    func isEnabled(_ id: ModuleID) -> Bool {
        enabledModules.contains(id)
    }

    func setEnabled(_ id: ModuleID, _ enabled: Bool) {
        if enabled {
            enabledModules.insert(id)
            // Permissions are requested when a module is turned on, never up front.
            for permission in ModuleCatalog.descriptor(id).permissions
            where permissions.status(permission) == .denied {
                permissions.request(permission)
            }
        } else {
            enabledModules.remove(id)
        }
        switch id {
        case .awake where !enabled: awake.stop()
        case .zones: enabled ? zones.start() : zones.stop()
        case .clipboard: enabled ? clipboard.start() : clipboard.stop()
        default: break
        }
        updateModuleShortcuts()
        defaults.set(enabledModules.map(\.rawValue).sorted(), forKey: Self.enabledModulesKey)
    }

    func binding(for id: ModuleID) -> Binding<Bool> {
        Binding(get: { self.isEnabled(id) }, set: { self.setEnabled(id, $0) })
    }

    // MARK: Launch at login

    var launchesAtLogin: Bool {
        get {
            access(keyPath: \.launchesAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchesAtLogin) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("Launch at login change failed: \(error)")
                }
            }
        }
    }
}
