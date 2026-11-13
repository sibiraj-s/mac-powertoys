import AppKit
import ApplicationServices

/// Another app's window, moved through the Accessibility API. Frames use Accessibility
/// coordinates: origin at the top left of the main display, y growing downward.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    /// The focused window of the frontmost app. With a `timeout`, an app that's hung is given
    /// up on after that many seconds rather than the default six.
    static func focused(timeout: Float? = nil) -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return focused(of: app.processIdentifier, timeout: timeout).window
    }

    /// An app's focused window, and whether the app answered at all: false when asking ran
    /// out of time, which isn't the same as its having no focused window.
    static func focused(of pid: pid_t, timeout: Float? = nil) -> (window: AXWindow?, answered: Bool) {
        let appElement = AXUIElementCreateApplication(pid)
        if let timeout { AXUIElementSetMessagingTimeout(appElement, timeout) }
        let (window, error): (AXUIElement?, AXError) = appElement.answer(to: kAXFocusedWindowAttribute)
        guard let window else { return (nil, error != .cannotComplete) }
        if let timeout { AXUIElementSetMessagingTimeout(window, timeout) }
        return (AXWindow(element: window, pid: pid), true)
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
        answeredWindows(of: pid, timeout: timeout) ?? []
    }

    /// The app's windows as `windows(of:timeout:)` gives them, or nil when the app didn't
    /// answer, which isn't the same as having none.
    static func answeredWindows(of pid: pid_t, timeout: Float? = nil) -> [AXWindow]? {
        let app = AXUIElementCreateApplication(pid)
        if let timeout { AXUIElementSetMessagingTimeout(app, timeout) }
        guard let windows: [AXUIElement] = app.value(of: kAXWindowsAttribute) else { return nil }
        return windows.map { window in
            if let timeout { AXUIElementSetMessagingTimeout(window, timeout) }
            return AXWindow(element: window, pid: pid)
        }
    }

    /// Waits as long as Accessibility normally does, for changes a busy app may be slow to make.
    func useDefaultTimeout() {
        AXUIElementSetMessagingTimeout(element, 0)
    }

    /// Whether the window's app answers at all: false when a question put to it ran out of time.
    /// A window that has closed still gets an answer, that it's gone.
    var isAnswering: Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) != .cannotComplete
    }

    var title: String { element.value(of: kAXTitleAttribute) ?? "" }
    var isMinimized: Bool { element.value(of: kAXMinimizedAttribute) ?? false }
    /// Ordinary windows and dialogs, not palettes, inspectors or other floating panels.
    var isStandard: Bool {
        let subrole = subrole
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    /// What kind of window it is, such as a standard one, a dialog or a floating panel.
    private var subrole: String? { element.value(of: kAXSubroleAttribute) }

    /// An ordinary window: not a dialog, sheet, palette or inspector.
    var isPlainWindow: Bool { subrole == kAXStandardWindowSubrole }

    /// In a full-screen Space of its own.
    var isFullScreen: Bool { element.value(of: "AXFullScreen") ?? false }

    /// Whether its size can be set; a fixed-size window's can't.
    var isResizable: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    var frame: CGRect? { answeredFrame.frame }

    /// The window's frame, and whether its app answered at all: false when asking ran out of time.
    var answeredFrame: (frame: CGRect?, answered: Bool) {
        let (positionValue, error): (AXValue?, AXError) = element.answer(to: kAXPositionAttribute)
        guard let positionValue else { return (nil, error != .cannotComplete) }
        let (sizeValue, sizeError): (AXValue?, AXError) = element.answer(to: kAXSizeAttribute)
        guard let sizeValue else { return (nil, sizeError != .cannotComplete) }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return (CGRect(origin: position, size: size), true)
    }

    /// - Parameter appTimeout: How long to wait on the window's app for what's asked of the app
    ///   itself, in seconds; without one, as long as Accessibility normally does.
    func setFrame(_ frame: CGRect, appTimeout: Float? = nil) {
        withoutEnhancedUserInterface(appTimeout: appTimeout) {
            // Size, then position, then size again: a window moving to a smaller display can be
            // clamped by its old position, and one moving to a larger one by its old size.
            setSize(frame.size)
            nudge(to: frame.origin)
            setSize(frame.size)
        }
    }

    func move(to origin: CGPoint, appTimeout: Float? = nil) {
        withoutEnhancedUserInterface(appTimeout: appTimeout) { nudge(to: origin) }
    }

    /// Sets the position and nothing else, for moving a window many times a second. Apps that
    /// animate frame changes may lag behind; `move(to:)` allows for those.
    func nudge(to origin: CGPoint) {
        var point = origin
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
    }

    /// Restores the window if minimized, puts it in front of its app's other windows, and brings the app forward.
    func raise(appTimeout: Float? = nil) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement(timeout: appTimeout), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
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

    /// Some apps (Chromium-based browsers, for one) animate frame changes while VoiceOver-style
    /// "enhanced UI" is on, which makes snapping slow and inexact. Turn it off for the change.
    private func withoutEnhancedUserInterface(appTimeout: Float?, _ change: () -> Void) {
        let app = appElement(timeout: appTimeout)
        let attribute = "AXEnhancedUserInterface" as CFString
        let wasEnhanced: Bool = app.value(of: attribute as String) ?? false
        if wasEnhanced { AXUIElementSetAttributeValue(app, attribute, kCFBooleanFalse) }
        change()
        if wasEnhanced { AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue) }
    }

    private func appElement(timeout: Float?) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        if let timeout { AXUIElementSetMessagingTimeout(app, timeout) }
        return app
    }

    func isSame(as other: AXWindow) -> Bool {
        CFEqual(element, other.element)
    }
}

extension AXUIElement {
    fileprivate func value<T>(of attribute: String) -> T? {
        answer(to: attribute).value
    }

    /// An attribute's value, with the error when there's none.
    fileprivate func answer<T>(to attribute: String) -> (value: T?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(self, attribute as CFString, &value)
        guard error == .success else { return (nil, error) }
        return (value as? T, .success)
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
