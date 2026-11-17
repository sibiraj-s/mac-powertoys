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
    let lanes: LanesController
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
    let apps: AppsController
    let pinCrop: PinCropController
    let windowSwitcher: WindowSwitcherController
    let displaysAudio: DisplaysAudioController
    let batchRename: BatchRenameController
    let locksmith: LocksmithController
    let finderExtras: FinderExtrasController
    let screenRuler: ScreenRulerController
    let network: NetworkController
    let networkInfo: NetworkInfoController
    let bandwidth: BandwidthController
    let networkSpeed: NetworkSpeedMonitor

    private(set) var enabledModules: Set<ModuleID>

    private let defaults: UserDefaults
    static let enabledModulesKey = "enabledModules"

    init(
        defaults: UserDefaults = .standard,
        lidSleep: any LidSleepControl = LidSleepClient(),
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
        apps: AppsController? = nil,
        pinCrop: PinCropController? = nil,
        keyMapping: any KeyMappingStore = LiveKeyMappingStore(),
        windowSwitcher: WindowSwitcherController? = nil,
        displaysAudio: DisplaysAudioController? = nil,
        finder: any FinderAccess = LiveFinder(),
        locksmith: LocksmithController? = nil,
        screenRuler: ScreenRulerController? = nil,
        laneWindows: (any LaneWindowSystem)? = nil,
        networkHelper: (any NetworkPrivileges)? = nil,
        networkReader: (any NetworkReading)? = nil,
        networkInfo: NetworkInfoController? = nil
    ) {
        self.defaults = defaults
        self.permissions = permissions ?? PermissionsService(defaults: defaults)
        shortcuts = Shortcuts(defaults: defaults, center: hotKeys)
        awake = AwakeController(defaults: defaults, lidSleep: lidSleep)
        zones = ZonesController(defaults: defaults, shortcuts: shortcuts)
        clipboard = ClipboardController(defaults: defaults, storeDirectory: clipboardStore, shortcuts: shortcuts)
        systemToggles = SystemTogglesController(defaults: defaults, system: system)
        hosts = HostsController(store: hostsStore, backupURL: hostsBackup)
        self.environment = environment ?? EnvironmentController()
        ports = PortsController(defaults: defaults)
        launchAgents = LaunchAgentsController(defaults: defaults)
        colorPicker = ColorPickerController(defaults: defaults, sampler: colorSampler, pasteboard: pasteboard)
        let permissions = self.permissions
        let isTrusted = { permissions.currentStatus(.accessibility) == .granted }
        lanes = LanesController(
            defaults: defaults, shortcuts: shortcuts, windows: laneWindows ?? LiveLaneWindows(isTrusted: isTrusted),
            isTrusted: isTrusted, overview: laneWindows == nil ? LaneOverviewPanel() : nil,
            dropZone: laneWindows == nil ? LaneDropPanel() : nil)
        textExtractor = TextExtractorController(
            defaults: defaults, capturer: regionCapture, reader: textReader, pasteboard: pasteboard,
            access: ScreenAccess(for: .textExtractor, permissions: permissions)
        )
        defaultsBrowser = DefaultsBrowserController(store: defaultsStore, backupDirectory: defaultsBackups)
        scrollMouse = ScrollMouseController(defaults: defaults, isTrusted: { permissions.currentStatus(.accessibility) == .granted })
        keys = KeysController(
            defaults: defaults, mappingStore: keyMapping, isTrusted: { permissions.currentStatus(.accessibility) == .granted })
        self.cleaner = cleaner ?? CleanerController(defaults: defaults)
        self.apps = apps ?? AppsController()
        self.pinCrop =
            pinCrop
            ?? PinCropController(access: ScreenAccess(for: .pinCrop, permissions: permissions))
        self.windowSwitcher = windowSwitcher ?? WindowSwitcherController(defaults: defaults, shortcuts: shortcuts)
        self.displaysAudio = displaysAudio ?? Self.makeDisplaysAudio(defaults: defaults, permissions: permissions)
        batchRename = BatchRenameController(defaults: defaults, finder: finder)
        self.locksmith = locksmith ?? LocksmithController(finder: finder)
        finderExtras = FinderExtrasController(defaults: defaults, finder: finder, pasteboard: pasteboard)
        self.screenRuler =
            screenRuler
            ?? ScreenRulerController(
                defaults: defaults, pasteboard: pasteboard, access: ScreenAccess(for: .screenRuler, permissions: permissions))
        let networkReader = networkReader ?? LiveNetworkReader()
        network = NetworkController(defaults: defaults, helper: networkHelper ?? NetworkHelperClient(), reader: networkReader)
        self.networkInfo = networkInfo ?? NetworkInfoController(reader: networkReader)
        bandwidth = BandwidthController(reader: networkReader)
        networkSpeed = NetworkSpeedMonitor(defaults: defaults)
        if let stored = defaults.stringArray(forKey: Self.enabledModulesKey) {
            enabledModules = Set(stored.compactMap(ModuleID.init(rawValue:)))
        } else {
            // First launch: only modules that need no permission are on, so nothing prompts unasked.
            enabledModules = Set(
                ModuleCatalog.all.filter { $0.isImplemented && $0.permissions.isEmpty && !$0.offByDefault }.map(\.id))
        }
        // From before only one of a pair could be on: the one added later, Lanes, stays.
        if enabledModules.contains(.lanes), enabledModules.remove(.zones) != nil {
            defaults.set(enabledModules.map(\.rawValue).sorted(), forKey: Self.enabledModulesKey)
        }
        if enabledModules.contains(.awake) { awake.startWatchingDisplays() }
        if enabledModules.contains(.zones) { zones.start() }
        if enabledModules.contains(.lanes) { lanes.start(lookingNow: false) }
        if enabledModules.contains(.clipboard) { clipboard.start() }
        if enabledModules.contains(.scrollMouse) { scrollMouse.start() }
        if enabledModules.contains(.keys) { keys.start() }
        if enabledModules.contains(.displaysAudio) { self.displaysAudio.start() }
        // Turned off with the helper still held, as when the app quit before letting go of it.
        if !enabledModules.contains(.network) { network.stop() }
        updateNetworkSpeed()
        updateModuleShortcuts()
    }

    /// Awake, System Toggles, Color Picker, Text Extractor, Pin & Crop, Screen Ruler, Window Switcher, Displays & Audio, Finder Extras and Network register no shortcuts of their own, so their shortcuts
    /// follow the module switch here.
    private func updateModuleShortcuts() {
        var simple: [(ModuleID, ShortcutDefinition, () -> Void)] = [
            (.awake, AwakeController.toggleShortcut, { [weak self] in self?.awake.toggle() }),
            (.colorPicker, ColorPickerController.pickShortcut, { [weak self] in Task { await self?.colorPicker.pick() } }),
            (.textExtractor, TextExtractorController.extractShortcut, { [weak self] in Task { await self?.textExtractor.extract() } }),
            (.pinCrop, PinCropController.pinShortcut, { [weak self] in Task { await self?.pinCrop.pick() } }),
            (.screenRuler, ScreenRulerController.measureShortcut, { [weak self] in Task { await self?.screenRuler.measure() } }),
            (.windowSwitcher, WindowSwitcherController.switchShortcut, { [weak self] in self?.windowSwitcher.trigger() }),
            (.displaysAudio, DisplaysAudioController.muteShortcut, { [weak self] in self?.displaysAudio.toggleMicMute() }),
            (.network, NetworkController.toggleThrottleShortcut, { [weak self] in Task { await self?.network.toggleThrottle() } }),
            (.network, NetworkController.flushDNSShortcut, { [weak self] in Task { await self?.network.flushDNS() } }),
            (.network, NetworkController.toggleProxyShortcut, { [weak self] in Task { await self?.network.toggleProxy() } }),
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

    /// The module that can't be on at the same time as `id`. Zones and Lanes both arrange
    /// windows, and each would undo what the other did.
    static func rival(of id: ModuleID) -> ModuleID? {
        switch id {
        case .zones: .lanes
        case .lanes: .zones
        default: nil
        }
    }

    func setEnabled(_ id: ModuleID, _ enabled: Bool) {
        // The rival goes first, so Lanes puts every window back before Zones starts, and the
        // other way round.
        if enabled, let rival = Self.rival(of: id), isEnabled(rival) {
            setEnabled(rival, false)
        }
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
        case .awake:
            if enabled {
                awake.startWatchingDisplays()
            } else {
                awake.stop()
                awake.stopWatchingDisplays()
            }
        case .pinCrop where !enabled: pinCrop.stop()
        case .screenRuler where !enabled: screenRuler.cancel()
        case .windowSwitcher where !enabled: windowSwitcher.cancel()
        case .zones: enabled ? zones.start() : zones.stop()
        case .lanes: enabled ? lanes.start() : lanes.stop()
        case .clipboard: enabled ? clipboard.start() : clipboard.stop()
        case .scrollMouse: enabled ? scrollMouse.start() : scrollMouse.stop()
        case .keys: enabled ? keys.start() : keys.stop()
        case .displaysAudio: enabled ? displaysAudio.start() : displaysAudio.stop()
        case .network:
            if enabled {
                Task { await network.refresh() }
            } else {
                network.stop()
                networkInfo.cancelSpeedTest()
            }
            updateNetworkSpeed()
        default: break
        }
        updateModuleShortcuts()
        defaults.set(enabledModules.map(\.rawValue).sorted(), forKey: Self.enabledModulesKey)
    }

    // MARK: Network speed in the menu bar

    /// The speed item is in the menu bar while its setting and the Network module are both on.
    var showsNetworkSpeed: Bool { isEnabled(.network) && networkSpeed.showsInMenuBar }

    func setShowsNetworkSpeed(_ on: Bool) {
        networkSpeed.showsInMenuBar = on
        updateNetworkSpeed()
    }

    /// Samples only while the item is shown. The item itself follows `showsNetworkSpeed`.
    private func updateNetworkSpeed() {
        if showsNetworkSpeed { networkSpeed.start() } else { networkSpeed.stop() }
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
                isTrusted: { permissions.currentStatus(.accessibility) == .granted }),
            defaults: defaults)
    }
}
