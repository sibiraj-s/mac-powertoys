import AppKit
import Carbon.HIToolbox

nonisolated enum Step: Equatable, Sendable {
    case up, down
}

/// The keyboard's brightness, volume and mute keys, and volume knobs, which send the same. Apple
/// keyboards send them as system-defined events; many others send F14 and F15 for brightness,
/// which macOS also treats as brightness keys.
nonisolated enum MediaKey: Equatable, Sendable {
    case brightnessUp, brightnessDown, volumeUp, volumeDown, mute

    /// System-defined events carry special keys with subtype 8; `data1` holds the key in its top
    /// 16 bits and whether it went down (0xA) or up (0xB) in the next byte.
    static func pressed(subtype: Int16, data1: Int) -> MediaKey? {
        guard subtype == 8, (data1 & 0xFF00) >> 8 == 0xA else { return nil }
        return key(type: (data1 & 0xFFFF_0000) >> 16)
    }

    static func released(subtype: Int16, data1: Int) -> Bool {
        subtype == 8 && (data1 & 0xFF00) >> 8 == 0xB && key(type: (data1 & 0xFFFF_0000) >> 16) != nil
    }

    private static func key(type: Int) -> MediaKey? {
        switch type {
        case 0: .volumeUp  // NX_KEYTYPE_SOUND_UP
        case 1: .volumeDown  // NX_KEYTYPE_SOUND_DOWN
        case 2: .brightnessUp  // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: .brightnessDown  // NX_KEYTYPE_BRIGHTNESS_DOWN
        case 7: .mute  // NX_KEYTYPE_MUTE
        default: nil
        }
    }

    /// F15 and F14 on their own; with a modifier they're left for shortcuts.
    static func key(keyCode: Int, flags: CGEventFlags) -> MediaKey? {
        guard flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl, .maskShift]) else { return nil }
        switch keyCode {
        case kVK_F15: return .brightnessUp
        case kVK_F14: return .brightnessDown
        default: return nil
        }
    }
}

/// Listens for the media keys while Accessibility is allowed, retrying until it is. `handle` says
/// whether a press was used, in which case it doesn't reach macOS. The tap runs on a thread of its
/// own and sees every key press, so ordinary keys go straight through without waiting on the main
/// thread; only media keys wait for `handle` there.
final class MediaKeyTap {
    private let isTrusted: () -> Bool
    private let handle: (MediaKey) -> Bool
    private var listener: MediaKeyListener?
    private var retryTimer: Timer?

    init(isTrusted: @escaping () -> Bool, handle: @escaping (MediaKey) -> Bool) {
        self.isTrusted = isTrusted
        self.handle = handle
    }

    var isRunning: Bool { listener != nil || retryTimer != nil }

    func start() {
        guard !isRunning else { return }
        install()
        guard listener == nil else { return }
        // Accessibility may be allowed later, in System Settings; keep trying until it is.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.install() }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        listener?.stop()
        listener = nil
    }

    private func install() {
        guard listener == nil, isTrusted() else { return }
        let decide: @Sendable (MediaKey) -> Bool = { [weak self] key in
            DispatchQueue.main.sync { MainActor.assumeIsolated { self?.handle(key) ?? false } }
        }
        guard let listener = MediaKeyListener.start(decide: decide) else { return }
        self.listener = listener
        retryTimer?.invalidate()
        retryTimer = nil
    }
}

/// The event tap and the thread it runs on.
private nonisolated final class MediaKeyListener: @unchecked Sendable {
    private let decide: @Sendable (MediaKey) -> Bool
    // Only touched on the tap's thread once it runs.
    private var tap: CFMachPort?
    /// Set by the tap's thread before `start` returns; read and cleared only by `stop`.
    private var runLoop: CFRunLoop?
    /// A press used here, so its release is kept from macOS too.
    private var swallowing = false

    private init(decide: @escaping @Sendable (MediaKey) -> Bool) {
        self.decide = decide
    }

    static func start(decide: @escaping @Sendable (MediaKey) -> Bool) -> MediaKeyListener? {
        let listener = MediaKeyListener(decide: decide)
        // NX_SYSDEFINED, which CGEventType doesn't name, and key presses for F14 and F15.
        let mask = CGEventMask(1) << 14 | CGEventMask(1) << CGEventType.keyDown.rawValue | CGEventMask(1) << CGEventType.keyUp.rawValue
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let listener = Unmanaged<MediaKeyListener>.fromOpaque(refcon).takeUnretainedValue()
            return listener.process(type, event) ? Unmanaged.passUnretained(event) : nil
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: callback, userInfo: Unmanaged.passUnretained(listener).toOpaque())
        else { return nil }
        listener.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            guard let tap = listener.tap else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            listener.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "PowerToys media keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return listener
    }

    /// The tap is ended on its own thread, which may be using it at that moment.
    func stop() {
        guard let runLoop else { return }
        self.runLoop = nil
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            tap = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Returns whether the event goes on to macOS.
    private func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns off a tap that's slow to answer; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .keyDown, .keyUp:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let key = MediaKey.key(keyCode: keyCode, flags: event.flags) else { return true }
            return type == .keyDown ? press(key) : release()
        default:
            guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event) else { return true }
            if let key = MediaKey.pressed(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1) {
                return press(key)
            }
            if MediaKey.released(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1) {
                return release()
            }
            return true
        }
    }

    private func press(_ key: MediaKey) -> Bool {
        swallowing = decide(key)
        return !swallowing
    }

    private func release() -> Bool {
        guard swallowing else { return true }
        swallowing = false
        return false
    }
}
