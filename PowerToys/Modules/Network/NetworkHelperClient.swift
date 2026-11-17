import Foundation
import Synchronization

/// What the Network module asks of the root helper; a protocol so tests change nothing.
protocol NetworkPrivileges: AnyObject {
    /// Called when the helper went away on its own, which stopped any throttle.
    var onInterrupted: (() -> Void)? { get set }
    var isAllowed: Bool { get }
    /// Registers the helper. Throws `HelperNeedsApproval` while it waits to be allowed in System Settings.
    func allow() throws
    /// Lets go of the helper, which is unregistered unless another feature still needs it.
    func disallow()
    /// Closes the throttle's connection, which makes the helper stop a throttle it started, but
    /// keeps the helper registered and leaves everything else as it is.
    func disconnect()
    func setThrottle(_ settings: ThrottleSettings?) async throws
    func setDNSServers(_ servers: [String], service: String) async throws
    func flushDNSCache() async throws
    /// Writes the resolver file, or removes it when it has no name servers.
    func setResolver(_ resolver: ResolverFile) async throws
    func setProxy(_ change: ProxyChange, service: String) async throws
}

/// Talks to the root helper over connections of its own, so a throttle, and proxies set on
/// this Mac, end when they close, as they do when the app quits or crashes.
final class NetworkHelperClient: NetworkPrivileges {
    var onInterrupted: (() -> Void)? {
        get { throttleConnection.onInterrupted }
        set { throttleConnection.onInterrupted = newValue }
    }
    private let registration: HelperRegistration
    /// The throttle has a connection of its own, so closing it to stop a throttle that didn't
    /// answer leaves proxies on this Mac, which end with the other, as they are.
    private let throttleConnection = HelperConnection()
    private let settingsConnection = HelperConnection()

    init(registration: HelperRegistration = .shared) {
        self.registration = registration
    }

    var isAllowed: Bool { registration.isAllowed }

    func allow() throws {
        try registration.allow(for: .network)
    }

    func disallow() {
        throttleConnection.drop()
        settingsConnection.drop()
        registration.release(.network)
    }

    func disconnect() {
        throttleConnection.drop()
    }

    func setThrottle(_ settings: ThrottleSettings?) async throws {
        let data = try settings.map { try JSONEncoder().encode($0) }
        // Dropping the connection makes the helper stop whatever it was starting, so the Mac
        // ends up as the app shows it: not throttled.
        try await call(throttleConnection, dropsOnTimeout: true) { $0.setThrottle(data, reply: $1) }
    }

    func setDNSServers(_ servers: [String], service: String) async throws {
        try await call(settingsConnection) { $0.setDNSServers(servers, service: service, reply: $1) }
    }

    func flushDNSCache() async throws {
        try await call(settingsConnection) { $0.flushDNSCache(reply: $1) }
    }

    func setResolver(_ resolver: ResolverFile) async throws {
        try await call(settingsConnection) {
            $0.setResolver(domain: resolver.domain, nameservers: resolver.nameservers, port: resolver.port ?? 0, reply: $1)
        }
    }

    func setProxy(_ change: ProxyChange, service: String) async throws {
        let data = try JSONEncoder().encode(change)
        try await call(settingsConnection) { $0.setProxy(data, service: service, reply: $1) }
    }

    /// Longer than the helper can take: it stops each tool it runs after 20 seconds, and runs at
    /// most eight for one request (turning three proxies on, or a throttle that fails and is
    /// cleared again).
    static let timeout: Duration = .seconds(170)

    /// Sends one request and waits for its reply, which is nil when it worked. Only a request
    /// that `dropsOnTimeout` closes the connection when it times out: that would also stop a
    /// throttle already running, which the app would go on showing.
    private func call(
        _ connection: HelperConnection, dropsOnTimeout: Bool = false,
        _ send: (any HelperProtocol, @escaping @Sendable (String?) -> Void) -> Void
    ) async throws {
        guard isAllowed else {
            throw CommandError(errorDescription: "Allow \(AppInfo.name) under Login Items & Extensions in System Settings first.")
        }
        do {
            let message: String? = try await withCheckedThrowingContinuation { continuation in
                let once = Once(continuation)
                let helper = connection.helper { error in
                    once.resume(throwing: CommandError(errorDescription: "The helper didn't answer: \(error.localizedDescription)"))
                }
                guard let helper else {
                    once.resume(throwing: CommandError(errorDescription: "This build of \(AppInfo.name) can't run the helper."))
                    return
                }
                send(helper) { once.resume(returning: $0) }
                once.timer = Task {
                    try? await Task.sleep(for: Self.timeout)
                    guard !Task.isCancelled else { return }
                    once.resume(throwing: TimedOut())
                }
            }
            if let message { throw CommandError(errorDescription: message) }
        } catch is TimedOut {
            guard dropsOnTimeout else {
                throw CommandError(errorDescription: "The helper didn't answer in time. The change may still go through.")
            }
            connection.drop()
            throw CommandError(errorDescription: "The helper didn't answer in time, so throttling was stopped.")
        }
    }

    private struct TimedOut: Error {}

    /// Resumes a continuation once, whichever of the reply, the error handler and the timer
    /// comes first, and stops the timer then.
    private nonisolated final class Once: Sendable {
        private let state: Mutex<(continuation: CheckedContinuation<String?, any Error>?, timer: Task<Void, Never>?)>

        init(_ continuation: CheckedContinuation<String?, any Error>) {
            state = Mutex((continuation, nil))
        }

        /// Set after the request is sent; cancelled at once if the reply already came.
        var timer: Task<Void, Never>? {
            get { state.withLock { $0.timer } }
            set {
                let resumed = state.withLock { state in
                    state.timer = newValue
                    return state.continuation == nil
                }
                if resumed { newValue?.cancel() }
            }
        }

        func resume(returning value: String?) {
            finish()?.resume(returning: value)
        }

        func resume(throwing error: any Error) {
            finish()?.resume(throwing: error)
        }

        private func finish() -> CheckedContinuation<String?, any Error>? {
            let (continuation, timer) = state.withLock { state in
                defer { state.continuation = nil }
                return (state.continuation, state.timer)
            }
            if continuation != nil { timer?.cancel() }
            return continuation
        }
    }
}
