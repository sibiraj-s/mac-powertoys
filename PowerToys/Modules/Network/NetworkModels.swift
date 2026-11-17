import Foundation

// MARK: - Throttle profiles

/// A named set of speeds, delays and loss for each direction.
nonisolated struct ThrottleProfile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var download: ThrottleLink
    var upload: ThrottleLink
    var isBuiltIn = false

    /// "780 Kbps ↓ · 330 Kbps ↑ · 200 ms", for menus and hints.
    var summary: String {
        if download.packetLoss >= 1, upload.packetLoss >= 1 { return "Nothing gets through" }
        var parts: [String] = []
        if download.kilobitsPerSecond != nil || upload.kilobitsPerSecond != nil {
            parts.append("\(Self.rate(download.kilobitsPerSecond)) ↓")
            parts.append("\(Self.rate(upload.kilobitsPerSecond)) ↑")
        }
        let roundTrip = download.delayMilliseconds + upload.delayMilliseconds
        if roundTrip > 0 { parts.append("+\(roundTrip) ms") }
        let loss = max(download.packetLoss, upload.packetLoss)
        if loss > 0 { parts.append("\(Self.percent(loss)) loss") }
        return parts.isEmpty ? "No limits" : parts.joined(separator: " · ")
    }

    static func rate(_ kilobits: Int?) -> String {
        guard let kilobits else { return "Unlimited" }
        if kilobits >= 1_000, kilobits % 1_000 == 0 { return "\(kilobits / 1_000) Mbps" }
        if kilobits >= 1_000 { return String(format: "%.1f Mbps", Double(kilobits) / 1_000) }
        return "\(kilobits) Kbps"
    }

    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        return value == value.rounded() ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }

    /// Close to Apple's Network Link Conditioner profiles, so results compare with it.
    static let builtIn: [ThrottleProfile] = [
        preset("3g", "3G", down: 780, up: 330, delay: (100, 100)),
        preset("lte", "LTE", down: 50_000, up: 10_000, delay: (50, 65)),
        preset("edge", "Edge", down: 240, up: 200, delay: (400, 440)),
        preset("dsl", "DSL", down: 2_000, up: 256, delay: (5, 5)),
        preset("lossyWifi", "Lossy Wi‑Fi", down: 40_000, up: 33_000, delay: (1, 1), loss: 0.05),
        preset("veryBad", "Very bad network", down: 1_000, up: 1_000, delay: (500, 500), loss: 0.1),
        preset("highLatency", "High latency", down: nil, up: nil, delay: (300, 300)),
        preset("offline", "Offline", down: nil, up: nil, delay: (0, 0), loss: 1),
    ]

    private static func preset(
        _ id: String, _ name: String, down: Int?, up: Int?, delay: (Int, Int), loss: Double = 0
    ) -> ThrottleProfile {
        ThrottleProfile(
            id: id, name: name,
            download: ThrottleLink(kilobitsPerSecond: down, delayMilliseconds: delay.0, packetLoss: loss),
            upload: ThrottleLink(kilobitsPerSecond: up, delayMilliseconds: delay.1, packetLoss: loss),
            isBuiltIn: true)
    }
}

/// How a throttle picks its traffic, as chosen in settings.
nonisolated enum ThrottleScope: String, CaseIterable, Identifiable, Sendable {
    case all, dns, hosts, ports

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All traffic"
        case .dns: "DNS lookups"
        case .hosts: "Hosts"
        case .ports: "Ports"
        }
    }
}

/// How long a throttle lasts before it stops by itself.
nonisolated enum ThrottleDuration: Int, CaseIterable, Identifiable, Sendable {
    case untilStopped = 0
    case minutes5 = 300
    case minutes15 = 900
    case minutes30 = 1_800
    case hour1 = 3_600

    var id: Self { self }

    var title: String {
        switch self {
        case .untilStopped: "Until stopped"
        case .minutes5: "5 minutes"
        case .minutes15: "15 minutes"
        case .minutes30: "30 minutes"
        case .hour1: "1 hour"
        }
    }

    var interval: TimeInterval? { self == .untilStopped ? nil : TimeInterval(rawValue) }
}

/// Splits what someone typed into a list: commas, spaces and new lines all separate items.
nonisolated func listItems(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
}

// MARK: - DNS

nonisolated struct DNSPreset: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let servers: [String]

    /// The network's own DNS, from the router or VPN.
    static let automatic = DNSPreset(id: "automatic", name: "Automatic", servers: [])

    static let all: [DNSPreset] = [
        automatic,
        DNSPreset(id: "cloudflare", name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]),
        DNSPreset(id: "google", name: "Google", servers: ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]),
        DNSPreset(id: "quad9", name: "Quad9", servers: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]),
        DNSPreset(id: "adguard", name: "AdGuard", servers: ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"]),
        DNSPreset(id: "opendns", name: "OpenDNS", servers: ["208.67.222.222", "208.67.220.220"]),
    ]

    /// The preset with exactly these servers, in any order.
    static func matching(_ servers: [String]) -> DNSPreset? {
        all.first { Set($0.servers) == Set(servers) }
    }
}

// MARK: - Proxies

/// The proxies set on a network service.
nonisolated struct ProxyState: Hashable, Sendable {
    var servers: [ProxyKind: ProxyServer] = [:]
    var bypass: [String] = []

    var isAnyOn: Bool { servers.values.contains(where: \.isOn) }

    /// The ones with a host.
    var configured: [ProxyServer] { ProxyKind.allCases.compactMap { servers[$0] }.filter { !$0.host.isEmpty } }

    /// The ones a quick toggle can turn on: a host and a port that works, so one left half set
    /// doesn't stop the rest.
    var usable: [ProxyServer] { configured.filter { (1...65_535).contains($0.port) } }

    func server(_ kind: ProxyKind) -> ProxyServer {
        servers[kind] ?? ProxyServer(kind: kind, host: "", port: 0, isOn: false)
    }
}

extension ProxyKind {
    var title: String {
        switch self {
        case .web: "HTTP"
        case .secureWeb: "HTTPS"
        case .socks: "SOCKS"
        }
    }
}

/// Debugging proxies people point HTTP and HTTPS at.
nonisolated struct ProxyPreset: Identifiable, Hashable, Sendable {
    let name: String
    let port: Int

    var id: String { name }

    static let all = [
        ProxyPreset(name: "Proxyman", port: 9090),
        ProxyPreset(name: "Charles", port: 8888),
        ProxyPreset(name: "mitmproxy", port: 8080),
    ]
}

// MARK: - Resolvers on disk

nonisolated enum ResolverDirectory {
    /// Every file in /etc/resolver, sorted by domain.
    static func read(at directory: URL = URL(filePath: ResolverFile.directory)) -> [ResolverFile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard NetworkValidation.isDomain(url.lastPathComponent),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return ResolverFile(domain: url.lastPathComponent, text: text)
        }
        .sorted { $0.domain < $1.domain }
    }
}
