import AppKit

/// Shows macOS's own brightness and volume indicator, the one its keys show, with a level in
/// 16 steps. It's a private part of macOS, looked up at run time; where it's missing or has
/// changed, nothing is shown.
enum LevelIndicator {
    /// The image macOS's indicator shows.
    enum Kind: Int64 {
        case brightness = 1
        case volume = 3
        case muted = 4
    }

    private typealias Show = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void

    private static let selector = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
    /// The priority macOS gives its own key presses.
    private static let priority: UInt32 = 0x1F4

    private static let manager: AnyObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_LAZY) != nil,
            let type = NSClassFromString("OSDManager") as? NSObject.Type,
            let manager = type.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject,
            manager.responds(to: selector)
        else { return nil }
        return manager
    }()

    /// Shows `level`, 0–1, on the screen under the pointer.
    static func show(_ kind: Kind, _ level: Double) {
        guard let manager = manager as? NSObject else { return }
        let show = unsafeBitCast(manager.method(for: selector), to: Show.self)
        let steps = UInt32((min(max(level, 0), 1) * 16).rounded())
        show(manager, selector, kind.rawValue, pointerDisplay(), priority, 1000, steps, 16, false)
    }

    private static func pointerDisplay() -> CGDirectDisplayID {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }
}
