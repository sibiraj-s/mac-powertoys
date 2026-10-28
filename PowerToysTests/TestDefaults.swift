import Foundation
@testable import PowerToys

/// A throwaway defaults domain so tests never touch the app's real settings.
final class TestDefaults {
    let suiteName = "PowerToysTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension AppState {
    /// An app state that touches no files, shortcuts or settings outside the test.
    static func testing(defaults: UserDefaults, hotKeys: any HotKeyRegistering, system: any SystemSettingsAccess) -> AppState {
        AppState(
            defaults: defaults, clipboardStore: nil, hotKeys: hotKeys, system: system,
            hostsStore: FakeHostsStore(), hostsBackup: nil,
            environment: EnvironmentController(loginShell: nil, sources: [.apps], probe: FakeProbe(), pathSources: { [:] }, exists: { _ in true }),
            defaultsStore: FakeDefaultsStore(), defaultsBackups: nil
        )
    }
}
