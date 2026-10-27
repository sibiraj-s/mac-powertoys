import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import Observation

enum Permission: String, CaseIterable, Identifiable, Sendable {
    case accessibility, screenRecording, inputMonitoring, automation, fullDiskAccess, microphone, admin

    var id: Self { self }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .inputMonitoring: "Input Monitoring"
        case .automation: "Automation"
        case .fullDiskAccess: "Full Disk Access"
        case .microphone: "Microphone"
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
        case .microphone: "mic"
        case .admin: "lock.shield"
        }
    }

    var explanation: String {
        switch self {
        case .accessibility: "Move and resize windows, read the menu bar and simulate key presses."
        case .screenRecording: "Show window previews, pick colors and read text from the screen."
        case .inputMonitoring: "Listen for global shortcuts and remap keys."
        case .automation: "Ask System Events and Finder to switch settings such as dark mode and to empty the Trash."
        case .fullDiskAccess: "See which process holds a file anywhere on disk."
        case .microphone: "Mute and unmute the microphone globally."
        case .admin: "Edit system files such as /etc/hosts. Asked for each change."
        }
    }

    /// Deep link into the matching System Settings privacy pane.
    var settingsURL: URL? {
        let anchor: String? = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .automation: "Privacy_Automation"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .microphone: "Privacy_Microphone"
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

    init() {
        refresh()
    }

    func status(_ permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .unknown
    }

    func refresh() {
        for permission in Permission.allCases {
            statuses[permission] = Self.check(permission)
        }
    }

    func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            // String literal instead of kAXTrustedCheckOptionPrompt, which isn't concurrency-safe in Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .automation, .fullDiskAccess, .microphone, .admin:
            openSettings(for: permission)
        }
        refresh()
    }

    func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    private static func check(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .inputMonitoring:
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? .granted : .denied
        case .automation, .fullDiskAccess, .microphone, .admin:
            .unknown
        }
    }
}
