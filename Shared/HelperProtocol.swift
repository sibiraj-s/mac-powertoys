import Foundation

/// What PowerToys asks of its helper, which runs as root, over XPC. Each feature opens its own
/// connection, so what one feature changed is undone when its connection closes, without touching
/// what another holds.
@objc nonisolated protocol HelperProtocol {
    /// Turns system sleep off or back on with `pmset -a disablesleep`. Sleep comes back on by itself
    /// when the connection that turned it off closes, so a crashed app can't leave it off.
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void)

    // The network replies carry nil when it worked, or what went wrong.

    /// Throttles the network as JSON-encoded `ThrottleSettings` describe, or stops with nil. The
    /// throttle ends by itself when the connection that started it closes.
    func setThrottle(_ settings: Data?, reply: @escaping @Sendable (String?) -> Void)

    /// Sets the DNS servers of a network service, or goes back to the ones it's given with none.
    func setDNSServers(_ servers: [String], service: String, reply: @escaping @Sendable (String?) -> Void)

    func flushDNSCache(reply: @escaping @Sendable (String?) -> Void)

    /// Writes /etc/resolver/`domain`, or removes it with no name servers. Only files the app wrote
    /// can be changed or removed.
    func setResolver(domain: String, nameservers: [String], port: Int, reply: @escaping @Sendable (String?) -> Void)

    /// Applies a JSON-encoded `ProxyChange` to a network service.
    func setProxy(_ change: Data, service: String, reply: @escaping @Sendable (String?) -> Void)
}

nonisolated enum HelperService {
    /// Also the launchd label and the plist's name, so the Debug and installed apps each get their own.
    static func name(appBundleID: String) -> String { appBundleID + ".Helper" }

    /// What the helper was called when it only served Awake. The app still ships a plist with this
    /// name so it can unregister a helper that was approved under it.
    static func retiredName(appBundleID: String) -> String { appBundleID + ".AwakeHelper" }

    /// The argument the retired plist runs the helper with, which makes it exit straight away.
    static let retiredArgument = "--retired"
}
