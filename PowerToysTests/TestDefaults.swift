import Foundation
import Synchronization

@testable import PowerToys

/// A defaults domain of the test's own, so tests never touch the app's real settings.
///
/// Names come from a pool and are used again, never made new for each test: cfprefsd keeps a
/// file handle open for each separate domain that's emptied, so a new domain per test used up
/// its handles after two test runs, and then no app on the Mac could save its settings. Each
/// name is cleared when it's handed out, so the last test's values stay on disk until then, in
/// the same few files every run.
///
/// Use `defaults` only: the pool knows a name is free once that object is gone, and can't see
/// the domain opened again by name.
nonisolated final class TestDefaults {
    private struct Pool {
        var free: [String] = []
        /// Names whose TestDefaults has gone, held until nothing it made, such as a controller
        /// still running, can use their defaults.
        var returned: [(name: String, defaults: WeakDefaults)] = []
        var made = 0
    }

    /// UserDefaults is thread-safe, though not marked Sendable.
    private struct WeakDefaults: @unchecked Sendable {
        weak var value: UserDefaults?
    }

    private static let pool = Mutex(Pool())

    /// The lowest number no other test process holds, held until this one exits. Runs one after
    /// another use the same names; runs at the same time, such as Xcode's and xcodebuild's, use
    /// different ones.
    static let processSlot: Int = {
        var slot = 1
        while true {
            let lock = FileManager.default.temporaryDirectory.appending(path: "PowerToysTests.\(slot).lock")
            // Left open, so the lock lasts until the process exits.
            let file = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard file >= 0 else { preconditionFailure("Can't open \(lock.path): \(String(cString: strerror(errno)))") }
            if flock(file, LOCK_EX | LOCK_NB) == 0 { return slot }
            let error = errno
            close(file)
            // Anything but another process holding it would fail the same way for every slot.
            guard error == EWOULDBLOCK else { preconditionFailure("Can't lock \(lock.path): \(String(cString: strerror(error)))") }
            slot += 1
        }
    }()

    private let suiteName: String
    let defaults: UserDefaults

    init() {
        suiteName = Self.pool.withLock { pool in
            var stillUsed: [(name: String, defaults: WeakDefaults)] = []
            for entry in pool.returned {
                if entry.defaults.value == nil { pool.free.append(entry.name) } else { stillUsed.append(entry) }
            }
            pool.returned = stillUsed
            if let name = pool.free.popLast() { return name }
            pool.made += 1
            return "PowerToysTests.\(Self.processSlot).\(pool.made)"
        }
        defaults = UserDefaults(suiteName: suiteName)!
        // What the last test with this name, or a run that stopped partway, left.
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        Self.pool.withLock { $0.returned.append((suiteName, WeakDefaults(value: defaults))) }
    }
}

extension AppState {
    /// An app state that touches no files, shortcuts or settings outside the test.
    static func testing(
        defaults: UserDefaults, hotKeys: any HotKeyRegistering, system: any SystemSettingsAccess, pinCrop: PinCropController? = nil,
        displaysAudio: DisplaysAudioController? = nil, screenRuler: ScreenRulerController? = nil,
        laneWindows: any LaneWindowSystem = FakeLaneWindows(), networkReader: FakeNetworkReader = FakeNetworkReader()
    ) -> AppState {
        AppState(
            defaults: defaults,
            lidSleep: FakeLidSleep(),
            permissions: PermissionsService(defaults: defaults, check: { _ in .denied }, prompt: { _, _ in }, openURL: { _ in }),
            clipboardStore: nil, hotKeys: hotKeys, system: system,
            hostsStore: FakeHostsStore(), hostsBackup: nil,
            environment: EnvironmentController(
                loginShell: nil, sources: [.apps], probe: FakeProbe(), pathSources: { [:] }, exists: { _ in true }),
            defaultsStore: FakeDefaultsStore(), defaultsBackups: nil, pinCrop: pinCrop,
            keyMapping: FakeKeyMappingStore(),
            displaysAudio: displaysAudio ?? .testing(defaults: defaults),
            finder: FakeFinder(),
            screenRuler: screenRuler,
            laneWindows: laneWindows,
            networkHelper: FakeNetworkHelper(),
            networkReader: networkReader,
            networkInfo: NetworkInfoController(reader: networkReader, makeLocation: nil)
        )
    }
}

/// A stuck tool that stays stuck until the test opens the gate, however slow the machine is, so a
/// call that returns while it's closed proves nothing waited for the tool.
nonisolated final class Gate: Sendable {
    private let waiters = Mutex<(isOpen: Bool, continuations: [CheckedContinuation<Void, Never>])>((false, []))

    /// Doesn't notice cancellation, like a tool blocked on a stalled disk.
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = waiters.withLock { state in
                if state.isOpen { return true }
                state.continuations.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let continuations = waiters.withLock { state in
            state.isOpen = true
            defer { state.continuations = [] }
            return state.continuations
        }
        for continuation in continuations { continuation.resume() }
    }
}

/// Waits like a slow tool: it doesn't notice cancellation. Unlike usleep it doesn't hold one of
/// Swift's concurrency threads, which are as few as the cores; on a CI runner a few of those at
/// once stall every other test.
nonisolated func stall(seconds: Double) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}

/// Records what Awake asks of the lid-sleep control, without a helper.
final class FakeLidSleep: LidSleepControl {
    var onInterrupted: (() -> Void)?
    var isAllowed = false
    var replacedOldHelper = false
    var needsApproval = false
    var works = true
    private(set) var calls: [Bool] = []
    private(set) var allowed = 0
    private(set) var disallowed = 0

    func allow() throws {
        if needsApproval { throw HelperNeedsApproval() }
        isAllowed = true
        allowed += 1
    }

    /// Like the real one, does nothing when it isn't registered.
    func disallow() {
        guard isAllowed else { return }
        isAllowed = false
        disallowed += 1
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        calls.append(disabled)
        return works
    }
}
