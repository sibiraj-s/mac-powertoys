import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import Observation

enum Permission: String, CaseIterable, Identifiable, Sendable {
    case accessibility, screenRecording, inputMonitoring, automation, fullDiskAccess, audioCapture, admin

    var id: Self { self }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .inputMonitoring: "Input Monitoring"
        case .automation: "Automation"
        case .fullDiskAccess: "Full Disk Access"
        case .audioCapture: "System Audio Recording"
        case .admin: "Administrator"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .inputMonitoring: "keyboard.badge.eye"
        case .automation: "gearshape.arrow.triangle.2.circlepath"
        case .fullDiskAccess: "internaldrive"
        case .audioCapture: "waveform"
        case .admin: "lock.shield"
        }
    }

    var explanation: String {
        switch self {
        case .accessibility: "Move and resize windows, read the menu bar and simulate key presses."
        case .screenRecording: "Show window previews, pick colors and read text from the screen."
        case .inputMonitoring: "Listen for global shortcuts and remap keys."
        case .automation: "Ask System Events and Finder to switch settings such as dark mode and to empty the Trash."
        case .fullDiskAccess: "See which process holds a file anywhere on disk, and clear data uninstalled apps left."
        case .audioCapture: "Change the volume of each app by playing its sound through at the volume you set."
        case .admin: "Edit system files such as /etc/hosts. Asked for each change."
        }
    }

    /// Whether macOS has a prompt of its own for it, shown once per app.
    var hasSystemPrompt: Bool {
        switch self {
        case .accessibility, .screenRecording, .inputMonitoring, .audioCapture: true
        case .automation, .fullDiskAccess, .admin: false
        }
    }

    /// Deep link into the matching System Settings privacy pane.
    var settingsURL: URL? {
        let anchor: String? =
            switch self {
            case .accessibility: "Privacy_Accessibility"
            case .screenRecording: "Privacy_ScreenCapture"
            case .inputMonitoring: "Privacy_ListenEvent"
            case .automation: "Privacy_Automation"
            case .fullDiskAccess: "Privacy_AllFiles"
            // System Audio Recording Only is listed in the Screen & System Audio Recording pane.
            case .audioCapture: "Privacy_ScreenCapture"
            case .admin: nil
            }
        return anchor.flatMap { URL(string: "x-apple.systempreferences:com.apple.preference.security?\($0)") }
    }
}

enum PermissionStatus {
    case granted, denied
    /// macOS offers no reliable preflight check; the prompt appears on first use.
    case unknown
}

@Observable
final class PermissionsService {
    private(set) var statuses: [Permission: PermissionStatus] = [:]

    static let promptedKey = "permissions.prompted"

    private let defaults: UserDefaults
    @ObservationIgnored private let check: (Permission) -> PermissionStatus
    /// Shows the system's prompt, then calls back on the main actor once it's answered, for the
    /// prompts that say; others call back at once.
    @ObservationIgnored private let prompt: (Permission, @escaping @MainActor @Sendable () -> Void) -> Void
    @ObservationIgnored private let openURL: (URL) -> Void

    init(
        defaults: UserDefaults = .standard,
        check: @escaping (Permission) -> PermissionStatus = { PermissionsService.check($0) },
        prompt: @escaping (Permission, @escaping @MainActor @Sendable () -> Void) -> Void = {
            PermissionsService.prompt($0, answered: $1)
        },
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.defaults = defaults
        self.check = check
        self.prompt = prompt
        self.openURL = openURL
        refresh()
    }

    func status(_ permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .unknown
    }

    /// Checks one permission now, without waiting for the next `refresh`.
    func currentStatus(_ permission: Permission) -> PermissionStatus {
        check(permission)
    }

    func refresh() {
        for permission in Permission.allCases {
            statuses[permission] = check(permission)
        }
    }

    /// Shows the system's prompt the first time; after that macOS no longer shows it, so the
    /// permission's pane in System Settings opens instead.
    /// `answered` runs once the prompt is answered, or at once when System Settings opens instead.
    func request(_ permission: Permission, answered: @escaping @MainActor @Sendable () -> Void = {}) {
        if permission.hasSystemPrompt, !hasPrompted(permission) {
            notePrompted(permission)
            prompt(permission) { [weak self] in
                self?.refresh()
                answered()
            }
        } else {
            openSettings(for: permission)
            answered()
        }
        refresh()
    }

    private func hasPrompted(_ permission: Permission) -> Bool {
        defaults.stringArray(forKey: Self.promptedKey)?.contains(permission.rawValue) ?? false
    }

    private func notePrompted(_ permission: Permission) {
        var prompted = Set(defaults.stringArray(forKey: Self.promptedKey) ?? [])
        prompted.insert(permission.rawValue)
        defaults.set(prompted.sorted(), forKey: Self.promptedKey)
    }

    func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        openURL(url)
    }

    static func prompt(_ permission: Permission, answered: @escaping @MainActor @Sendable () -> Void) {
        defer { if permission != .audioCapture { answered() } }
        switch permission {
        case .accessibility:
            // String literal instead of kAXTrustedCheckOptionPrompt, which isn't concurrency-safe in Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .audioCapture:
            AudioCaptureAccess.request(answered: answered)
        case .automation, .fullDiskAccess, .admin:
            break
        }
    }

    static func check(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .inputMonitoring:
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? .granted : .denied
        case .fullDiskAccess:
            FullDiskAccess.isGranted() ? .granted : .denied
        case .audioCapture:
            AudioCaptureAccess.status()
        case .automation, .admin:
            .unknown
        }
    }
}

/// macOS has no call for whether an app has Full Disk Access, but only with it can the app open
/// the privacy database's own file.
nonisolated enum FullDiskAccess {
    static func isGranted(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let database = home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db")
        if let handle = FileHandle(forReadingAtPath: database.path) {
            try? handle.close()
            return true
        }
        // Where that file is missing, folders only Full Disk Access can look into tell instead.
        return ["Library/Safari", "Library/Mail"].contains { folder in
            (try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: folder).path)) != nil
        }
    }
}
