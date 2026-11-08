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

    /// The app's window at `frame`, as the window list reports it. The list and Accessibility
    /// share coordinates, and Accessibility has no public call from a window number to its window.
    static func window(of pid: pid_t, at frame: CGRect) -> AXWindow? {
        windows(of: pid).first { $0.frame?.integral == frame.integral }
    }

    /// The app's windows, minimized ones included. With a `timeout`, an app that's hung stops
    /// holding things up after that many seconds rather than the default six, both for the list
    /// and for anything asked of the windows later; `useDefaultTimeout()` undoes it.
    static func windows(of pid: pid_t, timeout: Float? = nil) -> [AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        if let timeout { AXUIElementSetMessagingTimeout(app, timeout) }
        let windows: [AXUIElement] = app.value(of: kAXWindowsAttribute) ?? []
        return windows.map { window in
            if let timeout { AXUIElementSetMessagingTimeout(window, timeout) }
            return AXWindow(element: window, pid: pid)
        }
    }

    /// Waits as long as Accessibility normally does, for changes a busy app may be slow to make.
    func useDefaultTimeout() {
        AXUIElementSetMessagingTimeout(element, 0)
    }

    var title: String { element.value(of: kAXTitleAttribute) ?? "" }
    var isMinimized: Bool { element.value(of: kAXMinimizedAttribute) ?? false }
    /// Ordinary windows and dialogs, not palettes, inspectors or other floating panels.
    var isStandard: Bool {
        let subrole: String? = element.value(of: kAXSubroleAttribute)
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
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

    func move(to origin: CGPoint) {
        withoutEnhancedUserInterface { setPosition(origin) }
    }

    /// Restores the window if minimized, puts it in front of its app's other windows, and brings the app forward.
    func raise() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Presses its close button, as clicking it would; an app may ask to save first.
    func close() {
        guard let button: AXUIElement = element.value(of: kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    func minimize() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
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

extension AXUIElement {
    fileprivate func value<T>(of attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    fileprivate var role: String? { value(of: kAXRoleAttribute) }
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
