import Foundation

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
