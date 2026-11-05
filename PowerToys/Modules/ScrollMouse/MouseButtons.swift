import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// The extra mouse buttons that can be given another job. Raw values are CGEvent button numbers.
enum MouseButton: Int, CaseIterable, Identifiable, Codable {
    case middle = 2
    case back = 3
    case forward = 4

    var id: Self { self }

    var title: String {
        switch self {
        case .middle: "Middle button"
        case .back: "Button 4"
        case .forward: "Button 5"
        }
    }

    var hint: String {
        switch self {
        case .middle: "Pressing the scroll wheel."
        case .back: "The rear side button on most mice."
        case .forward: "The front side button on most mice."
        }
    }
}

/// What pressing a mouse button does.
enum ButtonAction: Hashable, Codable {
    /// Leave the click to the app under the pointer.
    case standard
    /// ⌘[, which browsers, Finder and most apps take as Back.
    case back
    /// ⌘], Forward.
    case forward
    /// Press these keys; nil until recorded, and until then the button clicks as usual.
    case keys(HotKey?)

    enum Kind: CaseIterable, Identifiable {
        case standard, back, forward, keys

        var id: Self { self }

        var title: String {
            switch self {
            case .standard: "Click as usual"
            case .back: "Back"
            case .forward: "Forward"
            case .keys: "Press keys"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .standard: .standard
        case .back: .back
        case .forward: .forward
        case .keys: .keys
        }
    }

    init(kind: Kind) {
        switch kind {
        case .standard: self = .standard
        case .back: self = .back
        case .forward: self = .forward
        case .keys: self = .keys(nil)
        }
    }

    /// The keys to press instead of the click, or nil to let the click through.
    var hotKey: HotKey? {
        switch self {
        case .standard: nil
        case .back: HotKey(keyCode: kVK_ANSI_LeftBracket, modifiers: .command, key: "[")
        case .forward: HotKey(keyCode: kVK_ANSI_RightBracket, modifiers: .command, key: "]")
        case .keys(let hotKey): hotKey
        }
    }
}

extension HotKey {
    /// The flags a synthesized key press needs. Arrow and navigation keys also carry the Fn and
    /// keypad flags a real keyboard sends, or shortcuts such as ⌃↑ for Mission Control don't match.
    var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if Self.arrowKeys.contains(keyCode) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        if isFunctionKey || Self.navigationKeys.contains(keyCode) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private static let arrowKeys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
    private static let navigationKeys = [kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help]
}
