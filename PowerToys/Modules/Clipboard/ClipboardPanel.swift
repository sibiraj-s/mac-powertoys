import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The clipboard history panel. It takes keyboard focus without activating PowerToys, so the app
/// you were typing in stays frontmost and receives the paste.
final class ClipboardPanel {
    private unowned let controller: ClipboardController
    private var panel: KeyPanel?
    private var picker: ClipboardPicker?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    private static let size = CGSize(width: 780, height: 480)

    init(controller: ClipboardController) {
        self.controller = controller
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let picker = ClipboardPicker(controller: controller)
        self.picker = picker
        panel.contentView = NSHostingView(rootView: ClipboardPickerView(picker: picker))

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            let origin = CGPoint(x: area.midX - Self.size.width / 2, y: area.maxY - area.height * 0.18 - Self.size.height)
            panel.setFrame(CGRect(origin: origin, size: Self.size), display: false)
        }
        panel.makeKeyAndOrderFront(nil)

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors run on the main thread. Only a Bool crosses back, since NSEvent isn't Sendable.
                let isHandled = MainActor.assumeIsolated {
                    guard let self, event.window === self.panel else { return false }
                    return self.handle(event)
                }
                return isHandled ? nil : event
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        picker = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Keys are handled here rather than in SwiftUI so the search field can't swallow them.
    private func handle(_ event: NSEvent) -> Bool {
        guard let picker else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case kVK_Escape:
            hide()
        case kVK_UpArrow:
            picker.move(by: -1)
        case kVK_DownArrow:
            picker.move(by: 1)
        case kVK_Tab:
            picker.cycleFilter(by: flags.contains(.shift) ? -1 : 1)
        default:
            guard let command = Self.command(keyCode: Int(event.keyCode), flags: flags) else { return false }
            if !picker.run(command) {
                NSSound.beep()
            }
        }
        return true
    }

    static func command(keyCode: Int, flags: NSEvent.ModifierFlags) -> ClipCommand? {
        switch (keyCode, flags) {
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): .paste(.original)
        case (kVK_Return, .shift), (kVK_ANSI_KeypadEnter, .shift): .paste(.plainText)
        case (kVK_ANSI_M, .command): .paste(.markdown)
        case (kVK_ANSI_J, .command): .paste(.json)
        case (kVK_ANSI_C, .command): .copy
        case (kVK_ANSI_O, .command): .open
        case (kVK_ANSI_R, .command): .reveal
        case (kVK_ANSI_S, .command): .saveImage
        case (kVK_ANSI_P, .command): .togglePin
        case (kVK_Delete, .command): .delete
        default: nil
        }
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Clicking anywhere else dismisses it, like Spotlight.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        return panel
    }
}

/// Borderless panels refuse key status unless told otherwise, and the search field needs it.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
