import Darwin
import Foundation

// What the app asks the helper to change on the network, and how the helper turns that into
// commands. Compiled into both, so the app can test exactly what runs as root.

// MARK: - Network services

/// A network service such as Wi‑Fi or a USB Ethernet adapter, as networksetup names it.
nonisolated struct NetworkService: Hashable, Identifiable, Sendable {
    let name: String
    let isEnabled: Bool

    var id: String { name }

    /// `networksetup -listallnetworkservices`: a note, then one service a line, disabled ones starred.
    static func parse(list output: String) -> [NetworkService] {
        output.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("An asterisk") }
            .map { line in
                line.hasPrefix("*")
                    ? NetworkService(name: String(line.dropFirst()), isEnabled: false)
                    : NetworkService(name: String(line), isEnabled: true)
            }
    }
}

// MARK: - Throttling

/// Which traffic a throttle slows down.
nonisolated enum ThrottleTarget: Codable, Hashable, Sendable {
    case all
    /// Name lookups only: DNS over port 53, not encrypted DNS.
    case dns
    /// Traffic to and from these addresses, IPv4 or IPv6, optionally with a prefix length.
    case hosts([String])
    /// TCP and UDP traffic to these remote ports.
    case ports([Int])
}

/// One direction of a throttle.
nonisolated struct ThrottleLink: Codable, Hashable, Sendable {
    /// nil for no limit.
    var kilobitsPerSecond: Int?
    var delayMilliseconds = 0
    /// 0 to 1.
    var packetLoss = 0.0

    init(kilobitsPerSecond: Int? = nil, delayMilliseconds: Int = 0, packetLoss: Double = 0) {
        self.kilobitsPerSecond = kilobitsPerSecond
        self.delayMilliseconds = delayMilliseconds
        self.packetLoss = packetLoss
    }

    var isValid: Bool {
        (kilobitsPerSecond.map { (1...10_000_000).contains($0) } ?? true)
            && (0...10_000).contains(delayMilliseconds)
            && (0...1).contains(packetLoss)
    }
}

/// Everything the helper needs to throttle the network.
nonisolated struct ThrottleSettings: Codable, Hashable, Sendable {
    var download: ThrottleLink
    var upload: ThrottleLink
    var target: ThrottleTarget
    /// Leaves 10.x, 192.168.x and other local addresses at full speed. Only applies to all traffic
    /// and ports, since a local router is often the DNS server.
    var excludesLocalNetwork: Bool

    init(download: ThrottleLink, upload: ThrottleLink, target: ThrottleTarget = .all, excludesLocalNetwork: Bool = false) {
        self.download = download
        self.upload = upload
        self.target = target
        self.excludesLocalNetwork = excludesLocalNetwork
    }

    /// Checked by the helper too, as it's what ends up in commands run as root.
    var problem: String? {
        guard download.isValid, upload.isValid else { return "The speed, delay or packet loss is out of range." }
        switch target {
        case .all, .dns: return nil
        case .hosts(let hosts):
            if hosts.isEmpty { return "Add at least one host to throttle." }
            if hosts.count > 256 { return "That's too many addresses to throttle." }
            if let bad = hosts.first(where: { !NetworkValidation.isAddressOrNetwork($0) }) { return "“\(bad)” isn't an IP address." }
            return nil
        case .ports(let ports):
            if ports.isEmpty { return "Add at least one port to throttle." }
            if ports.count > 64 || ports.contains(where: { !(1...65_535).contains($0) }) { return "Ports go from 1 to 65535." }
            return nil
        }
    }
}

/// The dummynet pipes and pf rules behind a throttle. The rules go in an anchor under
/// `com.apple/`, which macOS's own pf.conf already evaluates, so the main ruleset is never replaced.
nonisolated struct ThrottleRules: Sendable {
    let anchor: String
    let downloadPipe: Int
    var uploadPipe: Int { downloadPipe + 1 }

    init(anchor: String, downloadPipe: Int) {
        self.anchor = anchor
        self.downloadPipe = downloadPipe
    }

    /// The Debug and installed apps each have a helper, which clears its own anchor and pipes when
    /// it starts, so each app gets its own, or one would stop the other's throttle.
    init(appBundleID: String) {
        // FNV-1a, which unlike `hashValue` is the same in every process.
        let hash = appBundleID.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        // Pipe numbers well away from the ones people pick by hand.
        self.init(anchor: "com.apple/\(appBundleID).throttle", downloadPipe: 61_001 + Int(hash % 900) * 2)
    }

    /// Private, link-local and unique local ranges.
    static let localNetworks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10"]

    /// `dnctl` arguments that set up each pipe.
    func pipeArguments(_ settings: ThrottleSettings) -> [[String]] {
        [Self.pipe(downloadPipe, settings.download), Self.pipe(uploadPipe, settings.upload)]
    }

    private static func pipe(_ number: Int, _ link: ThrottleLink) -> [String] {
        var arguments = ["pipe", String(number), "config"]
        if let rate = link.kilobitsPerSecond { arguments += ["bw", "\(rate)Kbit/s"] }
        arguments += ["delay", String(link.delayMilliseconds)]
        if link.packetLoss > 0 { arguments += ["plr", String(format: "%.4f", link.packetLoss)] }
        return arguments
    }

    /// The interfaces a throttle on all traffic goes on: Ethernet, Wi‑Fi and the like, which
    /// macOS names en0, en1 and so on. Not VPN tunnels, whose traffic also leaves through one of
    /// these and would go through the pipes twice.
    static func physicalInterfaces(_ names: [String]) -> [String] {
        Set(names.filter { $0.count > 2 && $0.hasPrefix("en") && $0.dropFirst(2).allSatisfy(\.isNumber) }).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count < $1.count
        }
    }

    /// The anchor's rules. Outgoing traffic goes through the upload pipe and incoming through the
    /// download pipe; loopback is never throttled. Every rule is `quick`: macOS's pf forgets a
    /// dummynet match on its way out of an anchor under `com.apple/*`, so only a rule that ends
    /// the search there throttles anything.
    ///
    /// All traffic is throttled on `interfaces`, so a VPN's is slowed once, on its way out, and
    /// not again inside the tunnel. DNS, hosts and ports match on any interface but loopback:
    /// a VPN's own packets go to its server, not to them, so traffic inside a tunnel is slowed
    /// once there instead.
    func pfRules(_ settings: ThrottleSettings, interfaces: [String]) -> String {
        let up = "pipe \(uploadPipe)"
        let down = "pipe \(downloadPipe)"
        let physical = interfaces.count == 1 ? interfaces[0] : "{ \(interfaces.joined(separator: ", ")) }"
        var lines: [String] = []
        // DNS and hosts never leave the local network out, so they don't get the table.
        let local: Bool
        switch settings.target {
        case .all, .ports: local = settings.excludesLocalNetwork
        case .dns, .hosts: local = false
        }
        if local { lines.append("table <powertoys_local> const { \(Self.localNetworks.joined(separator: ", ")) }") }
        switch settings.target {
        case .all:
            if local {
                lines.append("dummynet out quick on \(physical) from any to ! <powertoys_local> \(up)")
                lines.append("dummynet in quick on \(physical) from ! <powertoys_local> to any \(down)")
            } else {
                lines.append("dummynet out quick on \(physical) all \(up)")
                lines.append("dummynet in quick on \(physical) all \(down)")
            }
        case .dns:
            lines.append("dummynet out quick on ! lo0 proto { tcp, udp } from any to any port 53 \(up)")
            lines.append("dummynet in quick on ! lo0 proto { tcp, udp } from any port 53 to any \(down)")
        case .hosts(let hosts):
            lines.append("table <powertoys_hosts> const { \(hosts.joined(separator: ", ")) }")
            lines.append("dummynet out quick on ! lo0 from any to <powertoys_hosts> \(up)")
            lines.append("dummynet in quick on ! lo0 from <powertoys_hosts> to any \(down)")
        case .ports(let ports):
            let list = "{ \(ports.map(String.init).joined(separator: ", ")) }"
            let remote = local ? "! <powertoys_local>" : "any"
            lines.append("dummynet out quick on ! lo0 proto { tcp, udp } from any to \(remote) port \(list) \(up)")
            lines.append("dummynet in quick on ! lo0 proto { tcp, udp } from \(remote) port \(list) to any \(down)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The token `pfctl -E` prints, to hand back with `pfctl -X` so pf goes back to how it was.
    static func enableToken(fromPfctlOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("Token") {
            let token = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
            if !token.isEmpty, token.allSatisfy(\.isNumber) { return token }
        }
        return nil
    }
}

// MARK: - Proxies

nonisolated enum ProxyKind: String, Codable, CaseIterable, Hashable, Sendable {
    case web, secureWeb, socks

    /// The part of networksetup's verbs that names this proxy, as in `-setwebproxy`.
    var verb: String {
        switch self {
        case .web: "web"
        case .secureWeb: "secureweb"
        case .socks: "socksfirewall"
        }
    }
}

nonisolated struct ProxyServer: Codable, Hashable, Sendable {
    var kind: ProxyKind
    var host: String
    var port: Int
    var isOn: Bool
}

/// Proxies to set on one network service, with the hosts that skip them.
nonisolated struct ProxyChange: Codable, Hashable, Sendable {
    var servers: [ProxyServer]
    /// nil leaves the list as it is.
    var bypass: [String]?

    var problem: String? {
        for server in servers where server.isOn {
            if server.host.isEmpty || server.port == 0 { return "Enter the proxy's host and port first." }
            guard NetworkValidation.isHost(server.host) else { return "“\(server.host)” isn't a host name or IP address." }
            guard (1...65_535).contains(server.port) else { return "Ports go from 1 to 65535." }
        }
        if let bad = bypass?.first(where: { !NetworkValidation.isBypassEntry($0) }) { return "“\(bad)” can't go in the bypass list." }
        return nil
    }

    /// `networksetup` argument lists that make the change on `service`.
    func commands(service: String) -> [[String]] {
        var commands: [[String]] = []
        for server in servers {
            if server.isOn {
                commands.append(["-set\(server.kind.verb)proxy", service, server.host, String(server.port)])
                commands.append(["-set\(server.kind.verb)proxystate", service, "on"])
            } else {
                commands.append(["-set\(server.kind.verb)proxystate", service, "off"])
            }
        }
        if let bypass {
            commands.append(["-setproxybypassdomains", service] + (bypass.isEmpty ? ["Empty"] : bypass))
        }
        return commands
    }
}

// MARK: - Parsing networksetup

nonisolated enum NetworkSetupOutput {
    /// `-getdnsservers`: one address a line, or a sentence when the network's own are used.
    static func dnsServers(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter(NetworkValidation.isAddress)
    }

    /// `-getwebproxy` and the like: "Enabled: Yes", "Server: host", "Port: 8080".
    static func proxy(_ output: String, kind: ProxyKind) -> ProxyServer {
        var server = ProxyServer(kind: kind, host: "", port: 0, isOn: false)
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon]
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Enabled": server.isOn = value == "Yes"
            case "Server": server.host = value
            case "Port": server.port = Int(value) ?? 0
            default: break
            }
        }
        return server
    }

    /// `-getproxybypassdomains`: one entry a line, or a sentence when there are none.
    static func bypass(_ output: String) -> [String] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        return lines.contains { $0.hasPrefix("There aren't any") } ? [] : lines.filter(NetworkValidation.isBypassEntry)
    }
}

// MARK: - Resolvers

/// A file in /etc/resolver, which sends lookups for one domain to other name servers.
nonisolated struct ResolverFile: Hashable, Sendable {
    static let directory = "/etc/resolver"
    /// Who the marker names, also used when the helper refuses to touch another's file.
    static let owner = "PowerToys"
    static let marker = "# Managed by \(owner)"

    var domain: String
    var nameservers: [String]
    var port: Int?
    /// Written by the app, so it may change or remove it; others are only shown.
    var isManaged = true

    var path: String { Self.directory + "/" + domain }

    var problem: String? {
        guard NetworkValidation.isDomain(domain) else { return "“\(domain)” isn't a domain name." }
        guard !nameservers.isEmpty else { return "Add at least one name server." }
        guard nameservers.count <= 8 else { return "That's too many name servers." }
        if let bad = nameservers.first(where: { !NetworkValidation.isAddress($0) }) { return "“\(bad)” isn't an IP address." }
        if let port, !(1...65_535).contains(port) { return "Ports go from 1 to 65535." }
        return nil
    }

    var text: String {
        var lines = [Self.marker]
        lines += nameservers.map { "nameserver \($0)" }
        if let port { lines.append("port \(port)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a resolver file; a file without the app's marker comes back unmanaged.
    init(domain: String, text: String) {
        var nameservers: [String] = []
        var port: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, !parts[0].hasPrefix("#") else { continue }
            switch parts[0] {
            case "nameserver": nameservers.append(String(parts[1]))
            case "port": port = Int(parts[1])
            default: break
            }
        }
        self.domain = domain
        self.nameservers = nameservers
        self.port = port
        isManaged = text.hasPrefix(Self.marker)
    }

    init(domain: String, nameservers: [String], port: Int? = nil) {
        self.domain = domain
        self.nameservers = nameservers
        self.port = port
    }
}

// MARK: - Validation

/// Checks on anything that ends up in a command or file written as root.
nonisolated enum NetworkValidation {
    static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }

    static func isIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, text, &address) == 1
    }

    static func isAddress(_ text: String) -> Bool { isIPv4(text) || isIPv6(text) }

    /// An address, or a network such as 10.0.0.0/8.
    static func isAddressOrNetwork(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        let address = String(parts[0])
        guard parts.count == 2 else { return isAddress(address) }
        guard let prefix = Int(parts[1]) else { return false }
        if isIPv4(address) { return (0...32).contains(prefix) }
        if isIPv6(address) { return (0...128).contains(prefix) }
        return false
    }

    /// A domain such as `test` or `dev.example.com`: letters, digits and hyphens, in labels of up to 63.
    static func isDomain(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 253 else { return false }
        return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func isHost(_ text: String) -> Bool { isAddress(text) || isDomain(text) }

    /// This Mac itself, however a proxy on it is written: localhost, 127.x, ::1 in any of its
    /// spellings, or 127.x mapped into IPv6.
    static func isLoopback(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, name, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        let isOne = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
        let isMapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF && bytes[12] == 127
        return isOne || isMapped
    }

    /// What macOS takes in a proxy bypass list: hosts, wildcards such as `*.local`, and networks
    /// such as `169.254/16`.
    static func isBypassEntry(_ text: String) -> Bool {
        // A leading dash would read as one of networksetup's options.
        guard !text.isEmpty, text.count <= 253, text != "Empty", !text.hasPrefix("-") else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-*/:_<>".contains($0)) }
    }

    /// A network service name as networksetup lists it, without the asterisk for a disabled one.
    static func isServiceName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 128 && !text.hasPrefix("-") && !text.contains(where: \.isNewline)
    }
}
