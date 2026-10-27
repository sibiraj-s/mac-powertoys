import AppKit
import ApplicationServices

/// Another app's window, moved through the Accessibility API. Frames use Accessibility
/// coordinates: origin at the top left of the main display, y growing downward.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    /// The focused window of the frontmost app.
    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = appElement.value(of: kAXFocusedWindowAttribute) else { return nil }
        return AXWindow(element: window, pid: app.processIdentifier)
    }

    /// The window under a point, in Accessibility coordinates.
    static func at(_ point: CGPoint) -> AXWindow? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit
        else { return nil }
        let window: AXUIElement? = hit.role == kAXWindowRole ? hit : hit.value(of: kAXWindowAttribute)
        guard let window else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return AXWindow(element: window, pid: pid)
    }

    var frame: CGRect? {
        guard let positionValue: AXValue = element.value(of: kAXPositionAttribute),
              let sizeValue: AXValue = element.value(of: kAXSizeAttribute)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    func setFrame(_ frame: CGRect) {
        withoutEnhancedUserInterface {
            // Size, then position, then size again: a window moving to a smaller display can be
            // clamped by its old position, and one moving to a larger one by its old size.
            setSize(frame.size)
            setPosition(frame.origin)
            setSize(frame.size)
        }
    }

    func setSize(_ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    private func setPosition(_ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
    }

    /// Some apps (Chromium-based browsers, for one) animate frame changes while VoiceOver-style
    /// "enhanced UI" is on, which makes snapping slow and inexact. Turn it off for the change.
    private func withoutEnhancedUserInterface(_ change: () -> Void) {
        let app = AXUIElementCreateApplication(pid)
        let attribute = "AXEnhancedUserInterface" as CFString
        let wasEnhanced: Bool = app.value(of: attribute as String) ?? false
        if wasEnhanced { AXUIElementSetAttributeValue(app, attribute, kCFBooleanFalse) }
        change()
        if wasEnhanced { AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue) }
    }

    func isSame(as other: AXWindow) -> Bool {
        CFEqual(element, other.element)
    }
}

private extension AXUIElement {
    func value<T>(of attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var role: String? { value(of: kAXRoleAttribute) }
}

/// Displays in Accessibility coordinates.
enum Displays {
    /// The display at the global origin, which Accessibility coordinates are measured from.
    private static var originScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    /// Converts between AppKit's bottom-left coordinates and Accessibility's top-left ones.
    /// The conversion is its own inverse.
    static func flip(_ rect: CGRect) -> CGRect {
        guard let height = originScreen?.frame.height else { return rect }
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func flip(_ point: CGPoint) -> CGPoint {
        guard let height = originScreen?.frame.height else { return point }
        return CGPoint(x: point.x, y: height - point.y)
    }

    /// The usable area (no menu bar or Dock) of a screen.
    static func usableArea(of screen: NSScreen) -> CGRect {
        flip(screen.visibleFrame)
    }

    /// The screen holding most of `frame`.
    static func screen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            area(flip(a.frame).intersection(frame)) < area(flip(b.frame).intersection(frame))
        }
    }

    static func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { flip($0.frame).contains(point) }
    }

    /// Screens left to right, for "next display".
    static var ordered: [NSScreen] {
        NSScreen.screens.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
    }

    /// A key for a display that survives reconnecting and restarting.
    static func key(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String?
        else { return screen.localizedName }
        return string
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
