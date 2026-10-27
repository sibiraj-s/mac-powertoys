import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut.
struct HotKey: Hashable, Codable {
    let keyCode: Int
    let modifiers: NSEvent.ModifierFlags
    /// The key as drawn on a keycap, such as "→" or "Z".
    let key: String

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
        self.key = key
    }

    static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// Modifier symbols in the order macOS draws them, then the key.
    var keyCaps: [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        return caps + [key]
    }

    var isFunctionKey: Bool {
        Self.functionKeys.contains(keyCode)
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

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keyCode: try container.decode(Int.self, forKey: .keyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: try container.decode(UInt.self, forKey: .modifiers)),
            key: try container.decode(String.self, forKey: .key)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
        try container.encode(key, forKey: .key)
    }

    // MARK: Key names

    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialKeys: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Tab: "⇥", kVK_Space: "Space", kVK_Escape: "⎋",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// The keycap label for a key, or nil for keys that can't be part of a shortcut.
    /// `characters` is what the key types with no modifiers held.
    static func keyName(keyCode: Int, characters: String?) -> String? {
        if let special = specialKeys[keyCode] { return special }
        if let index = functionKeys.firstIndex(of: keyCode) { return "F\(index + 1)" }
        guard let characters = characters?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !characters.isEmpty
        else { return nil }
        return characters.uppercased()
    }
}

/// Registers global shortcuts; a protocol so tests don't take real system-wide shortcuts.
protocol HotKeyRegistering: AnyObject {
    /// Returns nil when another app already owns the shortcut.
    func register(_ hotKey: HotKey, action: @escaping () -> Void) -> HotKeyCenter.Registration?
    func unregister(_ registration: HotKeyCenter.Registration)
}

/// Registers global shortcuts with Carbon, which needs no Accessibility or Input Monitoring access.
final class HotKeyCenter: HotKeyRegistering {
    static let shared = HotKeyCenter()

    struct Registration: Hashable {
        let id: UInt32
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    private static let signature: OSType = 0x5054_4B59 // "PTKY"

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
