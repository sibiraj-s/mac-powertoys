import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// The network as it is now. None of it needs root.
nonisolated struct NetworkSnapshot: Hashable, Sendable {
    var serviceName: String?
    var interface: String?
    var ipv4: [String] = []
    var ipv6: [String] = []
    var router: String?
    /// The DNS servers in use, from the network or set by hand.
    var dnsServers: [String] = []
    /// Tunnel interfaces with an address, such as a VPN's.
    var tunnels: [String] = []
    var wifi: WiFiDetails?
}

nonisolated struct WiFiDetails: Hashable, Sendable {
    /// nil without Location access, which macOS asks for before showing it.
    var networkName: String?
    var rssi: Int
    var noise: Int
    var transmitRate: Double
    var channel: Int?
    var band: String?

    /// How good the signal is, from its strength over the noise.
    var quality: String {
        switch rssi {
        case (-55)...: "Excellent"
        case (-67)..<(-55): "Good"
        case (-75)..<(-67): "Fair"
        default: "Weak"
        }
    }
}

nonisolated struct PublicAddress: Hashable, Sendable {
    let address: String
    let country: String?

    /// Cloudflare's trace page: one "key=value" a line.
    static func parse(trace: String) -> PublicAddress? {
        var values: [String: String] = [:]
        for line in trace.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let ip = values["ip"], NetworkValidation.isAddress(ip) else { return nil }
        return PublicAddress(address: ip, country: values["loc"])
    }
}

nonisolated struct SpeedTestResult: Hashable, Sendable, Decodable {
    /// Bits a second.
    let download: Double
    let upload: Double
    /// Round trips a minute under load; higher is better.
    let responsiveness: Double?
    /// Milliseconds with nothing else going on.
    let idleLatency: Double?
    let interface: String?

    enum CodingKeys: String, CodingKey {
        case download = "dl_throughput"
        case upload = "ul_throughput"
        case responsiveness
        case idleLatency = "base_rtt"
        case interface = "interface_name"
    }

    static func parse(_ json: String) throws -> SpeedTestResult {
        try JSONDecoder().decode(SpeedTestResult.self, from: Data(json.utf8))
    }

    static func megabits(_ bitsPerSecond: Double) -> String {
        let value = bitsPerSecond / 1_000_000
        return value >= 100 ? "\(Int(value.rounded())) Mbps" : String(format: "%.1f Mbps", value)
    }

    var responsivenessRating: String? {
        guard let responsiveness else { return nil }
        switch responsiveness {
        case 1_000...: return "High"
        case 300..<1_000: return "Medium"
        default: return "Low"
        }
    }
}

/// Bytes a process has sent and received since it started, from one `nettop` sample.
nonisolated struct ProcessTraffic: Hashable, Sendable {
    let pid: pid_t
    let name: String
    let bytesIn: UInt64
    let bytesOut: UInt64

    /// `nettop -P -L 1 -x -J bytes_in,bytes_out`: a header, then "name.pid,in,out," a line.
    static func parse(nettop output: String) -> [ProcessTraffic] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let bytesIn = UInt64(fields[1]), let bytesOut = UInt64(fields[2]) else { return nil }
            let label = fields[0]
            guard let dot = label.lastIndex(of: "."), let pid = pid_t(label[label.index(after: dot)...]) else { return nil }
            return ProcessTraffic(pid: pid, name: String(label[..<dot]), bytesIn: bytesIn, bytesOut: bytesOut)
        }
    }
}

/// Reads network settings and state; a protocol so tests use canned answers.
protocol NetworkReading: Sendable {
    func services() async throws -> [NetworkService]
    /// The servers set by hand on `service`; empty when it uses the network's own.
    func dnsServers(service: String) async throws -> [String]
    func proxies(service: String) async throws -> ProxyState
    func resolvers() async -> [ResolverFile]
    func snapshot() async -> NetworkSnapshot
    /// The name of the service macOS is using now, without the rest of the snapshot.
    func primaryService() async -> String?
    func publicAddress() async throws -> PublicAddress
    func speedTest() async throws -> SpeedTestResult
    func traffic() async throws -> [ProcessTraffic]
    /// The addresses a host name has now, or the address itself.
    func addresses(of host: String) async -> [String]
}

nonisolated struct LiveNetworkReader: NetworkReading {
    private static let networksetup = "/usr/sbin/networksetup"

    private func networksetup(_ arguments: [String]) async throws -> String {
        let output = try await Command.run(Self.networksetup, arguments, timeout: .seconds(10))
        guard output.status == 0 else {
            throw CommandError(errorDescription: output.stdout.isEmpty ? output.stderr : output.stdout)
        }
        return output.stdout
    }

    func services() async throws -> [NetworkService] {
        NetworkService.parse(list: try await networksetup(["-listallnetworkservices"]))
    }

    func dnsServers(service: String) async throws -> [String] {
        NetworkSetupOutput.dnsServers(try await networksetup(["-getdnsservers", service]))
    }

    /// Asks for each proxy and the bypass list at the same time.
    func proxies(service: String) async throws -> ProxyState {
        async let web = networksetup(["-getwebproxy", service])
        async let secureWeb = networksetup(["-getsecurewebproxy", service])
        async let socks = networksetup(["-getsocksfirewallproxy", service])
        async let bypass = networksetup(["-getproxybypassdomains", service])
        var state = ProxyState()
        state.servers[.web] = NetworkSetupOutput.proxy(try await web, kind: .web)
        state.servers[.secureWeb] = NetworkSetupOutput.proxy(try await secureWeb, kind: .secureWeb)
        state.servers[.socks] = NetworkSetupOutput.proxy(try await socks, kind: .socks)
        state.bypass = NetworkSetupOutput.bypass(try await bypass)
        return state
    }

    @concurrent
    func resolvers() async -> [ResolverFile] {
        ResolverDirectory.read()
    }

    @concurrent
    func primaryService() async -> String? {
        guard let store = SCDynamicStoreCreate(nil, "PowerToys" as CFString, nil, nil) else { return nil }
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return Self.serviceName(store: store, global: global)
    }

    /// The name of the service the global IPv4 state says macOS is using.
    private static func serviceName(store: SCDynamicStore, global: [String: Any]?) -> String? {
        guard let serviceID = global?["PrimaryService"] as? String else { return nil }
        let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(serviceID)" as CFString) as? [String: Any]
        return setup?["UserDefinedName"] as? String
    }

    @concurrent
    func snapshot() async -> NetworkSnapshot {
        var snapshot = NetworkSnapshot()
        let store = SCDynamicStoreCreate(nil, "PowerToys" as CFString, nil, nil)
        if let store {
            let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
            snapshot.interface = global?["PrimaryInterface"] as? String
            snapshot.router = global?["Router"] as? String
            snapshot.serviceName = Self.serviceName(store: store, global: global)
            let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
            snapshot.dnsServers = dns?["ServerAddresses"] as? [String] ?? []
        }
        let addresses = Self.interfaceAddresses()
        if let interface = snapshot.interface {
            snapshot.ipv4 = addresses.filter { $0.interface == interface && $0.family == AF_INET }.map(\.address)
            snapshot.ipv6 = addresses.filter { $0.interface == interface && $0.family == AF_INET6 && !$0.address.hasPrefix("fe80") }
                .map(\.address)
        }
        snapshot.tunnels = Array(
            Set(
                addresses.filter { address in
                    address.family == AF_INET && ["utun", "ipsec", "ppp"].contains { address.interface.hasPrefix($0) }
                }.map(\.interface))
        ).sorted()
        if let wifi = CWWiFiClient.shared().interface(), wifi.powerOn() {
            snapshot.wifi = WiFiDetails(
                networkName: wifi.ssid(), rssi: wifi.rssiValue(), noise: wifi.noiseMeasurement(),
                transmitRate: wifi.transmitRate(), channel: wifi.wlanChannel()?.channelNumber,
                band: wifi.wlanChannel().flatMap { Self.bandName($0.channelBand) })
        }
        return snapshot
    }

    private static func bandName(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
    }

    private struct InterfaceAddress {
        let interface: String
        let family: Int32
        let address: String
    }

    /// An address as text, without the %en0 that ends a scoped IPv6 one.
    private static func numericHost(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(nulTerminated: host).split(separator: "%").first.map(String.init) ?? ""
    }

    private static func interfaceAddresses() -> [InterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var result: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard let text = numericHost(address, length: length) else { continue }
            result.append(InterfaceAddress(interface: String(cString: pointer.pointee.ifa_name), family: family, address: text))
        }
        return result
    }

    func publicAddress() async throws -> PublicAddress {
        var request = URLRequest(url: URL(string: "https://1.1.1.1/cdn-cgi/trace")!)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let address = PublicAddress.parse(trace: String(decoding: data, as: UTF8.self)) else {
            throw CommandError(errorDescription: "The answer didn't include an address.")
        }
        return address
    }

    func speedTest() async throws -> SpeedTestResult {
        let output = try await Command.run("/usr/bin/networkQuality", ["-c", "-M", "20"], timeout: .seconds(60))
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError(errorDescription: message.isEmpty ? "The speed test didn't finish." : message)
        }
        return try SpeedTestResult.parse(output.stdout)
    }

    func traffic() async throws -> [ProcessTraffic] {
        let output = try await Command.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"], timeout: .seconds(10))
        return ProcessTraffic.parse(nettop: output.stdout)
    }

    @concurrent
    func addresses(of host: String) async -> [String] {
        if NetworkValidation.isAddressOrNetwork(host) { return [host] }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let first else { return [] }
        defer { freeaddrinfo(first) }
        var result: [String] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = info.pointee.ai_addr else { continue }
            guard let value = Self.numericHost(address, length: info.pointee.ai_addrlen) else { continue }
            if !result.contains(value) { result.append(value) }
        }
        return result
    }
}
