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

/// Listens for the media keys while Accessibility is allowed. `handle` says
/// whether a press was used, in which case it doesn't reach macOS. The tap runs on a thread of its
/// own and sees every key press, so ordinary keys go straight through without waiting on the main
/// thread; only media keys wait for `handle` there.
final class MediaKeyTap {
    private let isTrusted: () -> Bool
    private let handle: (MediaKey) -> Bool
    private var tap: EventTap?

    init(isTrusted: @escaping () -> Bool, handle: @escaping (MediaKey) -> Bool) {
        self.isTrusted = isTrusted
        self.handle = handle
    }

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        // A key already on its way when the tap stops goes to macOS, not to a tap that's gone.
        let decide: @Sendable (MediaKey) -> Bool = { [weak self] key in
            DispatchQueue.main.sync { MainActor.assumeIsolated { self?.decide(key) ?? false } }
        }
        // Made anew each time, so a press used before a stop doesn't swallow a release after the next start.
        let listener = MediaKeyListener(decide: decide)
        // NX_SYSDEFINED, which CGEventType doesn't name, and key presses for F14 and F15.
        let tap = EventTap(
            events: CGEventMask(1) << 14 | EventTap.mask(of: [.keyDown, .keyUp]), isTrusted: isTrusted,
            handler: .onOwnThread(name: "PowerToys media keys") { type, event in listener.process(type, event) })
        self.tap = tap
        tap.start()
    }

    func stop() {
        tap?.stop()
        tap = nil
    }

    private func decide(_ key: MediaKey) -> Bool {
        tap != nil && handle(key)
    }
}

/// What the tap's thread keeps track of between key events.
private nonisolated final class MediaKeyListener: @unchecked Sendable {
    private let decide: @Sendable (MediaKey) -> Bool
    /// A press used here, so its release is kept from macOS too. Only touched on the tap's thread.
    private var swallowing = false

    init(decide: @escaping @Sendable (MediaKey) -> Bool) {
        self.decide = decide
    }

    /// Returns whether the event goes on to macOS.
    func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
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
