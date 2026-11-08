import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI

@Observable
final class AppState {
    let permissions: PermissionsService
    let shortcuts: Shortcuts
    let awake: AwakeController
    let zones: ZonesController
    let clipboard: ClipboardController
    let systemToggles: SystemTogglesController
    let hosts: HostsController
    let environment: EnvironmentController
    let ports: PortsController
    let launchAgents: LaunchAgentsController
    let colorPicker: ColorPickerController
    let textExtractor: TextExtractorController
    let defaultsBrowser: DefaultsBrowserController
    let scrollMouse: ScrollMouseController
    let keys: KeysController
    let cleaner: CleanerController
    let pinCrop: PinCropController
    let windowSwitcher: WindowSwitcherController
    let displaysAudio: DisplaysAudioController
    let batchRename: BatchRenameController
    let locksmith: LocksmithController
    let finderExtras: FinderExtrasController

    private(set) var enabledModules: Set<ModuleID>

    private let defaults: UserDefaults
    static let enabledModulesKey = "enabledModules"

    init(
        defaults: UserDefaults = .standard,
        permissions: PermissionsService? = nil,
        clipboardStore: URL? = ClipboardController.defaultStoreDirectory,
        hotKeys: any HotKeyRegistering = HotKeyCenter.shared,
        system: any SystemSettingsAccess = LiveSystemSettings(),
        hostsStore: any HostsStore = LiveHostsStore(),
        hostsBackup: URL? = HostsController.defaultBackupURL,
        environment: EnvironmentController? = nil,
        colorSampler: any ColorSampling = LiveColorSampler(),
        regionCapture: any ScreenRegionCapturing = LiveRegionCapture(),
        textReader: any ImageTextReading = LiveImageTextReader(),
        pasteboard: NSPasteboard = .general,
        defaultsStore: any DefaultsStoring = LiveDefaultsStore(),
        defaultsBackups: URL? = DefaultsBrowserController.defaultBackupDirectory,
        cleaner: CleanerController? = nil,
        pinCrop: PinCropController? = nil,
        keyMapping: any KeyMappingStore = LiveKeyMappingStore(),
        windowSwitcher: WindowSwitcherController? = nil,
        displaysAudio: DisplaysAudioController? = nil,
        finder: any FinderAccess = LiveFinder(),
        locksmith: LocksmithController? = nil
    ) {
        self.defaults = defaults
        self.permissions = permissions ?? PermissionsService(defaults: defaults)
        shortcuts = Shortcuts(defaults: defaults, center: hotKeys)
        awake = AwakeController(defaults: defaults)
        zones = ZonesController(defaults: defaults, shortcuts: shortcuts)
        clipboard = ClipboardController(defaults: defaults, storeDirectory: clipboardStore, shortcuts: shortcuts)
        systemToggles = SystemTogglesController(defaults: defaults, system: system)
        hosts = HostsController(store: hostsStore, backupURL: hostsBackup)
        self.environment = environment ?? EnvironmentController()
        ports = PortsController(defaults: defaults)
        launchAgents = LaunchAgentsController(defaults: defaults)
        colorPicker = ColorPickerController(defaults: defaults, sampler: colorSampler, pasteboard: pasteboard)
        let permissions = self.permissions
        textExtractor = TextExtractorController(
            defaults: defaults, capturer: regionCapture, reader: textReader, pasteboard: pasteboard,
            access: ScreenAccess(for: .textExtractor, permissions: permissions)
        )
        defaultsBrowser = DefaultsBrowserController(store: defaultsStore, backupDirectory: defaultsBackups)
        scrollMouse = ScrollMouseController(defaults: defaults, isTrusted: { permissions.currentStatus(.accessibility) == .granted })
        keys = KeysController(
            defaults: defaults, mappingStore: keyMapping, isTrusted: { permissions.currentStatus(.accessibility) == .granted })
        self.cleaner = cleaner ?? CleanerController(defaults: defaults)
        self.pinCrop =
            pinCrop
            ?? PinCropController(access: ScreenAccess(for: .pinCrop, permissions: permissions))
        self.windowSwitcher = windowSwitcher ?? WindowSwitcherController(defaults: defaults, shortcuts: shortcuts)
        self.displaysAudio = displaysAudio ?? Self.makeDisplaysAudio(defaults: defaults, permissions: permissions)
        batchRename = BatchRenameController(defaults: defaults, finder: finder)
        self.locksmith = locksmith ?? LocksmithController(finder: finder)
        finderExtras = FinderExtrasController(defaults: defaults, finder: finder, pasteboard: pasteboard)
        if let stored = defaults.stringArray(forKey: Self.enabledModulesKey) {
            enabledModules = Set(stored.compactMap(ModuleID.init(rawValue:)))
        } else {
            // First launch: only modules that need no permission are on, so nothing prompts unasked.
            enabledModules = Set(ModuleCatalog.all.filter { $0.isImplemented && $0.permissions.isEmpty }.map(\.id))
        }
        if enabledModules.contains(.zones) { zones.start() }
        if enabledModules.contains(.clipboard) { clipboard.start() }
        if enabledModules.contains(.scrollMouse) { scrollMouse.start() }
        if enabledModules.contains(.keys) { keys.start() }
        if enabledModules.contains(.displaysAudio) { self.displaysAudio.start() }
        updateModuleShortcuts()
    }

    /// Awake, System Toggles, Color Picker, Text Extractor, Pin & Crop, Window Switcher, Displays & Audio and Finder Extras register no shortcuts of their own, so their shortcuts
    /// follow the module switch here.
    private func updateModuleShortcuts() {
        var simple: [(ModuleID, ShortcutDefinition, () -> Void)] = [
            (.awake, AwakeController.toggleShortcut, { [weak self] in self?.awake.toggle() }),
            (.colorPicker, ColorPickerController.pickShortcut, { [weak self] in Task { await self?.colorPicker.pick() } }),
            (.textExtractor, TextExtractorController.extractShortcut, { [weak self] in Task { await self?.textExtractor.extract() } }),
            (.pinCrop, PinCropController.pinShortcut, { [weak self] in Task { await self?.pinCrop.pick() } }),
            (.windowSwitcher, WindowSwitcherController.switchShortcut, { [weak self] in self?.windowSwitcher.trigger() }),
            (.displaysAudio, DisplaysAudioController.muteShortcut, { [weak self] in self?.displaysAudio.toggleMicMute() }),
            (.displaysAudio, DisplaysAudioController.nextOutputShortcut, { [weak self] in self?.displaysAudio.selectNextOutput() }),
            (
                .displaysAudio, DisplaysAudioController.brightnessUpShortcut,
                { [weak self] in self?.displaysAudio.externalDisplays.step(.up) }
            ),
            (
                .displaysAudio, DisplaysAudioController.brightnessDownShortcut,
                { [weak self] in self?.displaysAudio.externalDisplays.step(.down) }
            ),
        ]
        for action in FinderExtrasController.Action.allCases {
            simple.append((.finderExtras, action.shortcut, { [weak self] in Task { await self?.finderExtras.perform(action) } }))
        }
        for toggle in SystemToggle.allCases {
            simple.append((.systemToggles, toggle.shortcut, { [weak self] in Task { await self?.systemToggles.perform(toggle) } }))
        }
        for (module, shortcut, action) in simple {
            if isEnabled(module) {
                if !shortcuts.isActive(shortcut) { shortcuts.activate(shortcut, action: action) }
            } else {
                shortcuts.deactivate(shortcut)
            }
        }
    }

    /// An action chosen in Finder's menu, run only while Finder Extras is on.
    func handleFinderMenu(_ request: FinderMenuRequest) {
        guard isEnabled(.finderExtras) else { return }
        Task { await finderExtras.perform(request.action, on: FinderMenuSnapshot(request: request)) }
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
        case .pinCrop where !enabled: pinCrop.stop()
        case .windowSwitcher where !enabled: windowSwitcher.cancel()
        case .zones: enabled ? zones.start() : zones.stop()
        case .clipboard: enabled ? clipboard.start() : clipboard.stop()
        case .scrollMouse: enabled ? scrollMouse.start() : scrollMouse.stop()
        case .keys: enabled ? keys.start() : keys.stop()
        case .displaysAudio: enabled ? displaysAudio.start() : displaysAudio.stop()
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

extension AppState {
    /// The live Displays & Audio module, made only when one isn't passed in.
    fileprivate static func makeDisplaysAudio(defaults: UserDefaults, permissions: PermissionsService) -> DisplaysAudioController {
        let audioDevices = LiveAudioDevices(defaults: defaults)
        return DisplaysAudioController(
            devices: audioDevices,
            appVolume: AppVolumeController(
                defaults: defaults,
                access: { permissions.currentStatus(.audioCapture) },
                // Straight to macOS: its check can say "not asked" after access was allowed, and then
                // a second request through the permissions service would open System Settings unasked.
                requestAccess: { AudioCaptureAccess.request(answered: $0) },
                openAccessSettings: { permissions.openSettings(for: .audioCapture) }),
            externalDisplays: ExternalDisplaysController(
                defaults: defaults, outputNeedsDDC: { audioDevices.outputNeedsDDC() },
                isTrusted: { permissions.currentStatus(.accessibility) == .granted }))
    }
}
