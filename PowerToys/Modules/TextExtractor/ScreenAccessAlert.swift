import AppKit

/// Says why nothing happened when Screen Recording still isn't on, which after allowing it
/// usually means the app has to be opened again.
enum ScreenAccessAlert {
    static func show(openSettings: () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Text Extractor needs Screen Recording"
        alert.informativeText = "Allow \(AppInfo.name) in System Settings › Privacy & Security › Screen & System Audio Recording. If you already have, quit and open \(AppInfo.name) again for it to take effect."
        alert.addButton(withTitle: "Quit & Reopen")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: Relaunch.now()
        case .alertSecondButtonReturn: openSettings()
        default: break
        }
    }
}
