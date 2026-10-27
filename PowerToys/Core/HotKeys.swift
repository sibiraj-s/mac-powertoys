import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut.
struct HotKey: Hashable {
    let keyCode: Int
    let modifiers: NSEvent.ModifierFlags
    /// The key as drawn on a keycap, such as "→" or "Z".
    let key: String

    /// Modifier symbols in the order macOS draws them, then the key.
    var keyCaps: [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        return caps + [key]
    }

    fileprivate var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }

    // Hashable by key and modifiers; NSEvent.ModifierFlags isn't Hashable itself.
    static func == (a: HotKey, b: HotKey) -> Bool {
        a.keyCode == b.keyCode && a.modifiers.rawValue == b.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }
}

/// Registers global shortcuts with Carbon, which needs no Accessibility or Input Monitoring access.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    struct Registration: Hashable {
        fileprivate let id: UInt32
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    private static let signature: OSType = 0x5054_4B59 // "PTKY"

    /// Returns nil when another app already owns the shortcut.
    func register(_ hotKey: HotKey, action: @escaping () -> Void) -> Registration? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(hotKey.keyCode), hotKey.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        actions[id] = action
        return Registration(id: id)
    }

    func unregister(_ registration: Registration) {
        if let ref = refs.removeValue(forKey: registration.id) {
            UnregisterEventHotKey(ref)
        }
        actions[registration.id] = nil
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec, nil, &handler)
    }
}

/// Carbon delivers hot key events on the main thread.
private nonisolated func hotKeyPressed(_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    MainActor.assumeIsolated {
        HotKeyCenter.shared.fire(hotKeyID.id)
    }
    return noErr
}
