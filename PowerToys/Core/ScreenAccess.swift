import AppKit

/// Says why nothing happened when Screen Recording still isn't on, which after allowing it
/// usually means the app has to be opened again.
enum ScreenAccessAlert {
    static func show(for module: ModuleID, openSettings: () -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(ModuleCatalog.descriptor(module).name) needs Screen Recording"
        alert.informativeText =
            "Allow \(AppInfo.name) in System Settings › Privacy & Security › Screen & System Audio Recording. If you already have, quit and open \(AppInfo.name) again for it to take effect."
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

/// Screen Recording for a module's action. Access granted in System Settings only counts once the
/// app is opened again, so it's asked for once; after that, trying again explains instead.
final class ScreenAccess {
    private let isGranted: () -> Bool
    private let request: () -> Void
    private let explain: () -> Void
    private var hasRequested = false

    init(isGranted: @escaping () -> Bool, request: @escaping () -> Void, explain: @escaping () -> Void) {
        self.isGranted = isGranted
        self.request = request
        self.explain = explain
    }

    /// The app's own for `module`, explaining with `ScreenAccessAlert`.
    convenience init(for module: ModuleID, permissions: PermissionsService) {
        self.init(
            isGranted: { permissions.currentStatus(.screenRecording) == .granted },
            request: { permissions.request(.screenRecording) },
            explain: { ScreenAccessAlert.show(for: module) { permissions.openSettings(for: .screenRecording) } }
        )
    }

    /// Whether there's access; without it, asks for it or explains why it isn't on yet.
    func check() -> Bool {
        guard !isGranted() else { return true }
        if hasRequested {
            explain()
        } else {
            hasRequested = true
            request()
        }
        return false
    }
}
