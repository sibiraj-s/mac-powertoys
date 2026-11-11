import AppKit
import Foundation
import Testing

@testable import PowerToys

/// A Debug build runs next to the installed app, so nothing either makes may clash, and the two
/// must be easy to tell apart.
struct AppIdentityTests {
    @Test func audioDevicesStartWithTheBundleID() throws {
        let id = try #require(Bundle.main.bundleIdentifier)
        #expect(LiveAudioDevices.multiOutputUID == id + ".multioutput")
        #expect(AppVolumeTap.uidPrefix == id + ".appvolume")
    }

    @Test func supportFolderIsNamedAfterTheApp() {
        #expect(URL.powerToysSupportDirectory.lastPathComponent == AppInfo.name)
        #if DEBUG
            // A Debug build must not use the installed app's folder.
            #expect(AppInfo.name != "PowerToys")
        #endif
    }

    /// There's one /etc/hosts and one of each system preference domain, so every build shares one
    /// original of each.
    @Test func systemBackupsAreSharedBetweenBuilds() throws {
        let shared = URL.applicationSupportDirectory.appending(path: "PowerToys")
        #expect(HostsController.defaultBackupURL == shared.appending(path: "hosts.original"))
        #expect(DefaultsBrowserController.defaultBackupDirectory == shared.appending(path: "Defaults Backups"))
    }

    /// Permission prompts name the build asking, so the right one is allowed.
    @Test func permissionPromptsNameTheApp() throws {
        for key in ["NSAppleEventsUsageDescription", "NSAudioCaptureUsageDescription"] {
            let text = try #require(Bundle.main.object(forInfoDictionaryKey: key) as? String)
            #expect(text.hasPrefix(AppInfo.name + " "))
        }
    }

    @Test func menuBarIconAddsADot() throws {
        let symbol = MenuBarIcon.symbol
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        let dotted = MenuBarIcon.dotted(symbol)
        // Drawn in the menu bar's colour, like the plain symbol.
        #expect(dotted.isTemplate)

        // The dot sits in the lower-right corner.
        let tiff = try #require(dotted.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let scale = CGFloat(rep.pixelsWide) / dotted.size.width
        let center = rep.colorAt(x: rep.pixelsWide - Int(3 * scale), y: rep.pixelsHigh - Int(3 * scale))
        #expect((center?.alphaComponent ?? 0) > 0.9)
    }
}
