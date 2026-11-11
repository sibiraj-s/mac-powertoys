import Foundation
import ServiceManagement
import Synchronization

/// Turns the Mac's sleep off altogether, so a laptop stays awake with its lid closed, which power
/// assertions can't do. That takes root, which the app gets from its Awake helper.
protocol LidSleepControl: AnyObject {
    /// Called when the helper went away on its own (it restarted, or was turned off or removed),
    /// which turned sleep back on and dropped every hold.
    var onInterrupted: (() -> Void)? { get set }
    /// Whether the helper is registered and allowed to run.
    var isAllowed: Bool { get }
    /// Registers the helper. Throws `LidSleepNeedsApproval` while it waits to be allowed in System Settings.
    func allow() throws
    /// Unregisters the helper, so nothing runs as root while the setting is off. Does nothing when it isn't registered.
    func disallow()
    /// Returns whether it worked; on failure the helper is no longer holding sleep off. Waits for the
    /// answer, so the Mac's state never lags behind Awake's.
    @discardableResult func setSleepDisabled(_ disabled: Bool) -> Bool
}

struct LidSleepNeedsApproval: LocalizedError {
    var errorDescription: String? {
        "Allow \(AppInfo.name) under Login Items & Extensions in System Settings, then turn this on again."
    }
}

/// Talks to the helper daemon in Contents/MacOS, which launchd runs as root once it's registered
/// here and allowed in System Settings.
final class AwakeHelperClient: LidSleepControl {
    var onInterrupted: (() -> Void)?
    private static let serviceName = Bundle.main.bundleIdentifier.map(AwakeHelperService.name(appBundleID:))
    /// Made on first use, as Bundle.main isn't the app in every process that loads this.
    private lazy var service = Self.serviceName.map { SMAppService.daemon(plistName: $0 + ".plist") }
    private var connection: NSXPCConnection?
    /// Counts connections, so an interruption can tell whether it's about the current one.
    private var connectionGeneration = 0

    var isAllowed: Bool { service?.status == .enabled }

    func allow() throws {
        guard let service else { throw CommandError(errorDescription: "This build of \(AppInfo.name) can't run the helper.") }
        do {
            try service.register()
        } catch  where service.status == .requiresApproval || service.status == .enabled {
            // Throws while it waits for approval, and when it's registered already.
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw LidSleepNeedsApproval()
        }
    }

    func disallow() {
        dropConnection()
        guard let service, service.status != .notRegistered else { return }
        try? service.unregister()
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        guard let serviceName = Self.serviceName else { return false }
        let connection = connection ?? makeConnection(serviceName)
        let done = DispatchSemaphore(value: 0)
        let result = Reply()
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in done.signal() } as? AwakeHelperProtocol
        proxy?.setSleepDisabled(disabled) { ok in
            result.ok.withLock { $0 = ok }
            done.signal()
        }
        // pmset answers in well under a second; a helper that doesn't counts as failed, rather than freezing the app.
        guard proxy != nil, done.wait(timeout: .now() + 5) == .success, result.ok.withLock({ $0 }) else {
            // Closing the connection drops this app's hold, so the helper turns sleep back on.
            dropConnection()
            return false
        }
        return true
    }

    /// Closes the connection on purpose, which its handlers then ignore.
    private func dropConnection() {
        connectionGeneration += 1
        connection?.invalidate()
        connection = nil
    }

    /// The helper turns sleep back on when this closes, which happens when the app quits or crashes.
    private func makeConnection(_ serviceName: String) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: AwakeHelperProtocol.self)
        // The helper died and launchd starts a new one on the next call (interrupted), or it was
        // turned off or removed (invalidated). Either way sleep is back on with no holds. A connection
        // closed on purpose or replaced since has a stale generation and says nothing about the hold.
        connectionGeneration += 1
        let generation = connectionGeneration
        let wentAway: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }
                self.onInterrupted?()
            }
        }
        connection.interruptionHandler = wentAway
        connection.invalidationHandler = wentAway
        connection.resume()
        self.connection = connection
        return connection
    }

    /// Filled in by the reply, which can still arrive after a timeout gave up on it.
    private nonisolated final class Reply: Sendable {
        let ok = Mutex(false)
    }
}
