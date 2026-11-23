import AppKit
import IOKit
import Observation

/// An external display that answers DDC/CI, the monitor control channel over its cable.
struct ExternalDisplay: Identifiable, Hashable, Sendable {
    let id: UInt64
    let name: String
    /// 0–1, or nil until read, or when the display doesn't say.
    var brightness: Double?
    /// Its speakers' volume, 0–1, or nil when it has none it says.
    var volume: Double?
    var isMuted = false
}

/// The DDC controls that go from 0 to a maximum.
enum DDCControl: UInt8, Sendable {
    case brightness = 0x10
    case volume = 0x62
}

/// Reads and sets external displays' controls.
nonisolated protocol DDCAccess: Sendable {
    /// The external displays, named from `names` when there's just one of each: with more, the
    /// order displays are found in needn't match the order of `names`.
    func displays(names: [String]) async -> [ExternalDisplay]
    /// 0–1, or nil when the display doesn't say.
    func value(_ control: DDCControl, of id: UInt64) async -> Double?
    func setValue(_ value: Double, _ control: DDCControl, of id: UInt64) async -> Bool
    /// Nil when the display has no mute of its own.
    func isMuted(_ id: UInt64) async -> Bool?
    func setMuted(_ muted: Bool, of id: UInt64) async -> Bool
}

/// External displays' brightness, and the volume of their speakers, over DDC. Optionally from the
/// keyboard's brightness, volume and mute keys where macOS can't change these itself.
@Observable
final class ExternalDisplaysController {
    private(set) var displays: [ExternalDisplay] = []
    private(set) var isLoaded = false
    /// Other display apps running that may take the keys first.
    private(set) var conflicts: [KeyConflict] = []

    /// The keyboard's brightness keys change the external display under the pointer. Off by default,
    /// since it needs Accessibility.
    var usesBrightnessKeys: Bool {
        didSet {
            defaults.set(usesBrightnessKeys, forKey: Self.usesBrightnessKeysKey)
            updateKeyTap()
        }
    }

    /// The volume and mute keys change a display's speakers while sound plays through them.
    var usesVolumeKeys: Bool {
        didSet {
            defaults.set(usesVolumeKeys, forKey: Self.usesVolumeKeysKey)
            updateKeyTap()
        }
    }

    static let usesBrightnessKeysKey = "displaysAudio.usesBrightnessKeys"
    static let usesVolumeKeysKey = "displaysAudio.usesVolumeKeys"
    /// The same steps as macOS's own keys.
    static let keyStep = 1.0 / 16

    private let defaults: UserDefaults
    @ObservationIgnored private let ddc: any DDCAccess
    @ObservationIgnored private let pointerScreenNeedsDDC: () -> Bool
    /// Whether sound plays through a display's speakers, which macOS has no volume for.
    @ObservationIgnored private let outputNeedsDDC: () -> Bool
    /// Shows the level a key or shortcut changed something to.
    @ObservationIgnored private let showLevel: (LevelIndicator.Kind, Double) -> Void
    @ObservationIgnored private var keyTap: MediaKeyTap?
    /// Tried first for the volume and mute keys, for an output other than a display's speakers that
    /// macOS has no volume for; says whether it used the key.
    @ObservationIgnored var outputVolumeKey: (MediaKey) -> Bool = { _ in false }
    @ObservationIgnored private let isTrusted: () -> Bool
    @ObservationIgnored private let screenNames: () -> [String]
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let runningBundleIDs: () -> Set<String>
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var wakeObservers: [NSObjectProtocol] = []
    /// Says when apps open and quit, and when the Mac wakes.
    @ObservationIgnored private let workspaceCenter: NotificationCenter
    /// Waits between tries at reading the displays after wake.
    @ObservationIgnored private let pause: (Duration) async -> Void
    /// Reading the displays again after wake, until they answer.
    @ObservationIgnored private var wakeRefresh: Task<Void, Never>?
    /// Reading the displays again after a write didn't reach one.
    @ObservationIgnored private var reconnecting: Task<Void, Never>?
    @ObservationIgnored private var pending: [Write: Double] = [:]
    @ObservationIgnored private var writing: Set<Write> = []
    /// Volume before a mute on a display with no mute of its own, which mutes by turning it down.
    @ObservationIgnored private var volumeBeforeMute: [UInt64: Double] = [:]
    @ObservationIgnored private var hasMuteControl: Set<UInt64> = []
    /// The one display the last read found that could tell, by its screen's name, which a display
    /// back from sleep under a new ID is matched against.
    @ObservationIgnored private var lastSeen: (id: UInt64, name: String)?
    /// The last display found back under a new ID, told apart the same way.
    @ObservationIgnored private var lastReplaced: (old: UInt64, new: UInt64)?
    /// Changes that didn't reach a display whose connection went, by display and level: each sends
    /// the latest change again to the ID the display comes back under.
    @ObservationIgnored private var lostChanges: [UInt64: [Level: (UInt64) -> Void]] = [:]
    /// Counts changes to the displays' levels, so a read that started before one keeps the level it
    /// changed to rather than the one read.
    @ObservationIgnored private var changes = 0
    @ObservationIgnored private var lastChanged: [Change: Int] = [:]
    /// Counts refreshes, so a slow one that a newer one or `stop` overtook doesn't land.
    @ObservationIgnored private var generation = 0
    /// The first load, which everything that needs the displays before then waits on.
    @ObservationIgnored private var loading: Task<Void, Never>?

    private enum Level: Hashable {
        case brightness, volume, mute
    }

    private struct Change: Hashable {
        let id: UInt64
        let level: Level
    }

    private func noteChange(_ level: Level, of id: UInt64) {
        changes += 1
        lastChanged[Change(id: id, level: level)] = changes
    }

    private struct Write: Hashable {
        let id: UInt64
        let control: DDCControl
    }

    init(
        defaults: UserDefaults = .standard,
        ddc: any DDCAccess = LiveDDC(),
        screenNames: @escaping () -> [String] = { ExternalDisplaysController.externalScreenNames() },
        pointerScreenNeedsDDC: @escaping () -> Bool = { ExternalDisplaysController.pointerScreenNeedsDDC() },
        outputNeedsDDC: @escaping () -> Bool = { false },
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        runningBundleIDs: @escaping () -> Set<String> = { KeyConflict.runningBundleIDs() },
        showLevel: @escaping (LevelIndicator.Kind, Double) -> Void = { LevelIndicator.show($0, $1) },
        pause: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.defaults = defaults
        self.ddc = ddc
        self.screenNames = screenNames
        self.pointerScreenNeedsDDC = pointerScreenNeedsDDC
        self.outputNeedsDDC = outputNeedsDDC
        self.isTrusted = isTrusted
        self.runningBundleIDs = runningBundleIDs
        self.showLevel = showLevel
        self.pause = pause
        self.workspaceCenter = workspaceCenter
        usesBrightnessKeys = defaults.bool(forKey: Self.usesBrightnessKeysKey)
        usesVolumeKeys = defaults.bool(forKey: Self.usesVolumeKeysKey)
    }

    /// Watches for displays coming and going. Displays are only asked about once `load` is called,
    /// so there's no DDC traffic for people who never look at them.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLoaded else { return }
                Task { await self.refresh() }
            }
        }
        // Other display apps opening and quitting change what's said under the keys switches.
        let center = workspaceCenter
        appObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkConflicts() }
            }
        }
        // After sleep the displays' connections are made anew, which a screen change doesn't always say.
        wakeObservers = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            }
        }
        checkConflicts()
        updateKeyTap()
    }

    /// Waits before each try at reading the displays after wake, as a display takes a while to answer again.
    static let wakeRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]

    /// The displays' DDC connections don't survive sleep: each comes back as a new one, so the ones
    /// held go nowhere, and a display may not answer for a few seconds. Reads the displays again
    /// until every one found says a level, or the tries run out.
    func systemDidWake() {
        guard observer != nil, isLoaded else { return }
        wakeRefresh?.cancel()
        wakeRefresh = Task { [weak self] in
            for delay in Self.wakeRetryDelays {
                await self?.pause(delay)
                guard let self, !Task.isCancelled, self.observer != nil else { return }
                // Goes by what the displays said to this read: one that a newer read overtook says nothing.
                if let found = await self.refresh(), !found.isEmpty,
                    found.allSatisfy({ $0.brightness != nil || $0.volume != nil })
                {
                    return
                }
            }
        }
    }

    /// A change to `level` that didn't reach display `id`. If its connection has gone, as after
    /// sleep or a cable plugged in again, the displays are read again and `resend` sends the latest
    /// change to the display's new ID, when it can be told apart. A display that only missed one
    /// keeps the level shown.
    private func writeFailed(_ id: UInt64, _ level: Level, resend: @escaping (UInt64) -> Void) {
        guard observer != nil else { return }
        lostChanges[id, default: [:]][level] = resend
        guard reconnecting == nil else { return }
        reconnecting = Task { [weak self] in
            guard let self else { return }
            let current = await ddc.displays(names: screenNames()).map(\.id)
            if !Task.isCancelled, !current.contains(id) { await refresh() }
            // Stopped meanwhile, and maybe started again with a reconnect of its own.
            guard !Task.isCancelled else { return }
            reconnecting = nil
            let lost = lostChanges
            lostChanges = [:]
            if let replaced = lastReplaced, let resends = lost[replaced.old] {
                for resend in resends.values { resend(replaced.new) }
            }
        }
    }

    private func checkConflicts() {
        conflicts = KeyConflict.running(in: runningBundleIDs())
    }

    var brightnessKeysWarning: String? { KeyConflict.warning(conflicts.filter(\.takesBrightnessKeys)) }
    var volumeKeysWarning: String? { KeyConflict.warning(conflicts.filter(\.takesVolumeKeys)) }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for observer in appObservers { workspaceCenter.removeObserver(observer) }
        appObservers = []
        for observer in wakeObservers { workspaceCenter.removeObserver(observer) }
        wakeObservers = []
        wakeRefresh?.cancel()
        wakeRefresh = nil
        reconnecting?.cancel()
        reconnecting = nil
        lastChanged = [:]
        lostChanges = [:]
        conflicts = []
        updateKeyTap()
        generation += 1
        loading = nil
        displays = []
        isLoaded = false
    }

    /// Reads the displays the first time they're needed.
    func load() async {
        guard observer != nil, !isLoaded else { return }
        let task = loading ?? Task { _ = await refresh() }
        loading = task
        await task.value
        if loading == task { loading = nil }
    }

    /// Reads the displays and their levels. Returns what the displays said, before levels changed
    /// meanwhile are kept, or nil when a newer read or `stop` overtook it, so it didn't land.
    @discardableResult
    func refresh() async -> [ExternalDisplay]? {
        generation += 1
        let current = generation
        let changesBefore = changes
        let names = screenNames()
        var found = await ddc.displays(names: names)
        var muteControl: Set<UInt64> = []
        for index in found.indices {
            let id = found[index].id
            found[index].brightness = await ddc.value(.brightness, of: id)
            found[index].volume = await ddc.value(.volume, of: id)
            if let muted = await ddc.isMuted(id) {
                muteControl.insert(id)
                found[index].isMuted = muted
            }
        }
        guard current == generation, observer != nil else { return nil }
        let said = found
        // A display back from sleep has a new ID; a mute made by turning it down goes along with it.
        // Only a lone display can be told apart from before, by its screen's name, which macOS may
        // only give once the display answers; displays come back in no set order.
        if found.count == 1, names.count == 1 {
            let display = found[0]
            if let last = lastSeen, last.id != display.id, last.name == display.name {
                lastReplaced = (last.id, display.id)
                if let volume = volumeBeforeMute.removeValue(forKey: last.id) { volumeBeforeMute[display.id] = volume }
            }
            lastSeen = (display.id, display.name)
        } else if found.count > 1 {
            lastSeen = nil
        }
        for index in found.indices {
            let id = found[index].id
            // From the mutes as they are now, which a key may have changed while the levels were read.
            if !muteControl.contains(id) { found[index].isMuted = volumeBeforeMute[id] != nil }
            // A level changed meanwhile stays as it was changed to: what was read may be from before.
            guard let shown = displays.first(where: { $0.id == id }) else { continue }
            let changed = { (level: Level) in (self.lastChanged[Change(id: id, level: level)] ?? 0) > changesBefore }
            if changed(.brightness) { found[index].brightness = shown.brightness }
            if changed(.volume) { found[index].volume = shown.volume }
            if changed(.mute), muteControl.contains(id) { found[index].isMuted = shown.isMuted }
        }
        displays = found
        hasMuteControl = muteControl
        isLoaded = true
        return said
    }

    func setBrightness(_ value: Double, for display: ExternalDisplay) {
        set(.brightness, to: value, for: display.id)
    }

    /// Changing the volume unmutes, as it does with macOS's volume slider.
    func setVolume(_ value: Double, for display: ExternalDisplay) {
        if display.isMuted { setMuted(false, for: display, showing: false) }
        set(.volume, to: value, for: display.id)
    }

    /// Shows the new value at once; the display gets the latest one when it's ready, so dragging a
    /// slider or turning a knob doesn't queue up every step.
    private func set(_ control: DDCControl, to value: Double, for id: UInt64) {
        let value = min(max(value, 0), 1)
        if let index = displays.firstIndex(where: { $0.id == id }) {
            switch control {
            case .brightness: displays[index].brightness = value
            case .volume: displays[index].volume = value
            }
        }
        noteChange(control == .brightness ? .brightness : .volume, of: id)
        let write = Write(id: id, control: control)
        pending[write] = value
        guard !writing.contains(write) else { return }
        writing.insert(write)
        Task {
            while let next = pending.removeValue(forKey: write) {
                if await !ddc.setValue(next, control, of: id) {
                    // Held only until the reconnect, or `stop`, is done with it.
                    writeFailed(id, control == .brightness ? .brightness : .volume) { newID in
                        self.set(control, to: next, for: newID)
                    }
                }
            }
            writing.remove(write)
        }
    }

    // MARK: Keys

    private func updateKeyTap() {
        guard observer != nil, usesBrightnessKeys || usesVolumeKeys else {
            keyTap?.stop()
            keyTap = nil
            return
        }
        guard keyTap == nil else { return }
        let tap = MediaKeyTap(isTrusted: isTrusted) { [weak self] in self?.handle($0) ?? false }
        tap.start()
        keyTap = tap
        // The keys need to know the displays without the settings being opened first.
        Task { await load() }
    }

    /// Acts on a key where macOS can't, and says whether it did; otherwise the key is left to macOS.
    /// Brightness keys work on the screen under the pointer when it's an external one macOS can't
    /// change itself. Volume keys work while sound plays through a display's speakers.
    func handle(_ key: MediaKey) -> Bool {
        switch key {
        case .brightnessUp, .brightnessDown:
            guard usesBrightnessKeys, displays.contains(where: { $0.brightness != nil }), pointerScreenNeedsDDC() else { return false }
            step(key == .brightnessUp ? .up : .down)
        case .volumeUp, .volumeDown, .mute:
            guard usesVolumeKeys else { return false }
            if outputVolumeKey(key) { return true }
            guard let speakers, outputNeedsDDC() else { return false }
            if key == .mute {
                setMuted(!speakers.isMuted, for: speakers)
            } else {
                stepVolume(key == .volumeUp ? .up : .down, for: speakers)
            }
        }
        return true
    }

    /// The display whose speakers the keys change: with more than one, which one is playing isn't
    /// known, so none.
    private var speakers: ExternalDisplay? {
        let withSpeakers = displays.filter { $0.volume != nil }
        return withSpeakers.count == 1 ? withSpeakers.first : nil
    }

    /// One step up or down on each display whose brightness is known, as from a shortcut. With more
    /// than one, there's no telling which is which, so they all change.
    func step(_ direction: Step) {
        guard isLoaded else {
            Task {
                await load()
                if isLoaded { step(direction) }
            }
            return
        }
        var shown: Double?
        for display in displays {
            guard let current = display.brightness else { continue }
            let level = Self.stepped(current, direction)
            setBrightness(level, for: display)
            shown = shown ?? level
        }
        if let shown { showLevel(.brightness, shown) }
    }

    /// Like macOS's volume keys, a step while muted unmutes first.
    private func stepVolume(_ direction: Step, for display: ExternalDisplay) {
        var current = display.volume ?? 0
        if display.isMuted {
            current = volumeBeforeMute[display.id] ?? current
            setMuted(false, for: display, showing: false)
        }
        let level = Self.stepped(current, direction)
        set(.volume, to: level, for: display.id)
        showLevel(.volume, level)
    }

    /// Mutes with the display's own mute where it has one, or else by turning the volume down.
    func setMuted(_ muted: Bool, for display: ExternalDisplay, showing: Bool = true) {
        guard let index = displays.firstIndex(where: { $0.id == display.id }) else { return }
        displays[index].isMuted = muted
        if hasMuteControl.contains(display.id) {
            let id = display.id
            noteChange(.mute, of: id)
            Task {
                guard await !ddc.setMuted(muted, of: id) else { return }
                writeFailed(id, .mute) { newID in
                    guard let display = self.displays.first(where: { $0.id == newID }) else { return }
                    self.setMuted(muted, for: display, showing: false)
                }
            }
        } else if muted {
            volumeBeforeMute[display.id] = display.volume ?? 0
            set(.volume, to: 0, for: display.id)
        } else {
            set(.volume, to: volumeBeforeMute.removeValue(forKey: display.id) ?? display.volume ?? 0.5, for: display.id)
        }
        guard showing else { return }
        if muted {
            showLevel(.muted, 0)
        } else {
            showLevel(.volume, displays[index].volume ?? 0)
        }
    }

    static func stepped(_ value: Double, _ direction: Step) -> Double {
        let steps = (value / keyStep).rounded() + (direction == .up ? 1 : -1)
        return min(max(steps * keyStep, 0), 1)
    }

    /// Whether the screen under the pointer is an external one whose brightness macOS can't change
    /// itself, as it can for Apple's displays.
    static func pointerScreenNeedsDDC() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return CGDisplayIsBuiltin(number) == 0 && canChangeBrightness?(number) != true
    }

    /// DisplayServices' own check, used by macOS's brightness keys. A private call, looked up at run time.
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    private static let canChangeBrightness: CanChangeBrightness? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
    ).flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }.map { unsafeBitCast($0, to: CanChangeBrightness.self) }

    static func externalScreenNames() -> [String] {
        NSScreen.screens.filter { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return true }
            return CGDisplayIsBuiltin(number) == 0
        }.map(\.localizedName)
    }
}

/// DDC/CI message bytes.
nonisolated enum DDC {
    static let brightness: UInt8 = 0x10
    static let mute: UInt8 = 0x8D
    static let displayAddress: UInt8 = 0x6E
    static let hostAddress: UInt8 = 0x51

    /// Set VCP feature: length, opcode 0x03, code, value, checksum.
    static func setPacket(code: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(packet.reduce(displayAddress ^ hostAddress, ^))
        return packet
    }

    /// Get VCP feature: length, opcode 0x01, code, checksum.
    static func getPacket(code: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, code]
        packet.append(packet.reduce(displayAddress, ^))
        return packet
    }

    /// The current and maximum value from a Get VCP feature reply, if it's one for `code`.
    static func parseReply(_ reply: [UInt8], code: UInt8) -> (current: Int, maximum: Int)? {
        guard reply.count >= 11, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }
        // Some displays fill the unused high byte of the maximum with 0xFF.
        let maximum = (reply[6] == 0xFF ? 0 : Int(reply[6]) << 8) | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        guard maximum > 0 else { return nil }
        return (current, maximum)
    }
}

/// DDC over Apple silicon's display services. The calls are private and looked up at run time,
/// so where they're missing there are simply no displays. Each exchange runs on one serial queue,
/// waiting for its reply there, so a write can never land between a request and its reply.
nonisolated final class LiveDDC: DDCAccess, @unchecked Sendable {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let chipAddress: UInt32 = 0x37

    private let queue = DispatchQueue(label: "dev.sibiraj.powertoys.ddc")
    // Only touched on `queue`.
    private var services: [UInt64: CFTypeRef] = [:]
    private var maximums: [UInt64: [UInt8: Int]] = [:]

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
    }

    // Looked up once; nil where this macOS doesn't have them.
    private static let create = symbol("IOAVServiceCreateWithService", as: Create.self)
    private static let write = symbol("IOAVServiceWriteI2C", as: Transfer.self)
    private static let read = symbol("IOAVServiceReadI2C", as: Transfer.self)

    /// Runs `work` on the queue, after everything sent before it.
    private func serially<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    func displays(names: [String]) async -> [ExternalDisplay] {
        await serially { self.findDisplays(names: names) }
    }

    func value(_ control: DDCControl, of id: UInt64) async -> Double? {
        await serially {
            guard let reading = self.readValue(control.rawValue, of: id) else { return nil }
            self.maximums[id, default: [:]][control.rawValue] = reading.maximum
            return min(Double(reading.current) / Double(reading.maximum), 1)
        }
    }

    func setValue(_ value: Double, _ control: DDCControl, of id: UInt64) async -> Bool {
        await serially {
            let maximum = self.maximums[id]?[control.rawValue] ?? 100
            return self.writeValue(UInt16((value * Double(maximum)).rounded()), code: control.rawValue, of: id)
        }
    }

    /// VCP 0x8D: 1 is muted, 2 isn't.
    func isMuted(_ id: UInt64) async -> Bool? {
        await serially {
            switch self.readValue(DDC.mute, of: id)?.current {
            case 1: true
            case 2: false
            default: nil
            }
        }
    }

    func setMuted(_ muted: Bool, of id: UInt64) async -> Bool {
        await serially { self.writeValue(muted ? 1 : 2, code: DDC.mute, of: id) }
    }

    // MARK: On the queue

    private func findDisplays(names: [String]) -> [ExternalDisplay] {
        services = [:]
        guard let create = Self.create else { return [] }
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [UInt64] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location =
                IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else {
                continue
            }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &id)
            services[id] = service
            found.append(id)
        }
        return found.enumerated().map { index, id in
            let name = found.count == 1 && names.count == 1 ? names[0] : "External display \(index + 1)"
            return ExternalDisplay(id: id, name: name)
        }
    }

    private func readValue(_ code: UInt8, of id: UInt64) -> (current: Int, maximum: Int)? {
        guard let service = services[id], let write = Self.write, let read = Self.read else { return nil }
        for _ in 0..<3 {
            var request = DDC.getPacket(code: code)
            guard write(service, Self.chipAddress, UInt32(DDC.hostAddress), &request, UInt32(request.count)) == kIOReturnSuccess
            else { continue }
            // Displays need a moment to answer.
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard read(service, Self.chipAddress, UInt32(DDC.hostAddress), &reply, UInt32(reply.count)) == kIOReturnSuccess,
                let value = DDC.parseReply(reply, code: code)
            else { continue }
            return value
        }
        return nil
    }

    private func writeValue(_ value: UInt16, code: UInt8, of id: UInt64) -> Bool {
        guard let service = services[id], let write = Self.write else { return false }
        var packet = DDC.setPacket(code: code, value: value)
        var succeeded = false
        // Some displays miss a single write, so send it twice.
        for _ in 0..<2 {
            let result = write(service, Self.chipAddress, UInt32(DDC.hostAddress), &packet, UInt32(packet.count))
            succeeded = result == kIOReturnSuccess || succeeded
            usleep(10_000)
        }
        return succeeded
    }
}
