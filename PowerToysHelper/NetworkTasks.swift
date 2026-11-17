import Foundation
import Synchronization

/// The one throttle the helper runs, and which connection owns it. Starting a throttle from
/// another connection takes it over; closing the owner's connection stops it.
nonisolated final class Throttle: Sendable {
    private static let pfctl = "/sbin/pfctl"
    private static let dnctl = "/usr/sbin/dnctl"
    /// pfctl and dnctl answer in milliseconds. Kept short because each runs under the lock that
    /// shutting down waits for, and launchd kills a helper slow to exit, which would leave the
    /// Mac throttled.
    private static let timeout: TimeInterval = 5

    private let rules: ThrottleRules
    /// `closed` holds connections that have gone: XPC can deliver a request after the handler for
    /// its connection closing has run, and nothing would undo a throttle started then.
    private let state = Mutex<(owner: UUID?, token: String?, isClosing: Bool, closed: Set<UUID>)>((nil, nil, false, []))

    init(rules: ThrottleRules) {
        self.rules = rules
    }

    func set(_ settings: ThrottleSettings?, for owner: UUID) -> String? {
        state.withLock { state in
            // Shutting down: nothing may start after `releaseAll` cleared up, with no helper left
            // to undo it.
            if state.isClosing { return settings == nil ? nil : "The helper is stopping. Try again in a moment." }
            if state.closed.contains(owner) { return settings == nil ? nil : "The connection to the helper closed." }
            guard let settings else {
                // Only the owner can stop it, so a stale connection can't end another's throttle.
                guard state.owner == nil || state.owner == owner else { return nil }
                clear(&state)
                return nil
            }
            // Settings that can't be used change nothing, and stop only the asker's own throttle.
            if let problem = settings.problem {
                if state.owner == nil || state.owner == owner { clear(&state) }
                return problem
            }
            let interfaces = ThrottleRules.physicalInterfaces(Self.interfaceNames())
            if case .all = settings.target, interfaces.isEmpty {
                if state.owner == nil || state.owner == owner { clear(&state) }
                return "This Mac has no Ethernet or Wi‑Fi interface to throttle."
            }
            // From here, whatever happens, a failed request leaves nothing throttling, so the app
            // can tell that the throttle it showed has stopped.
            for arguments in rules.pipeArguments(settings) {
                if let error = Tool.check(Self.dnctl, arguments, timeout: Self.timeout) {
                    clear(&state)
                    return "Couldn't set up the throttle: \(error)"
                }
            }
            // launchd loads /etc/pf.conf at boot, which hooks com.apple's anchors into pf. If
            // something has replaced that ruleset since, the rules would load but never run.
            guard Tool.run(Self.pfctl, ["-s", "Anchors"], timeout: Self.timeout).output.contains("com.apple") else {
                clear(&state)
                return
                    "The packet filter isn't set up as macOS sets it up at startup, so throttling can't work. Restarting the Mac restores it."
            }
            if let error = Tool.check(
                Self.pfctl, ["-a", rules.anchor, "-f", "-"], input: rules.pfRules(settings, interfaces: interfaces), timeout: Self.timeout)
            {
                clear(&state)
                return "Couldn't load the throttle rules: \(error)"
            }
            if state.token == nil {
                let enabled = Tool.run(Self.pfctl, ["-E"], timeout: Self.timeout)
                guard let token = ThrottleRules.enableToken(fromPfctlOutput: enabled.output) else {
                    clear(&state)
                    return "Couldn't turn on the packet filter: \(enabled.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
                state.token = token
            }
            state.owner = owner
            return nil
        }
    }

    /// Stops the throttle if `owner` started it, as when its connection closes, and refuses
    /// anything `owner` asks for after.
    func release(_ owner: UUID) {
        state.withLock { state in
            state.closed.insert(owner)
            guard state.owner == owner else { return }
            clear(&state)
        }
    }

    /// Stops whatever is running and refuses new throttles from then on, for a helper about to exit.
    func releaseAll() {
        state.withLock { state in
            clear(&state)
            state.isClosing = true
        }
    }

    /// Every network interface's name, as en0 or utun3. An interface added later, such as a USB
    /// Ethernet adapter, is throttled from the next start.
    private static func interfaceNames() -> [String] {
        guard let first = if_nameindex() else { return [] }
        defer { if_freenameindex(first) }
        var names: [String] = []
        var entry = first
        while entry.pointee.if_index != 0, let name = entry.pointee.if_name {
            names.append(String(cString: name))
            entry += 1
        }
        return names
    }

    /// Removes rules and pipes left by a helper that crashed or a Mac that lost power. pf itself
    /// stays as it was, since the token that turned it on went with the old helper.
    func clearLeftovers() {
        _ = Tool.run(Self.pfctl, ["-a", rules.anchor, "-F", "all"], timeout: Self.timeout)
        _ = Tool.run(Self.dnctl, ["pipe", "delete", String(rules.downloadPipe), String(rules.uploadPipe)], timeout: Self.timeout)
    }

    private func clear(_ state: inout (owner: UUID?, token: String?, isClosing: Bool, closed: Set<UUID>)) {
        clearLeftovers()
        if let token = state.token { _ = Tool.run(Self.pfctl, ["-X", token], timeout: Self.timeout) }
        state.owner = nil
        state.token = nil
    }
}

/// Proxies pointing at this Mac that the app turned on. They end with the connection that set
/// them, as a throttle does: a debugging app's port stops answering once it quits, and a proxy
/// left pointing there would cut the whole Mac off from the web. Any other proxy is a setting,
/// and stays.
nonisolated final class ProxyLeases: Sendable {
    private struct Lease: Codable, Hashable, Sendable {
        let service: String
        let server: ProxyServer
    }

    /// Where the leases are kept, so a helper that crashed or was killed undoes them when it
    /// next starts, as it clears a throttle's leftovers. One file for each app's helper.
    private let file: URL?
    /// `closed` holds connections that have gone, whose late requests are refused.
    private let state = Mutex<(leases: [UUID: [Lease]], closed: Set<UUID>, isClosing: Bool)>(([:], [], false))

    init(appBundleID: String) {
        let safe = !appBundleID.isEmpty && !appBundleID.contains("/") && appBundleID != "." && appBundleID != ".."
        file = safe ? URL(filePath: "/Library/Application Support/\(appBundleID)/proxy-leases.json") : nil
    }

    func set(_ change: ProxyChange, service: String, for id: UUID) -> String? {
        let leases = change.servers.filter { $0.isOn && NetworkValidation.isLoopback($0.host) }.map {
            Lease(service: service, server: $0)
        }
        // Recorded and saved before the change is made, so a change that half fails, or a helper
        // killed partway, is still undone. Undoing one that never landed does nothing.
        let refused = state.withLock { state in
            if state.isClosing || state.closed.contains(id) { return true }
            // Each proxy this changes now points somewhere new, or is off: only where it points
            // now is this connection's to undo.
            var kept = state.leases[id] ?? []
            kept.removeAll { lease in lease.service == service && change.servers.contains { $0.kind == lease.server.kind } }
            state.leases[id] = kept + leases
            save(state.leases)
            return false
        }
        if refused { return "The connection to the helper closed." }
        // Not under the lock, so a slow networksetup doesn't hold up a connection closing or the
        // helper exiting.
        let error = NetworkSettings.setProxy(change, service: service)
        // The connection closed while this went through, so its release may have come before the
        // change landed: undone again now.
        let late = state.withLock { state in state.isClosing || state.closed.contains(id) }
        if late { leases.forEach(Self.undo) }
        return error
    }

    /// Turns off what `id` set, as when its connection closes, and refuses its requests after.
    func release(_ id: UUID) {
        state.withLock { state in
            state.closed.insert(id)
            guard let leases = state.leases.removeValue(forKey: id) else { return }
            leases.forEach(Self.undo)
            save(state.leases)
        }
    }

    /// Turns off everything set, and refuses new requests, for a helper about to exit.
    func releaseAll() {
        state.withLock { state in
            state.isClosing = true
            state.leases.values.joined().forEach(Self.undo)
            state.leases = [:]
            save(state.leases)
        }
    }

    /// Undoes what a helper that crashed, was killed or lost power had set. Nothing holds a
    /// lease yet: launchd starts the helper at boot, after a crash or for a new connection.
    func clearLeftovers() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let leases = (try? JSONDecoder().decode([Lease].self, from: data)) ?? []
        leases.filter { NetworkValidation.isServiceName($0.service) }.forEach(Self.undo)
        try? FileManager.default.removeItem(at: file)
    }

    private func save(_ leases: [UUID: [Lease]]) {
        guard let file else { return }
        let all = Array(leases.values.joined())
        guard !all.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
    }

    /// Turns the proxy off if it still points where it was set to, leaving one changed since,
    /// in System Settings or by the debugging app itself, as it is.
    private static func undo(_ lease: Lease) {
        let verb = lease.server.kind.verb
        let output = Tool.run(NetworkSettings.networksetup, ["-get\(verb)proxy", lease.service], timeout: 5)
        guard output.status == 0 else { return }
        let now = NetworkSetupOutput.proxy(output.output, kind: lease.server.kind)
        guard now.isOn, now.host == lease.server.host, now.port == lease.server.port else { return }
        _ = Tool.run(NetworkSettings.networksetup, ["-set\(verb)proxystate", lease.service, "off"], timeout: 5)
    }
}

/// DNS, resolver and proxy settings. Unlike a throttle these are settings, so they stay after
/// the app quits, apart from proxies pointing at this Mac, which `ProxyLeases` undoes.
nonisolated enum NetworkSettings {
    static let networksetup = "/usr/sbin/networksetup"

    /// Network services as networksetup lists them, without the asterisk on disabled ones.
    static func services() -> [String] {
        NetworkService.parse(list: Tool.run(networksetup, ["-listallnetworkservices"]).output).map(\.name)
    }

    private static func knownService(_ service: String) -> String? {
        guard NetworkValidation.isServiceName(service), services().contains(service) else {
            return "There's no network service called “\(service)”."
        }
        return nil
    }

    static func setDNSServers(_ servers: [String], service: String) -> String? {
        if let problem = knownService(service) { return problem }
        guard servers.count <= 8 else { return "That's too many DNS servers." }
        if let bad = servers.first(where: { !NetworkValidation.isAddress($0) }) { return "“\(bad)” isn't an IP address." }
        return Tool.check(networksetup, ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers))
            ?? flushDNSCache()
    }

    static func flushDNSCache() -> String? {
        _ = Tool.run("/usr/bin/dscacheutil", ["-flushcache"])
        // mDNSResponder always runs; failing to signal it means the cache wasn't cleared.
        return Tool.check("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    static func setResolver(_ resolver: ResolverFile) -> String? {
        guard NetworkValidation.isDomain(resolver.domain) else { return "“\(resolver.domain)” isn't a domain name." }
        let url = URL(filePath: resolver.path)
        let files = FileManager.default
        // Never touch a file someone else wrote, including one that can't be read as text.
        if files.fileExists(atPath: resolver.path) {
            let existing = try? String(contentsOf: url, encoding: .utf8)
            guard let existing, ResolverFile(domain: resolver.domain, text: existing).isManaged else {
                return "/etc/resolver/\(resolver.domain) wasn't made by \(ResolverFile.owner), so it's left as it is."
            }
        }
        if resolver.nameservers.isEmpty {
            guard files.fileExists(atPath: resolver.path) else { return nil }
            do {
                try files.removeItem(at: url)
            } catch {
                return error.localizedDescription
            }
            return flushDNSCache()
        }
        if let problem = resolver.problem { return problem }
        do {
            try files.createDirectory(
                atPath: ResolverFile.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try Data(resolver.text.utf8).write(to: url, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: resolver.path)
        } catch {
            return error.localizedDescription
        }
        return flushDNSCache()
    }

    static func setProxy(_ change: ProxyChange, service: String) -> String? {
        if let problem = knownService(service) ?? change.problem { return problem }
        for arguments in change.commands(service: service) {
            if let error = Tool.check(networksetup, arguments) { return error }
        }
        return nil
    }
}
