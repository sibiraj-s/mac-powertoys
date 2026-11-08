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
    static func testing(
        defaults: UserDefaults, hotKeys: any HotKeyRegistering, system: any SystemSettingsAccess, pinCrop: PinCropController? = nil,
        displaysAudio: DisplaysAudioController? = nil, screenRuler: ScreenRulerController? = nil
    ) -> AppState {
        AppState(
            defaults: defaults,
            permissions: PermissionsService(defaults: defaults, check: { _ in .denied }, prompt: { _, _ in }, openURL: { _ in }),
            clipboardStore: nil, hotKeys: hotKeys, system: system,
            hostsStore: FakeHostsStore(), hostsBackup: nil,
            environment: EnvironmentController(
                loginShell: nil, sources: [.apps], probe: FakeProbe(), pathSources: { [:] }, exists: { _ in true }),
            defaultsStore: FakeDefaultsStore(), defaultsBackups: nil, pinCrop: pinCrop,
            keyMapping: FakeKeyMappingStore(),
            displaysAudio: displaysAudio ?? .testing(defaults: defaults),
            finder: FakeFinder(),
            screenRuler: screenRuler
        )
    }
}

/// Waits like a stuck tool: it doesn't notice cancellation. Unlike usleep it doesn't hold one of
/// Swift's concurrency threads, which are as few as the cores; on a CI runner a few of those at
/// once stall every other test.
nonisolated func stall(seconds: Double) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}
