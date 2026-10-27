import AppKit
import CoreWLAN

/// Reads and changes system settings; a protocol so tests don't flip the real ones.
protocol SystemSettingsAccess {
    /// Whether a toggle is on, or nil when it can't be read (actions, or no Wi‑Fi hardware).
    func isOn(_ toggle: SystemToggle) -> Bool?
    func set(_ toggle: SystemToggle, on: Bool) throws
    /// Runs an action; slow ones, such as ejecting disks, finish off the main thread.
    func run(_ action: SystemToggle) async throws
}

struct SystemSettingsError: LocalizedError {
    let errorDescription: String?
}

/// The real settings, through preferences, System Events, Finder, CoreWLAN and NSWorkspace.
struct LiveSystemSettings: SystemSettingsAccess {
    func isOn(_ toggle: SystemToggle) -> Bool? {
        switch toggle {
        case .darkMode:
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        case .hideDock:
            Preferences.bool("autohide", in: "com.apple.dock") ?? false
        case .hideMenuBar:
            Preferences.bool("_HIHideMenuBar", in: Preferences.global) ?? false
        case .hideDesktopIcons:
            !(Preferences.bool("CreateDesktop", in: "com.apple.finder") ?? true)
        case .showHiddenFiles:
            Preferences.bool("AppleShowAllFiles", in: "com.apple.finder") ?? false
        case .showFileExtensions:
            Preferences.bool("AppleShowAllExtensions", in: Preferences.global) ?? false
        case .wifi:
            CWWiFiClient.shared().interface()?.powerOn()
        case .sleepDisplay, .startScreenSaver, .ejectDisks, .emptyTrash:
            nil
        }
    }

    func set(_ toggle: SystemToggle, on: Bool) throws {
        switch toggle {
        case .darkMode:
            try AppleScript.run("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
        case .hideDock:
            try AppleScript.run("tell application \"System Events\" to tell dock preferences to set autohide to \(on)")
        case .hideMenuBar:
            try AppleScript.run("tell application \"System Events\" to tell dock preferences to set autohide menu bar to \(on)")
        case .hideDesktopIcons:
            Preferences.set(!on, for: "CreateDesktop", in: "com.apple.finder")
            Finder.relaunch()
        case .showHiddenFiles:
            Preferences.set(on, for: "AppleShowAllFiles", in: "com.apple.finder")
            Finder.relaunch()
        case .showFileExtensions:
            Preferences.set(on, for: "AppleShowAllExtensions", in: Preferences.global)
            Finder.relaunch()
        case .wifi:
            guard let interface = CWWiFiClient.shared().interface() else {
                throw SystemSettingsError(errorDescription: "This Mac has no Wi‑Fi.")
            }
            try interface.setPower(on)
        case .sleepDisplay, .startScreenSaver, .ejectDisks, .emptyTrash:
            preconditionFailure("\(toggle) is an action; use run(_:)")
        }
    }

    func run(_ action: SystemToggle) async throws {
        switch action {
        case .sleepDisplay:
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            try process.run()
        case .startScreenSaver:
            NSWorkspace.shared.open(URL(filePath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
        case .ejectDisks:
            let volumes = Self.ejectableVolumes()
            guard !volumes.isEmpty else {
                throw SystemSettingsError(errorDescription: "There are no disks to eject.")
            }
            let failed = await Self.eject(volumes)
            if !failed.isEmpty {
                throw SystemSettingsError(errorDescription: "Couldn't eject \(failed.joined(separator: ", ")). Something may still be using it.")
            }
        case .emptyTrash:
            try AppleScript.run("tell application \"Finder\" to empty trash")
        default:
            preconditionFailure("\(action) is a toggle; use set(_:on:)")
        }
    }

    /// Ejects each volume and returns the names of those that wouldn't go. Unmounting waits on
    /// the disk, so it runs off the main thread.
    @concurrent
    private nonisolated static func eject(_ volumes: [URL]) async -> [String] {
        var failed: [String] = []
        for volume in volumes {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            } catch {
                failed.append(volume.lastPathComponent)
            }
        }
        return failed
    }

    /// External drives and disk images, not the startup disk or network shares.
    static func ejectableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey,
        ]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            if values.volumeIsRootFileSystem == true || values.volumeIsLocal != true { return false }
            return values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false
        }
    }
}

/// Other apps' preferences, through cfprefsd so the apps see the change.
enum Preferences {
    static let global = kCFPreferencesAnyApplication as String

    static func bool(_ key: String, in domain: String) -> Bool? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Bool
    }

    static func set(_ value: Bool, for key: String, in domain: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

enum AppleScript {
    static func run(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw SystemSettingsError(errorDescription: "The change didn't go through.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return }
        // -1743: the user hasn't allowed Automation for the target app.
        if error[NSAppleScript.errorNumber] as? Int == -1743 {
            throw SystemSettingsError(errorDescription: "Allow PowerToys under Privacy & Security → Automation.")
        }
        throw SystemSettingsError(errorDescription: error[NSAppleScript.errorMessage] as? String ?? "The change didn't go through.")
    }
}

enum Finder {
    static let bundleID = "com.apple.finder"

    private static var pendingRelaunch: Task<Void, Never>?

    /// Finder reads these settings only at launch, so it has to restart. Quick changes in a row
    /// share one restart. Finder quits the way `killall Finder` asks it to, so copies in progress
    /// wind down instead of being cut off, and comes back by itself; this reopens it if it doesn't.
    static func relaunch() {
        pendingRelaunch?.cancel()
        pendingRelaunch = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                kill(app.processIdentifier, SIGTERM)
            }
            try? await Task.sleep(for: .seconds(1.5))
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
