import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// What the Caps Lock key does.
enum CapsLockMode: String, CaseIterable, Identifiable, Codable {
    case standard, escape, control, hyper, hyperOrEscape

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Caps Lock"
        case .escape: "Escape"
        case .control: "Control"
        case .hyper: "Hyper"
        case .hyperOrEscape: "Hyper, or Escape alone"
        }
    }

    var hint: String {
        switch self {
        case .standard: "Works as usual."
        case .escape: "Presses ⎋."
        case .control: "Works as a second ⌃ key."
        case .hyper: "Holds ⌃⌥⇧⌘ together, a combination apps don't use, for your own shortcuts."
        case .hyperOrEscape: "Holds ⌃⌥⇧⌘ with another key; pressed and released on its own, presses ⎋."
        }
    }

    /// Hyper needs the event tap: Caps Lock is mapped to an otherwise unused key the tap watches.
    var usesHyper: Bool { self == .hyper || self == .hyperOrEscape }

    /// The HID usage Caps Lock is mapped to in the system key mapping, or nil to leave it alone.
    var hidDestination: UInt64? {
        switch self {
        case .standard: nil
        case .escape: HIDUsage.escape
        case .control: HIDUsage.leftControl
        case .hyper, .hyperOrEscape: HIDUsage.f18
        }
    }
}

/// Keyboard usages (page 7) as the system key mapping takes them.
enum HIDUsage {
    static let capsLock: UInt64 = 0x7_0000_0039
    static let escape: UInt64 = 0x7_0000_0029
    static let leftControl: UInt64 = 0x7_0000_00E0
    static let f18: UInt64 = 0x7_0000_006D
    /// The virtual key code F18 arrives as once Caps Lock is mapped to it.
    static let f18KeyCode = kVK_F18

    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    /// The mapping with Caps Lock sent to `destination`, or left alone when nil; entries for other
    /// keys, such as ones set with `hidutil`, are kept.
    static func mapping(_ entries: [[String: UInt64]], capsLockTo destination: UInt64?) -> [[String: UInt64]] {
        var result = entries.filter { $0[sourceKey] != capsLock }
        if let destination { result.append([sourceKey: capsLock, destinationKey: destination]) }
        return result
    }
}

/// The system-wide key mapping `hidutil property --set UserKeyMapping` changes. It lasts until
/// restart; a protocol so tests don't change the real keyboard.
protocol KeyMappingStore: AnyObject {
    func userKeyMapping() -> [[String: UInt64]]
    func setUserKeyMapping(_ entries: [[String: UInt64]])
    /// Mapped to another key, Caps Lock can't be turned off again, so it's turned off first.
    func turnOffCapsLock()
}

final class LiveKeyMappingStore: KeyMappingStore {
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private static let property = "UserKeyMapping" as CFString

    func userKeyMapping() -> [[String: UInt64]] {
        let value = IOHIDEventSystemClientCopyProperty(client, Self.property)
        let entries = value as? [[String: NSNumber]] ?? []
        return entries.map { $0.mapValues(\.uint64Value) }
    }

    func setUserKeyMapping(_ entries: [[String: UInt64]]) {
        let value = entries.map { $0.mapValues { NSNumber(value: $0) } } as NSArray
        if !IOHIDEventSystemClientSetProperty(client, Self.property, value) {
            NSLog("Couldn't change the key mapping")
        }
    }

    func turnOffCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connection) }
        IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false)
    }
}

/// Tracks the Hyper key: held, it adds ⌃⌥⇧⌘ to other keys; it was "tapped" when released with
/// no other key pressed meanwhile.
struct HyperKeyState {
    private(set) var isHeld = false
    private var isAlone = false

    static let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    /// Key repeat sends more presses while held; only the first counts.
    mutating func press() {
        guard !isHeld else { return }
        isHeld = true
        isAlone = true
    }

    /// Another key or a mouse button went down while Hyper was held.
    mutating func interrupt() {
        isAlone = false
    }

    /// Returns whether it was tapped on its own.
    mutating func release() -> Bool {
        defer {
            isHeld = false
            isAlone = false
        }
        return isHeld && isAlone
    }
}
