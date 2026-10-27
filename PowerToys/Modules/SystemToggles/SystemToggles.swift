import Carbon.HIToolbox
import Foundation

enum SystemToggles {
    static let darkModeShortcut = ShortcutDefinition(
        id: "systemToggles.darkMode", module: .systemToggles, title: "Toggle dark mode",
        defaultHotKey: HotKey(keyCode: kVK_ANSI_D, modifiers: [.control, .option], key: "D")
    )

    /// Flips system-wide dark mode through System Events. The first call triggers the Automation prompt.
    static func toggleDarkMode() {
        let source = """
        tell application "System Events" to tell appearance preferences to set dark mode to not dark mode
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("SystemToggles: dark mode toggle failed: \(error)")
        }
    }
}
