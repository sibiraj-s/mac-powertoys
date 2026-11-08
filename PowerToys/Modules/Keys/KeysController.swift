import AppKit
import Carbon.HIToolbox
import Observation

/// Turns Caps Lock into Escape, Control or Hyper, and remaps keys and shortcuts everywhere or per
/// app. Escape and Control go through the system key mapping; Hyper and remaps go through an event
/// tap that sees key presses before apps do.
@Observable
final class KeysController {
    var capsLock: CapsLockMode {
        didSet {
            defaults.set(capsLock.rawValue, forKey: Self.capsLockKey)
            hyper = HyperKeyState()
            updateTap()
            applyCapsLock()
        }
    }

    private(set) var remaps: [KeyRemap]

    private(set) var isRunning = false

    /// Remaps are paused while keys are being recorded on the Keys page, so the recorder sees the
    /// keys as pressed. Hyper still applies, so it can be recorded.
    var isPaused = false

    static let capsLockKey = "keys.capsLock"
    static let remapsKey = "keys.remaps"
    /// Set while Caps Lock is mapped by this app, so a mapping left by a crash is undone at launch.
    static let mapsCapsLockKey = "keys.mapsCapsLock"

    /// Marks events this controller posts, so its own tap lets them through untouched.
    static let syntheticMarker: Int64 = 0x5054_4B4D  // "PTKM"

    private let defaults: UserDefaults
    @ObservationIgnored private let mappingStore: any KeyMappingStore
    /// Whether Accessibility is allowed, which the event tap needs; asked afresh each time.
    @ObservationIgnored private let isTrusted: () -> Bool
    @ObservationIgnored private let frontmostApp: () -> String?
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var hyper = HyperKeyState()
    /// What each remapped key that's still down was turned into, so its repeats and release match.
    @ObservationIgnored private var heldRemaps: [Int: KeyRemap.Output] = [:]

    init(
        defaults: UserDefaults = .standard,
        mappingStore: any KeyMappingStore = LiveKeyMappingStore(),
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        frontmostApp: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    ) {
        self.defaults = defaults
        self.mappingStore = mappingStore
        self.isTrusted = isTrusted
        self.frontmostApp = frontmostApp
        capsLock = defaults.string(forKey: Self.capsLockKey).flatMap(CapsLockMode.init(rawValue:)) ?? .standard
        remaps =
            defaults.data(forKey: Self.remapsKey)
            .flatMap { try? JSONDecoder().decode([KeyRemap].self, from: $0) } ?? []
        applyCapsLock()
        // The key mapping outlives the app, so it's undone on quit.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// The tap calls back with an unretained pointer to this controller, so it mustn't outlive it.
    isolated deinit {
        stop()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    // MARK: Remaps

    @discardableResult
    func addRemap() -> KeyRemap {
        let remap = KeyRemap()
        remaps.append(remap)
        saveRemaps()
        return remap
    }

    func update(_ remap: KeyRemap) {
        guard let index = remaps.firstIndex(where: { $0.id == remap.id }) else { return }
        remaps[index] = remap
        saveRemaps()
    }

    func remove(_ id: KeyRemap.ID) {
        remaps.removeAll { $0.id == id }
        saveRemaps()
    }

    /// Why `keys` can't start `remap`, or nil when they can.
    func problem(with keys: HotKey, from remap: KeyRemap) -> String? {
        let taken = remaps.contains { $0.id != remap.id && $0.from == keys && $0.app?.bundleID == remap.app?.bundleID }
        guard taken else { return nil }
        return remap.app.map { "These keys are already remapped in \($0.name)." } ?? "These keys are already remapped."
    }

    private func saveRemaps() {
        defaults.set(try? JSONEncoder().encode(remaps), forKey: Self.remapsKey)
        updateTap()
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        updateTap()
        applyCapsLock()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        updateTap()
        applyCapsLock()
    }

    /// Whether the event tap is installed; it's only there while Hyper or a remap needs it, since
    /// it sees every key press on the main thread.
    var isListening: Bool { tap != nil }

    private var needsTap: Bool {
        isRunning && (capsLock.usesHyper || remaps.contains(where: \.isActive))
    }

    private func updateTap() {
        if needsTap {
            guard tap == nil, retryTimer == nil else { return }
            installTap()
            guard tap == nil else { return }
            // Accessibility may be allowed later, in System Settings; keep trying until it is.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.installTap() }
            }
        } else {
            retryTimer?.invalidate()
            retryTimer = nil
            removeTap()
        }
    }

    /// Escape and Control apply once running; Hyper only once the tap is there to turn the mapped
    /// key into ⌃⌥⇧⌘, or Caps Lock would do nothing until Accessibility is allowed.
    private func applyCapsLock() {
        let destination = isRunning && (!capsLock.usesHyper || tap != nil) ? capsLock.hidDestination : nil
        let mapsCapsLock = defaults.bool(forKey: Self.mapsCapsLockKey)
        // Leave Caps Lock alone unless this app mapped it, in case it was mapped some other way.
        guard destination != nil || mapsCapsLock else { return }
        if destination != nil, !mapsCapsLock { mappingStore.turnOffCapsLock() }
        mappingStore.setUserKeyMapping(HIDUsage.mapping(mappingStore.userKeyMapping(), capsLockTo: destination))
        defaults.set(destination != nil, forKey: Self.mapsCapsLockKey)
    }

    private func installTap() {
        guard needsTap, tap == nil, isTrusted() else { return }
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<KeysController>.fromOpaque(refcon).takeUnretainedValue()
            // The tap's source is on the main run loop, so this runs on the main thread.
            let keeps = MainActor.assumeIsolated { controller.handle(type, event) }
            return keeps ? Unmanaged.passUnretained(event) : nil
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        retryTimer?.invalidate()
        retryTimer = nil
        applyCapsLock()
    }

    private func removeTap() {
        releaseHeldKeys()
        hyper = HyperKeyState()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// Releases the keys remapped keys were turned into, for when their own release may never be
    /// seen, so nothing is left held down.
    private func releaseHeldKeys() {
        for case .keys(let keys?) in heldRemaps.values {
            keys.post(isDown: false, marker: Self.syntheticMarker)
        }
        heldRemaps = [:]
    }

    // MARK: Events

    /// Events posted by this app: remapped keys, and keys Scroll & Mouse presses for mouse buttons.
    private static let ownMarkers: Set<Int64> = [syntheticMarker, ScrollMouseController.syntheticMarker]

    /// Returns whether the event goes on to apps; it may have been changed on the way.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns off a tap that's slow to answer; turn it back on. Releases went by
            // unseen meanwhile, so let go of anything held.
            releaseHeldKeys()
            hyper = HyperKeyState()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case _ where Self.ownMarkers.contains(event.getIntegerValueField(.eventSourceUserData)):
            return true
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            // A click while Hyper is held is a Hyper click, and means it wasn't tapped alone.
            if hyper.isHeld {
                event.flags.formUnion(HyperKeyState.flags)
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { hyper.interrupt() }
            }
            return true
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if capsLock.usesHyper, keyCode == HIDUsage.f18KeyCode, type != .flagsChanged {
            if type == .keyDown {
                hyper.press()
            } else if hyper.release(), capsLock == .hyperOrEscape {
                HotKey(keyCode: kVK_Escape, modifiers: [], key: "⎋").press(marker: Self.syntheticMarker)
            }
            return false
        }
        if hyper.isHeld {
            event.flags.formUnion(HyperKeyState.flags)
            if type == .keyDown { hyper.interrupt() }
        }
        switch type {
        case .keyDown: return handleKeyDown(keyCode, event)
        case .keyUp: return handleKeyUp(keyCode)
        default: return true
        }
    }

    private func handleKeyDown(_ keyCode: Int, _ event: CGEvent) -> Bool {
        // A repeat continues whatever its first press did; it never starts a remap, or the key
        // that went through unchanged would have its release swallowed.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            guard let held = heldRemaps[keyCode] else { return true }
            if case .keys(let keys?) = held {
                keys.post(isDown: true, marker: Self.syntheticMarker, autorepeat: true)
            }
            return false
        }
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        guard !isPaused, let output = KeyRemap.output(for: keyCode, modifiers: modifiers, app: frontmostApp(), in: remaps)
        else {
            heldRemaps[keyCode] = nil
            return true
        }
        heldRemaps[keyCode] = output
        if case .keys(let keys?) = output {
            keys.post(isDown: true, marker: Self.syntheticMarker)
        }
        return false
    }

    /// Releasing a remapped key releases what it was turned into, even if modifiers came up first.
    private func handleKeyUp(_ keyCode: Int) -> Bool {
        guard let output = heldRemaps.removeValue(forKey: keyCode) else { return true }
        if case .keys(let keys?) = output {
            keys.post(isDown: false, marker: Self.syntheticMarker)
        }
        return false
    }
}
