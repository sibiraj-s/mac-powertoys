// PowerToys' helper. launchd runs it as root once the app registers it, from the plist in
// Contents/Library/LaunchDaemons, whose only argument is the app's bundle ID. It answers only the
// app signed with that ID by the same team as this helper, and only does the narrow things
// `HelperProtocol` lists, each undone when the connection that asked for it closes.

import Foundation
import Security

nonisolated final class Session: NSObject, HelperProtocol {
    let id = UUID()
    let holds: SleepHolds
    let throttle: Throttle
    let proxies: ProxyLeases

    init(holds: SleepHolds, throttle: Throttle, proxies: ProxyLeases) {
        self.holds = holds
        self.throttle = throttle
        self.proxies = proxies
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(holds.set(disabled, for: id))
    }

    func setThrottle(_ settings: Data?, reply: @escaping @Sendable (String?) -> Void) {
        guard let settings else { return reply(throttle.set(nil, for: id)) }
        guard let decoded = try? JSONDecoder().decode(ThrottleSettings.self, from: settings) else {
            return reply("The throttle settings couldn't be read.")
        }
        reply(throttle.set(decoded, for: id))
    }

    func setDNSServers(_ servers: [String], service: String, reply: @escaping @Sendable (String?) -> Void) {
        reply(NetworkSettings.setDNSServers(servers, service: service))
    }

    func flushDNSCache(reply: @escaping @Sendable (String?) -> Void) {
        reply(NetworkSettings.flushDNSCache())
    }

    func setResolver(domain: String, nameservers: [String], port: Int, reply: @escaping @Sendable (String?) -> Void) {
        reply(NetworkSettings.setResolver(ResolverFile(domain: domain, nameservers: nameservers, port: port > 0 ? port : nil)))
    }

    func setProxy(_ change: Data, service: String, reply: @escaping @Sendable (String?) -> Void) {
        guard let decoded = try? JSONDecoder().decode(ProxyChange.self, from: change) else {
            return reply("The proxy settings couldn't be read.")
        }
        reply(proxies.set(decoded, service: service, for: id))
    }
}

nonisolated final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let clientRequirement: String?
    let holds = SleepHolds()
    let throttle: Throttle
    let proxies: ProxyLeases

    init(clientRequirement: String?, throttle: Throttle, proxies: ProxyLeases) {
        self.clientRequirement = clientRequirement
        self.throttle = throttle
        self.proxies = proxies
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Unsigned or ad hoc builds have no team to check callers against, so nothing may connect.
        guard let clientRequirement else { return false }
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        let session = Session(holds: holds, throttle: throttle, proxies: proxies)
        connection.exportedObject = session
        let id = session.id
        let holds = holds
        let throttle = throttle
        let proxies = proxies
        // The app quit, crashed or let go: its hold, throttle and proxies on this Mac end with it.
        connection.invalidationHandler = {
            holds.release(id)
            throttle.release(id)
            proxies.release(id)
        }
        connection.resume()
        return true
    }
}

/// The app with `bundleID`, signed by the team that signed this helper.
nonisolated func clientRequirement(bundleID: String) -> String? {
    guard bundleID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
        SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    else { return nil }
    return "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
}

let arguments = CommandLine.arguments
// Started from the plist kept under the Awake helper's old name, at boot until the app unregisters
// it. The old helper turned sleep back on at boot, in case it had left it off, so this does too.
if arguments.dropFirst().first == HelperService.retiredArgument {
    _ = SleepHolds.pmset(disableSleep: false)
    exit(0)
}
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: PowerToysHelper <app bundle ID>\n".utf8))
    exit(64)
}
// `disablesleep` outlives this process, so sleep left off by a helper that crashed, or by a Mac
// that lost power, comes back on here. Nothing holds it yet: launchd starts the helper at boot
// (RunAtLoad), after a crash (KeepAlive) or for a new connection. The same goes for a throttle,
// and for proxies on this Mac.
let throttle = Throttle(rules: ThrottleRules(appBundleID: arguments[1]))
let proxies = ProxyLeases(appBundleID: arguments[1])
_ = SleepHolds.pmset(disableSleep: false)
throttle.clearLeftovers()
proxies.clearLeftovers()
// launchd stops the helper with SIGTERM when it's turned off in System Settings, unregistered,
// replaced by an update or the Mac shuts down; sleep comes back on, throttling stops and proxies on
// this Mac turn off before it goes. It exits 0 then, so KeepAlive restarts it only after a crash,
// to clear what the crashed one left.
signal(SIGTERM, SIG_IGN)
// A tool that exits before reading its input fails the write instead of ending the helper, and
// with it every hold and throttle.
signal(SIGPIPE, SIG_IGN)
let delegate = ListenerDelegate(clientRequirement: clientRequirement(bundleID: arguments[1]), throttle: throttle, proxies: proxies)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    delegate.holds.releaseAll()
    delegate.throttle.releaseAll()
    delegate.proxies.releaseAll()
    exit(0)
}
termination.resume()
let listener = NSXPCListener(machServiceName: HelperService.name(appBundleID: arguments[1]))
listener.delegate = delegate
listener.resume()
dispatchMain()
