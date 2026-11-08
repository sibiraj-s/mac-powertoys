import Sparkle
import SwiftUI

/// Finds, downloads and installs new versions of PowerToys with Sparkle, from the appcast
/// attached to the latest GitHub release.
@Observable
final class Updater {
    static let shared = Updater()
    static let releasesPage = URL(string: "https://github.com/sibiraj-s/mac-powertoys/releases/latest")!

    /// Only builds signed for release carry the key that verifies updates; others (local
    /// and ad hoc builds) link to the releases page instead. Development builds aren't
    /// versioned, so every release would look newer.
    #if DEBUG
        let isEnabled = false
    #else
        let isEnabled = !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
    #endif

    /// False while a check or an update is in progress.
    private(set) var canCheck = false

    /// Sparkle's own setting: it checks once a day by default and saves the choice itself.
    /// Sparkle never changes it on its own, since Info.plist turns its permission prompt off.
    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) { controller.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    @ObservationIgnored private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {}

    func start() {
        guard isEnabled else { return }
        controller.startUpdater()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { _, change in
            let canCheck = change.newValue ?? false
            MainActor.assumeIsolated { Updater.shared.canCheck = canCheck }
        }
    }

    /// Whether "Check for Updates…" can run now: always, when it opens the releases page.
    var canCheckNow: Bool { !isEnabled || canCheck }

    /// "Check for Updates…": Sparkle's window reports the result.
    func checkNow() {
        if !isEnabled {
            NSWorkspace.shared.open(Self.releasesPage)
        } else if canCheck {
            NSApp.activate()
            controller.checkForUpdates(nil)
        }
    }
}

/// A View, not inline in the app's commands: Commands don't reliably redraw when `canCheck`
/// changes, which could leave the item disabled after Sparkle starts.
struct CheckForUpdatesButton: View {
    var body: some View {
        Button("Check for Updates…") { Updater.shared.checkNow() }
            .disabled(!Updater.shared.canCheckNow)
    }
}
