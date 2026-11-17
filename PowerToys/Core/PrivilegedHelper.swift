import Foundation
import ServiceManagement
import Synchronization

/// A launchd daemon the app registers: `SMAppService` for real, a fake in tests.
protocol DaemonService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: DaemonService {}

/// What a feature needs the root helper for. The helper stays registered while any of these
/// does, so turning one feature off doesn't take it away from another.
nonisolated enum HelperUse: String, CaseIterable, Sendable {
    case lidSleep
    case network

    /// Whether the feature stays on while the helper waits for approval, and keeps asking for it
    /// with each change, as the Network module does. Lid sleep's switch stays off instead, and
    /// each try is the user turning it on again.
    var staysOnWhileWaiting: Bool { self == .network }
}

struct HelperNeedsApproval: LocalizedError {
    /// What waits for it: a feature that stays off meanwhile is turned on again, while a change
    /// such as flushing DNS is just tried again.
    var use: HelperUse = .lidSleep

    var errorDescription: String? {
        let then = use.staysOnWhileWaiting ? "try again" : "turn this on again"
        return "Allow \(AppInfo.name) under Login Items & Extensions in System Settings, then \(then)."
    }
}

/// Registers and unregisters the helper daemon in Contents/MacOS, which launchd runs as root once
/// it's registered here and allowed in System Settings. Remembers which features want it, so
/// it's unregistered only when the last of them lets go, and nothing runs as root otherwise.
final class HelperRegistration {
    static let shared = HelperRegistration()

    static let usesKey = "helperUses"

    private let service: (any DaemonService)?
    private let retired: (any DaemonService)?
    private let defaults: UserDefaults
    private let openSystemSettings: () -> Void
    /// Features that opened System Settings this launch. One that stays on while the helper
    /// waits opens it for its first request, not for every change or shortcut after it.
    private var openedSystemSettings: Set<HelperUse> = []

    init(
        service: (any DaemonService)?,
        retired: (any DaemonService)?,
        defaults: UserDefaults = .standard,
        openSystemSettings: @escaping () -> Void = SMAppService.openSystemSettingsLoginItems
    ) {
        self.service = service
        self.retired = retired
        self.defaults = defaults
        self.openSystemSettings = openSystemSettings
    }

    /// Made from Bundle.main, which isn't the app in every process that loads this, so a build
    /// without a bundle ID gets no helper.
    private convenience init() {
        let id = Bundle.main.bundleIdentifier
        self.init(
            service: id.map { SMAppService.daemon(plistName: HelperService.name(appBundleID: $0) + ".plist") },
            retired: id.map { SMAppService.daemon(plistName: HelperService.retiredName(appBundleID: $0) + ".plist") })
    }

    /// Whether the helper is registered and allowed to run.
    var isAllowed: Bool { service?.status == .enabled }

    /// The features that have asked for the helper and not let it go.
    private(set) var uses: Set<HelperUse> {
        get { Set((defaults.stringArray(forKey: Self.usesKey) ?? []).compactMap(HelperUse.init(rawValue:))) }
        set {
            guard newValue != uses else { return }
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.usesKey)
        }
    }

    /// Records that `use` needs the helper and registers it if it isn't yet. Called before every
    /// use, even when another feature already has it allowed, so letting go for that feature
    /// doesn't unregister it from under this one. Throws `HelperNeedsApproval` while it waits to
    /// be allowed there, and opens System Settings: each time for a feature that stays off
    /// meanwhile, and the first time each launch for one that stays on.
    func allow(for use: HelperUse) throws {
        guard let service else { throw CommandError(errorDescription: "This build of \(AppInfo.name) can't run the helper.") }
        // Recorded before it's allowed, so a helper approved later in System Settings stays
        // registered for a feature that stays on meanwhile. Turning it off lets it go, approved
        // or not. A feature that stays off doesn't hold it, so it can't keep the helper running
        // after every feature that's on lets go.
        let wasRecorded = uses.contains(use)
        uses.insert(use)
        do {
            try register(service)
        } catch {
            // Not waiting for approval but failing outright, as a broken build does: it's left
            // recorded only if it was before.
            if !wasRecorded { uses.remove(use) }
            throw error
        }
        guard service.status == .requiresApproval else { return }
        if !use.staysOnWhileWaiting || !openedSystemSettings.contains(use) {
            openedSystemSettings.insert(use)
            openSystemSettings()
        }
        if !use.staysOnWhileWaiting { uses.remove(use) }
        throw HelperNeedsApproval(use: use)
    }

    private func register(_ service: any DaemonService) throws {
        guard service.status != .enabled else { return }
        do {
            try service.register()
        } catch  where service.status == .requiresApproval || service.status == .enabled {
            // Throws while it waits for approval, and when it's registered already.
        }
    }

    /// Lets go of the helper for `use`, and unregisters it once no feature wants it. Does nothing
    /// to a helper that isn't registered.
    func release(_ use: HelperUse) {
        uses.remove(use)
        guard uses.isEmpty, let service, service.status != .notRegistered else { return }
        try? service.unregister()
    }

    /// Unregisters a helper approved under the Awake helper's old name, so it no longer shows in
    /// System Settings or runs. Returns whether it had been allowed, in which case lid sleep needs
    /// the new helper approved.
    func retireOldHelper() -> Bool {
        guard let retired else { return false }
        let status = retired.status
        guard status == .enabled || status == .requiresApproval else { return false }
        try? retired.unregister()
        return status == .enabled
    }
}

/// One feature's connection to the helper. Each feature keeps its own, so what the helper does
/// for it, such as holding sleep off or throttling, ends when this connection closes, as it does
/// when the app quits or crashes, without touching what it does for another feature.
final class HelperConnection {
    /// Called when the helper went away on its own: it restarted (and launchd starts a new one on
    /// the next call), or it was turned off or removed. Either way it undid what it did for this
    /// connection. Never called for a connection closed on purpose with `drop`.
    var onInterrupted: (() -> Void)?

    private let serviceName: String?
    private var connection: NSXPCConnection?
    private var state = ConnectionState()

    init(serviceName: String? = Bundle.main.bundleIdentifier.map(HelperService.name(appBundleID:))) {
        self.serviceName = serviceName
    }

    /// The helper, connecting first if need be; nil in a build without a bundle ID. `errorHandler`
    /// is called instead of the reply when the message can't be delivered.
    func helper(errorHandler: @escaping @Sendable (any Error) -> Void) -> (any HelperProtocol)? {
        guard let serviceName else { return nil }
        // The helper may have gone away without the main actor hearing yet. Reported now, before
        // anything new is sent, so the report can't arrive after this request and undo it.
        report(state)
        // Invalidated: it can't be used again.
        if state.isInvalid { connection = nil }
        let connection = connection ?? connect(serviceName)
        return connection.remoteObjectProxyWithErrorHandler(errorHandler) as? any HelperProtocol
    }

    /// Closes the connection on purpose, which its handlers then ignore. The helper undoes what it
    /// did for it.
    func drop() {
        state.markDropped()
        connection?.invalidate()
        connection = nil
    }

    private func connect(_ serviceName: String) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // Each connection has its own state, so a handler reports on the connection it belongs to
        // even once a new one has replaced it.
        let state = ConnectionState()
        self.state = state
        let wentAway: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Recognised by its state rather than the connection's address, which a newer
                // connection, made after this one was let go, can reuse.
                if state.isInvalid, self.state === state { self.connection = nil }
                self.report(state)
            }
        }
        connection.interruptionHandler = {
            state.markWentAway(invalid: false)
            wentAway()
        }
        connection.invalidationHandler = {
            state.markWentAway(invalid: true)
            wentAway()
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// Tells `onInterrupted` once about each time the helper went away that it hasn't heard of,
    /// unless the connection was closed on purpose.
    private func report(_ state: ConnectionState) {
        if state.takeUnreported() { onInterrupted?() }
    }
}

/// Whether a connection was invalidated or closed on purpose, and whether the helper went away
/// since that was last reported, readable from any thread.
private nonisolated final class ConnectionState: Sendable {
    private let flags = Mutex((invalid: false, dropped: false, unreported: false))

    var isInvalid: Bool { flags.withLock { $0.invalid } }

    func markWentAway(invalid: Bool) {
        flags.withLock {
            $0.unreported = true
            if invalid { $0.invalid = true }
        }
    }

    func markDropped() { flags.withLock { $0.dropped = true } }

    /// Whether there's something to report, which counts as reported from now on.
    func takeUnreported() -> Bool {
        flags.withLock { flags in
            defer { flags.unreported = false }
            return flags.unreported && !flags.dropped
        }
    }
}
