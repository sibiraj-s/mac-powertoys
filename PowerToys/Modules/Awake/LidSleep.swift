import Foundation
import Synchronization

/// Turns the Mac's sleep off altogether, so a laptop stays awake with its lid closed, which power
/// assertions can't do. That takes root, which the app gets from its helper.
protocol LidSleepControl: AnyObject {
    /// Called when the helper went away on its own (it restarted, or was turned off or removed),
    /// which turned sleep back on and dropped every hold.
    var onInterrupted: (() -> Void)? { get set }
    /// Whether the helper is registered and allowed to run.
    var isAllowed: Bool { get }
    /// Whether this launch unregistered a helper approved under the Awake helper's old name, which
    /// leaves lid sleep waiting for the new one to be allowed.
    var replacedOldHelper: Bool { get }
    /// Registers the helper. Throws `HelperNeedsApproval` while it waits to be allowed in System Settings.
    func allow() throws
    /// Lets go of the helper, which is unregistered unless another feature still needs it.
    func disallow()
    /// Returns whether it worked; on failure the helper is no longer holding sleep off. Waits for the
    /// answer, so the Mac's state never lags behind Awake's.
    @discardableResult func setSleepDisabled(_ disabled: Bool) -> Bool
}

/// Talks to the root helper over its own connection, so the sleep hold ends when this connection
/// closes, whatever else the helper is doing for other features.
final class LidSleepClient: LidSleepControl {
    /// Called on the main actor's next turn, never in the middle of `setSleepDisabled`, whose
    /// connection can report it: the handler makes calls of its own, and works out afresh what
    /// lid sleep should be, so it needn't come before the call that found out.
    var onInterrupted: (() -> Void)? {
        didSet {
            connection.onInterrupted = onInterrupted.map { handler in
                { Task { @MainActor in handler() } }
            }
        }
    }
    let replacedOldHelper: Bool
    private let registration: HelperRegistration
    private let connection = HelperConnection()

    init(registration: HelperRegistration = .shared) {
        self.registration = registration
        replacedOldHelper = registration.retireOldHelper()
    }

    var isAllowed: Bool { registration.isAllowed }

    func allow() throws {
        try registration.allow(for: .lidSleep)
    }

    func disallow() {
        connection.drop()
        registration.release(.lidSleep)
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let result = Reply()
        let helper = connection.helper { @Sendable _ in done.signal() }
        helper?.setSleepDisabled(disabled) { ok in
            result.ok.withLock { $0 = ok }
            done.signal()
        }
        // pmset answers in well under a second; a helper that doesn't counts as failed, rather than freezing the app.
        guard helper != nil, done.wait(timeout: .now() + 5) == .success, result.ok.withLock({ $0 }) else {
            // Closing the connection drops this app's hold, so the helper turns sleep back on.
            connection.drop()
            return false
        }
        return true
    }

    /// Filled in by the reply, which can still arrive after a timeout gave up on it.
    private nonisolated final class Reply: Sendable {
        let ok = Mutex(false)
    }
}
