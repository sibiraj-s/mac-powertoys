import AppKit

/// Vigil is a dedicated keep-awake app. Awake covers the everyday cases and points here for automation.
enum Vigil {
    static let bundleID = "dev.sibiraj.vigil"
    static let releasesURL = URL(string: "https://github.com/sibiraj-s/vigil/releases/latest")!

    static let features = [
        "Triggers: stay awake while chosen apps run, on a Wi‑Fi network, with a display or drive connected, or on a schedule",
        "While an app runs or a download finishes",
        "Battery guard that ends sessions on low battery",
        "Countdown in the menu bar and global shortcuts",
    ]

    static var installedURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func open() {
        guard let url = installedURL else {
            NSWorkspace.shared.open(releasesURL)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
