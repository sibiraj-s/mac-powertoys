import Foundation
import Synchronization
import Testing

@testable import PowerToys

// MARK: - Fakes

/// Records what the Network module asks of the helper, without one.
final class FakeNetworkHelper: NetworkPrivileges {
    var onInterrupted: (() -> Void)?
    var isAllowed = false
    var needsApproval = false
    /// What every request fails with, when set.
    var failure: String?
    /// Holds throttle requests until opened, like a helper that's slow to answer.
    var replies: Gate?
    private(set) var throttles: [ThrottleSettings?] = []
    private(set) var dnsChanges: [(servers: [String], service: String)] = []
    private(set) var resolvers: [ResolverFile] = []
    private(set) var proxyChanges: [(change: ProxyChange, service: String)] = []
    private(set) var flushes = 0
    private(set) var allowed = 0
    private(set) var disallowed = 0
    private(set) var disconnected = 0

    func allow() throws {
        if needsApproval { throw HelperNeedsApproval(use: .network) }
        isAllowed = true
        allowed += 1
    }

    func disallow() {
        disallowed += 1
    }

    func disconnect() {
        disconnected += 1
    }

    /// Reports the helper as gone as the next request goes out, as the real connection does.
    var goesAway = false

    private func check() throws {
        if goesAway {
            goesAway = false
            onInterrupted?()
        }
        if let failure { throw CommandError(errorDescription: failure) }
    }

    func setThrottle(_ settings: ThrottleSettings?) async throws {
        await replies?.wait()
        try check()
        throttles.append(settings)
    }

    func setDNSServers(_ servers: [String], service: String) async throws {
        try check()
        dnsChanges.append((servers, service))
    }

    func flushDNSCache() async throws {
        try check()
        flushes += 1
    }

    func setResolver(_ resolver: ResolverFile) async throws {
        try check()
        resolvers.append(resolver)
    }

    func setProxy(_ change: ProxyChange, service: String) async throws {
        try check()
        proxyChanges.append((change, service))
    }
}

/// Canned network state, which tests change through `state`.
nonisolated final class FakeNetworkReader: NetworkReading, Sendable {
    struct State {
        var services = [NetworkService(name: "Wi-Fi", isEnabled: true), NetworkService(name: "Thunderbolt Bridge", isEnabled: false)]
        var dns: [String: [String]] = [:]
        var proxies: [String: ProxyState] = [:]
        var resolvers: [ResolverFile] = []
        var snapshot = NetworkSnapshot(serviceName: "Wi-Fi", interface: "en0", ipv4: ["192.168.1.20"], router: "192.168.1.1")
        var traffic: [ProcessTraffic] = []
        var addresses: [String: [String]] = [:]
        /// Makes reading DNS servers fail, as when networksetup times out.
        var dnsFails = false
    }

    let state = Mutex(State())

    func services() async throws -> [NetworkService] { state.withLock { $0.services } }
    func dnsServers(service: String) async throws -> [String] {
        let (servers, fails) = state.withLock { ($0.dns[service] ?? [], $0.dnsFails) }
        if fails { throw CommandError(errorDescription: "networksetup timed out") }
        return servers
    }
    func proxies(service: String) async throws -> ProxyState { state.withLock { $0.proxies[service] ?? ProxyState() } }
    func resolvers() async -> [ResolverFile] { state.withLock { $0.resolvers } }
    func snapshot() async -> NetworkSnapshot { state.withLock { $0.snapshot } }
    func primaryService() async -> String? { state.withLock { $0.snapshot.serviceName } }
    func publicAddress() async throws -> PublicAddress { PublicAddress(address: "203.0.113.7", country: "SG") }
    func speedTest() async throws -> SpeedTestResult { try SpeedTestResult.parse(#"{"dl_throughput": 1, "ul_throughput": 1}"#) }
    func traffic() async throws -> [ProcessTraffic] { state.withLock { $0.traffic } }

    func addresses(of host: String) async -> [String] {
        if NetworkValidation.isAddressOrNetwork(host) { return [host] }
        return state.withLock { $0.addresses[host] ?? [] }
    }
}

// MARK: - Rules the helper runs

struct ThrottleRulesTests {
    private let threeG = ThrottleProfile.builtIn.first { $0.id == "3g" }!
    private let rules = ThrottleRules(anchor: "com.apple/test.throttle", downloadPipe: 61_001)

    /// The Debug and installed apps' helpers mustn't clear each other's throttle.
    @Test func eachAppGetsItsOwnAnchorAndPipes() {
        let installed = ThrottleRules(appBundleID: "dev.sibiraj.powertoys")
        let debug = ThrottleRules(appBundleID: "dev.sibiraj.powertoys.debug")
        #expect(installed.anchor == "com.apple/dev.sibiraj.powertoys.throttle")
        #expect(installed.anchor != debug.anchor)
        #expect(installed.downloadPipe != debug.downloadPipe)
        #expect(ThrottleRules(appBundleID: "dev.sibiraj.powertoys").downloadPipe == installed.downloadPipe)
        #expect((61_001...62_800).contains(installed.downloadPipe))
    }

    @Test func pipesCarryRateDelayAndLoss() {
        let settings = ThrottleSettings(
            download: ThrottleLink(kilobitsPerSecond: 780, delayMilliseconds: 100),
            upload: ThrottleLink(kilobitsPerSecond: nil, delayMilliseconds: 0, packetLoss: 0.05))
        #expect(
            rules.pipeArguments(settings) == [
                ["pipe", "61001", "config", "bw", "780Kbit/s", "delay", "100"],
                ["pipe", "61002", "config", "delay", "0", "plr", "0.0500"],
            ])
    }

    /// Not on VPN tunnels too, which would slow their traffic twice.
    @Test func allTrafficGoesOnThePhysicalInterfaces() {
        let settings = ThrottleSettings(download: threeG.download, upload: threeG.upload)
        #expect(
            rules.pfRules(settings, interfaces: ["en0"])
                == "dummynet out quick on en0 all pipe 61002\ndummynet in quick on en0 all pipe 61001\n")
        #expect(rules.pfRules(settings, interfaces: ["en0", "en5"]).contains("dummynet out quick on { en0, en5 } all pipe 61002"))
    }

    @Test func physicalInterfacesAreTheEnOnes() {
        let names = ["lo0", "gif0", "stf0", "en0", "en10", "en2", "utun3", "awdl0", "bridge0", "en", "enx1", "en0"]
        #expect(ThrottleRules.physicalInterfaces(names) == ["en0", "en2", "en10"])
    }

    /// Their own filters keep a VPN's packets out, so they catch traffic inside a tunnel.
    @Test func hostsPortsAndDNSMatchAnyInterfaceButLoopback() {
        let settings = ThrottleSettings(download: threeG.download, upload: threeG.upload, target: .ports([443]))
        #expect(rules.pfRules(settings, interfaces: ["en0"]).contains("dummynet out quick on ! lo0 proto { tcp, udp }"))
    }

    @Test func localNetworkCanBeLeftAlone() {
        let rules = self.rules.pfRules(
            ThrottleSettings(download: threeG.download, upload: threeG.upload, excludesLocalNetwork: true), interfaces: ["en0"])
        #expect(rules.hasPrefix("table <powertoys_local> const { 10.0.0.0/8, "))
        #expect(rules.contains("dummynet out quick on en0 from any to ! <powertoys_local> pipe 61002"))
        #expect(rules.contains("dummynet in quick on en0 from ! <powertoys_local> to any pipe 61001"))
    }

    @Test func dnsOnlyMatchesPort53AndIgnoresLocalExclusion() {
        let rules = self.rules.pfRules(
            ThrottleSettings(download: threeG.download, upload: threeG.upload, target: .dns, excludesLocalNetwork: true),
            interfaces: ["en0"])
        #expect(!rules.contains("powertoys_local"))
        #expect(rules.contains("proto { tcp, udp } from any to any port 53 pipe 61002"))
        #expect(rules.contains("proto { tcp, udp } from any port 53 to any pipe 61001"))
    }

    @Test func hostsGoInATable() {
        let rules = self.rules.pfRules(
            ThrottleSettings(download: threeG.download, upload: threeG.upload, target: .hosts(["203.0.113.7", "2001:db8::1"])),
            interfaces: ["en0"])
        #expect(rules.contains("table <powertoys_hosts> const { 203.0.113.7, 2001:db8::1 }"))
        #expect(rules.contains("from any to <powertoys_hosts> pipe 61002"))
    }

    @Test func portsMatchRemotePorts() {
        let rules = self.rules.pfRules(
            ThrottleSettings(download: threeG.download, upload: threeG.upload, target: .ports([443, 8080])),
            interfaces: ["en0"])
        #expect(rules.contains("from any to any port { 443, 8080 } pipe 61002"))
        #expect(rules.contains("from any port { 443, 8080 } to any pipe 61001"))
    }

    @Test func readsTheEnableToken() {
        #expect(ThrottleRules.enableToken(fromPfctlOutput: "No ALTQ support in kernel\npf enabled\nToken : 1234567890\n") == "1234567890")
        #expect(ThrottleRules.enableToken(fromPfctlOutput: "pfctl: Operation not permitted") == nil)
    }

    @Test func settingsCatchBadInput() {
        let link = ThrottleLink()
        #expect(ThrottleSettings(download: link, upload: link).problem == nil)
        #expect(ThrottleSettings(download: link, upload: link, target: .hosts([])).problem != nil)
        #expect(ThrottleSettings(download: link, upload: link, target: .hosts(["example.com"])).problem != nil)
        #expect(ThrottleSettings(download: link, upload: link, target: .hosts(["10.0.0.0/8"])).problem == nil)
        #expect(ThrottleSettings(download: link, upload: link, target: .ports([0])).problem != nil)
        #expect(ThrottleSettings(download: ThrottleLink(packetLoss: 1.5), upload: link).problem != nil)
        #expect(ThrottleSettings(download: ThrottleLink(delayMilliseconds: 20_000), upload: link).problem != nil)
    }
}

struct ProxyChangeTests {
    @Test func turningOnSetsHostThenState() {
        let change = ProxyChange(servers: [ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: true)], bypass: nil)
        #expect(
            change.commands(service: "Wi-Fi") == [
                ["-setwebproxy", "Wi-Fi", "127.0.0.1", "9090"],
                ["-setwebproxystate", "Wi-Fi", "on"],
            ])
    }

    @Test func turningOffOnlyChangesState() {
        let change = ProxyChange(servers: [ProxyServer(kind: .socks, host: "", port: 0, isOn: false)], bypass: [])
        #expect(
            change.commands(service: "Wi-Fi") == [
                ["-setsocksfirewallproxystate", "Wi-Fi", "off"],
                ["-setproxybypassdomains", "Wi-Fi", "Empty"],
            ])
    }

    @Test func rejectsBadHostsPortsAndBypassEntries() {
        #expect(ProxyChange(servers: [ProxyServer(kind: .web, host: "bad host", port: 80, isOn: true)]).problem != nil)
        #expect(ProxyChange(servers: [ProxyServer(kind: .web, host: "proxy.local", port: 70_000, isOn: true)]).problem != nil)
        #expect(ProxyChange(servers: [], bypass: ["; rm -rf"]).problem != nil)
        // It would read as one of networksetup's options.
        #expect(ProxyChange(servers: [], bypass: ["-setdnsservers"]).problem != nil)
        let empty = ProxyChange(servers: [ProxyServer(kind: .web, host: "", port: 0, isOn: true)])
        #expect(empty.problem == "Enter the proxy's host and port first.")
        #expect(ProxyChange(servers: [], bypass: ["*.local", "169.254/16"]).problem == nil)
    }
}

struct ResolverFileTests {
    @Test func writesMarkerNameserversAndPort() {
        let file = ResolverFile(domain: "test", nameservers: ["127.0.0.1"], port: 5353)
        #expect(file.text == "# Managed by PowerToys\nnameserver 127.0.0.1\nport 5353\n")
        #expect(file.path == "/etc/resolver/test")
    }

    @Test func readsBackWhatItWrote() {
        let file = ResolverFile(domain: "internal.corp", nameservers: ["10.0.0.2", "10.0.0.3"])
        #expect(ResolverFile(domain: "internal.corp", text: file.text) == file)
    }

    @Test func filesWithoutTheMarkerAreLeftAlone() {
        let other = ResolverFile(domain: "ts.net", text: "nameserver 100.100.100.100\n")
        #expect(!other.isManaged)
        #expect(other.nameservers == ["100.100.100.100"])
    }

    @Test func catchesBadInput() {
        #expect(ResolverFile(domain: "../etc", nameservers: ["127.0.0.1"]).problem != nil)
        #expect(ResolverFile(domain: "test", nameservers: []).problem != nil)
        #expect(ResolverFile(domain: "test", nameservers: ["localhost"]).problem != nil)
        #expect(ResolverFile(domain: "test", nameservers: ["127.0.0.1"], port: 0).problem != nil)
        #expect(ResolverFile(domain: "dev.test", nameservers: ["::1"], port: 53).problem == nil)
    }

    @Test func readsTheResolverDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ResolverFile(domain: "test", nameservers: ["127.0.0.1"]).text.write(
            to: directory.appending(path: "test"), atomically: true, encoding: .utf8)
        try "nameserver 10.0.0.1\n".write(to: directory.appending(path: "corp"), atomically: true, encoding: .utf8)
        // Not resolvers: Finder's and editors' leftovers.
        try "".write(to: directory.appending(path: ".DS_Store"), atomically: true, encoding: .utf8)
        try "nameserver 10.0.0.9\n".write(to: directory.appending(path: "corp~"), atomically: true, encoding: .utf8)
        let files = ResolverDirectory.read(at: directory)
        #expect(files.map(\.domain) == ["corp", "test"])
        #expect(files.map(\.isManaged) == [false, true])
    }
}

struct NetworkValidationTests {
    /// Proxies pointing here end when the app does.
    @Test func loopbackHosts() {
        for host in ["127.0.0.1", "127.0.0.2", "localhost", "LOCALHOST.", "::1", "0:0:0:0:0:0:0:1", "::ffff:127.0.0.1"] {
            #expect(NetworkValidation.isLoopback(host))
        }
        for host in ["128.0.0.1", "proxy.local", "10.0.0.1", "127.example.com", "::2", "::ffff:10.0.0.1", ""] {
            #expect(!NetworkValidation.isLoopback(host))
        }
    }

    @Test func addresses() {
        #expect(NetworkValidation.isAddress("192.168.1.1"))
        #expect(NetworkValidation.isAddress("2606:4700:4700::1111"))
        #expect(!NetworkValidation.isAddress("192.168.1"))
        #expect(!NetworkValidation.isAddress("1.1.1.1; reboot"))
        #expect(NetworkValidation.isAddressOrNetwork("10.0.0.0/8"))
        #expect(NetworkValidation.isAddressOrNetwork("fe80::/10"))
        #expect(!NetworkValidation.isAddressOrNetwork("10.0.0.0/33"))
        #expect(!NetworkValidation.isAddressOrNetwork("10.0.0.0/8/8"))
    }

    @Test func domains() {
        #expect(NetworkValidation.isDomain("test"))
        #expect(NetworkValidation.isDomain("api.example-1.com"))
        #expect(!NetworkValidation.isDomain(""))
        #expect(!NetworkValidation.isDomain("a..b"))
        #expect(!NetworkValidation.isDomain("-bad.com"))
        #expect(!NetworkValidation.isDomain("../etc/passwd"))
        #expect(!NetworkValidation.isDomain("exämple.com"))
    }

    @Test func bypassEntriesAndServices() {
        #expect(NetworkValidation.isBypassEntry("*.local"))
        #expect(NetworkValidation.isBypassEntry("<local>"))
        #expect(!NetworkValidation.isBypassEntry("Empty"))
        #expect(!NetworkValidation.isBypassEntry("a b"))
        #expect(NetworkValidation.isServiceName("USB 10/100/1000 LAN"))
        #expect(!NetworkValidation.isServiceName("-setdnsservers"))
    }
}

// MARK: - Reading the network

struct NetworkParsingTests {
    @Test func services() {
        let output = "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Thunderbolt Bridge\nUSB 10/100/1000 LAN\n"
        #expect(
            NetworkService.parse(list: output) == [
                NetworkService(name: "Wi-Fi", isEnabled: true),
                NetworkService(name: "Thunderbolt Bridge", isEnabled: false),
                NetworkService(name: "USB 10/100/1000 LAN", isEnabled: true),
            ])
    }

    @Test func dnsServers() {
        #expect(NetworkSetupOutput.dnsServers("There aren't any DNS Servers set on Wi-Fi.\n").isEmpty)
        #expect(NetworkSetupOutput.dnsServers("1.1.1.1\n2606:4700:4700::1111\n") == ["1.1.1.1", "2606:4700:4700::1111"])
    }

    @Test func proxy() {
        let on = NetworkSetupOutput.proxy("Enabled: Yes\nServer: 127.0.0.1\nPort: 9090\nAuthenticated Proxy Enabled: 0\n", kind: .web)
        #expect(on == ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: true))
        let off = NetworkSetupOutput.proxy("Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n", kind: .socks)
        #expect(off == ProxyServer(kind: .socks, host: "", port: 0, isOn: false))
    }

    @Test func bypass() {
        #expect(NetworkSetupOutput.bypass("*.local\n169.254/16\n") == ["*.local", "169.254/16"])
        #expect(NetworkSetupOutput.bypass("There aren't any bypass domains set on Wi-Fi.\n").isEmpty)
    }

    @Test func nettop() {
        let output = [
            ",bytes_in,bytes_out,", "launchd.1,18838,9000,", "Google Chrome H.4321,5,6,", "mDNSResponder.499,2911980,1603560,", "bad line",
        ].joined(separator: "\n")
        #expect(
            ProcessTraffic.parse(nettop: output) == [
                ProcessTraffic(pid: 1, name: "launchd", bytesIn: 18_838, bytesOut: 9_000),
                ProcessTraffic(pid: 4321, name: "Google Chrome H", bytesIn: 5, bytesOut: 6),
                ProcessTraffic(pid: 499, name: "mDNSResponder", bytesIn: 2_911_980, bytesOut: 1_603_560),
            ])
    }

    @Test func publicAddress() {
        let trace = "fl=123\nh=1.1.1.1\nip=203.0.113.7\nts=1\nloc=SG\n"
        #expect(PublicAddress.parse(trace: trace) == PublicAddress(address: "203.0.113.7", country: "SG"))
        #expect(PublicAddress.parse(trace: "ip=nope\n") == nil)
    }

    @Test func speedTest() throws {
        let json = """
            {"base_rtt": 66.7, "dl_throughput": 102719608, "ul_throughput": 90679136,
             "responsiveness": 246.9, "interface_name": "en0"}
            """
        let result = try SpeedTestResult.parse(json)
        #expect(SpeedTestResult.megabits(result.download) == "103 Mbps")
        #expect(SpeedTestResult.megabits(result.upload) == "90.7 Mbps")
        #expect(result.responsivenessRating == "Low")
        #expect(result.idleLatency == 66.7)
        #expect(result.interface == "en0")
    }

    @Test func dnsPresetsMatchInAnyOrder() {
        #expect(DNSPreset.matching([]) == .automatic)
        #expect(DNSPreset.matching(["1.0.0.1", "1.1.1.1", "2606:4700:4700::1001", "2606:4700:4700::1111"])?.id == "cloudflare")
        #expect(DNSPreset.matching(["192.168.1.2"]) == nil)
    }

    @Test func profileSummaries() {
        let profiles = Dictionary(uniqueKeysWithValues: ThrottleProfile.builtIn.map { ($0.id, $0) })
        #expect(profiles["3g"]?.summary == "780 Kbps ↓ · 330 Kbps ↑ · +200 ms")
        #expect(profiles["lte"]?.summary == "50 Mbps ↓ · 10 Mbps ↑ · +115 ms")
        #expect(profiles["lossyWifi"]?.summary == "40 Mbps ↓ · 33 Mbps ↑ · +2 ms · 5% loss")
        #expect(profiles["highLatency"]?.summary == "+600 ms")
        #expect(profiles["offline"]?.summary == "Nothing gets through")
        #expect(ThrottleProfile.rate(1_500) == "1.5 Mbps")
    }

    @Test func listItemsSplitOnCommasAndSpaces() {
        #expect(listItems("a.com, b.com\n c.com") == ["a.com", "b.com", "c.com"])
        #expect(listItems("  ").isEmpty)
    }
}

struct BandwidthControllerTests {
    private func traffic(_ pid: pid_t, _ bytesIn: UInt64, _ bytesOut: UInt64) -> ProcessTraffic {
        ProcessTraffic(pid: pid, name: "proc\(pid)", bytesIn: bytesIn, bytesOut: bytesOut)
    }

    @Test func ratesComeFromTheDifferenceBetweenSamples() {
        let bandwidth = BandwidthController(reader: FakeNetworkReader(), appName: { $0 == 2 ? "Safari" : nil })
        let start = ContinuousClock.now
        bandwidth.record([traffic(1, 1_000, 500), traffic(2, 0, 0)], at: start)
        #expect(!bandwidth.isLoaded)
        bandwidth.record([traffic(1, 5_000, 900), traffic(2, 2_000, 0), traffic(3, 9_999, 9_999)], at: start + .seconds(2))
        #expect(bandwidth.usage.map(\.pid) == [1, 2])
        #expect(bandwidth.usage[0].download == 2_000)
        #expect(bandwidth.usage[0].upload == 200)
        #expect(bandwidth.usage[1].name == "Safari")
        #expect(bandwidth.totalDownload == 3_000)
    }

    @Test func aReusedProcessIDShowsFromTheNextSample() {
        let bandwidth = BandwidthController(reader: FakeNetworkReader(), appName: { _ in nil })
        let start = ContinuousClock.now
        bandwidth.record([traffic(7, 10_000, 10_000)], at: start)
        // A new process that already moved 500 MB elsewhere: none of it is this second's.
        bandwidth.record([traffic(7, 500_000_000, 0)], at: start + .seconds(1))
        #expect(bandwidth.usage.isEmpty)
        bandwidth.record([traffic(7, 500_000_100, 0)], at: start + .seconds(2))
        #expect(bandwidth.usage.first?.download == 100)
    }

    @Test func formatsRates() {
        #expect(NetworkSpeedMonitor.detailed(0) == "–")
        #expect(NetworkSpeedMonitor.detailed(628) == "628 B/s")
        #expect(NetworkSpeedMonitor.detailed(2_100) == "2.1 KB/s")
        #expect(NetworkSpeedMonitor.detailed(1_260_000) == "1.3 MB/s")
        #expect(NetworkSpeedMonitor.compact(0) == "0 KB/s")
        #expect(NetworkSpeedMonitor.compact(340_400) == "340 KB/s")
        #expect(NetworkSpeedMonitor.compact(1_240_000) == "1.2 MB/s")
        #expect(NetworkSpeedMonitor.compact(52_000_000) == "52 MB/s")
    }

    /// The unit follows the number as shown, never "1000 KB/s" or a too-wide "10.0 MB/s".
    @Test func formatsRatesAtTheEdgesOfAUnit() {
        #expect(NetworkSpeedMonitor.compact(999_600) == "1.0 MB/s")
        #expect(NetworkSpeedMonitor.compact(9_960_000) == "10 MB/s")
        #expect(NetworkSpeedMonitor.compact(999_600_000) == "1.0 GB/s")
        #expect(NetworkSpeedMonitor.detailed(999.6) == "1.0 KB/s")
        #expect(NetworkSpeedMonitor.detailed(999_960) == "1.0 MB/s")
        #expect(NetworkSpeedMonitor.detailed(999_960_000) == "1.0 GB/s")
    }
}

// MARK: - The controller

struct NetworkControllerTests {
    private let store = TestDefaults()
    private let helper = FakeNetworkHelper()
    private let reader = FakeNetworkReader()

    private func makeController() async -> NetworkController {
        let network = NetworkController(defaults: store.defaults, helper: helper, reader: reader)
        await network.refresh()
        return network
    }

    @Test func followsTheServiceMacOSIsUsing() async {
        let network = await makeController()
        #expect(network.service == "Wi-Fi")
        #expect(network.services.count == 2)
    }

    @Test func startingAThrottleSendsTheProfileAndScope() async {
        let network = await makeController()
        network.profileID = "edge"
        network.excludesLocalNetwork = false
        await network.startThrottle()
        let edge = ThrottleProfile.builtIn.first { $0.id == "edge" }!
        #expect(helper.throttles == [ThrottleSettings(download: edge.download, upload: edge.upload, target: .all)])
        #expect(network.activeThrottle?.profile.id == "edge")
        #expect(network.activeThrottle?.endsAt == nil)
        #expect(network.message == nil)
    }

    @Test func hostNamesAreLookedUpBeforeStarting() async {
        reader.state.withLock { $0.addresses["api.example.com"] = ["203.0.113.7", "2001:db8::7"] }
        let network = await makeController()
        network.scope = .hosts
        network.hostsText = "api.example.com, 198.51.100.1"
        await network.startThrottle()
        #expect(helper.throttles.first??.target == .hosts(["203.0.113.7", "2001:db8::7", "198.51.100.1"]))
    }

    @Test func aHostWithNoAddressStopsIt() async {
        let network = await makeController()
        network.scope = .hosts
        network.hostsText = "nowhere.invalid"
        await network.startThrottle()
        #expect(helper.throttles.isEmpty)
        #expect(network.activeThrottle == nil)
        #expect(network.message?.isError == true)
    }

    /// Picked from the menu bar tile: one that can't start doesn't become the chosen profile.
    @Test func aProfileThatCouldntStartIsntChosen() async {
        let network = await makeController()
        network.scope = .hosts
        network.hostsText = "nowhere.invalid"
        await network.startThrottle(ThrottleProfile.builtIn[2])
        #expect(network.profileID == ThrottleProfile.builtIn[0].id)
        network.scope = .all
        await network.startThrottle(ThrottleProfile.builtIn[2])
        #expect(network.profileID == ThrottleProfile.builtIn[2].id)
    }

    @Test func portsMustBeNumbers() async {
        let network = await makeController()
        network.scope = .ports
        network.portsText = "443 https"
        await network.startThrottle()
        #expect(helper.throttles.isEmpty)
        #expect(network.message?.text == "Ports are numbers, such as 443.")
    }

    @Test func waitingForApprovalSaysWhyAndStaysOff() async {
        helper.needsApproval = true
        let network = await makeController()
        await network.startThrottle()
        #expect(network.activeThrottle == nil)
        #expect(network.message?.text == HelperNeedsApproval(use: .network).errorDescription)
        #expect(network.message?.text.hasSuffix("then try again.") == true)
    }

    @Test func aHelperFailureStaysOff() async {
        helper.failure = "Couldn't load the throttle rules."
        let network = await makeController()
        await network.startThrottle()
        #expect(network.activeThrottle == nil)
        #expect(network.message?.text == "Couldn't load the throttle rules.")
    }

    @Test func everyChangeTellsTheHelperItsUsed() async {
        helper.isAllowed = true
        let network = await makeController()
        await network.flushDNS()
        await network.flushDNS()
        #expect(helper.allowed == 2)
    }

    @Test func aFailedSwitchStopsShowingTheOldThrottle() async {
        let network = await makeController()
        network.duration = .minutes15
        await network.startThrottle()
        #expect(network.activeThrottle != nil)
        helper.failure = "Couldn't load the throttle rules."
        await network.startThrottle(ThrottleProfile.builtIn[1])
        #expect(network.activeThrottle == nil)
    }

    @Test func aBadTargetLeavesTheRunningThrottleAlone() async {
        let network = await makeController()
        await network.startThrottle()
        network.scope = .ports
        network.portsText = "web"
        await network.startThrottle()
        #expect(network.activeThrottle?.scope == .all)
        #expect(helper.throttles.count == 1)
    }

    @Test func stoppingWhenTheHelperFailsClosesTheConnectionButKeepsTheHelper() async {
        let network = await makeController()
        await network.startThrottle()
        helper.failure = "The helper didn't answer."
        await network.stopThrottle()
        #expect(network.activeThrottle == nil)
        #expect(helper.disconnected == 1)
        #expect(helper.disallowed == 0)
    }

    @Test func stoppingSendsNothingToThrottle() async {
        let network = await makeController()
        await network.toggleThrottle()
        await network.toggleThrottle()
        #expect(helper.throttles.count == 2)
        #expect(helper.throttles.last! == nil)
        #expect(network.activeThrottle == nil)
    }

    @Test func aTimedThrottleKnowsWhenItEnds() async {
        let network = await makeController()
        network.duration = .minutes15
        await network.startThrottle()
        let endsAt = try? #require(network.activeThrottle?.endsAt)
        #expect(endsAt.map { abs($0.timeIntervalSinceNow - 900) < 5 } == true)
        await network.stopThrottle()
    }

    @Test func aHelperThatWentAwayEndsTheThrottle() async {
        let network = await makeController()
        await network.startThrottle()
        helper.onInterrupted?()
        #expect(network.activeThrottle == nil)
        #expect(network.message?.isError == true)
    }

    /// Found out as the next request went out: that request's result doesn't hide it.
    @Test func aThrottleLostAsTheNextChangeWentOutIsStillSaid() async {
        let network = await makeController()
        await network.startThrottle()
        helper.goesAway = true
        await network.flushDNS()
        #expect(network.activeThrottle == nil)
        #expect(network.message?.isError == true)
        #expect(network.message?.text.contains("throttling stopped") == true)
    }

    @Test func aThrottleLostAsANewOneStartedIsntSaid() async {
        let network = await makeController()
        await network.startThrottle()
        helper.goesAway = true
        await network.startThrottle(ThrottleProfile.builtIn[1])
        #expect(network.activeThrottle?.profile == ThrottleProfile.builtIn[1])
        #expect(network.message == nil)
    }

    @Test func turningTheModuleOffLetsTheHelperGo() async {
        let network = await makeController()
        await network.startThrottle()
        network.stop()
        #expect(network.activeThrottle == nil)
        #expect(helper.disallowed == 1)
    }

    @Test func settingsOutlastTheApp() async {
        let network = await makeController()
        network.profileID = "lte"
        network.scope = .dns
        network.duration = .hour1
        let next = NetworkController(defaults: store.defaults, helper: FakeNetworkHelper(), reader: reader)
        #expect(next.profileID == "lte")
        #expect(next.scope == .dns)
        #expect(next.duration == .hour1)
    }

    @Test func customProfilesAreSavedAndDeleted() async {
        let network = await makeController()
        let hotel = ThrottleProfile(
            id: "hotel", name: "Hotel", download: ThrottleLink(kilobitsPerSecond: 500), upload: ThrottleLink(kilobitsPerSecond: 100),
            isBuiltIn: true)
        network.saveProfile(hotel)
        #expect(network.profile.name == "Hotel")
        #expect(network.profile.isBuiltIn == false)
        let next = NetworkController(defaults: store.defaults, helper: FakeNetworkHelper(), reader: reader)
        #expect(next.customProfiles.map(\.id) == ["hotel"])
        network.deleteProfile(network.profile)
        #expect(network.customProfiles.isEmpty)
        #expect(network.profileID == ThrottleProfile.builtIn[0].id)
    }

    @Test func dnsGoesToTheChosenService() async {
        let network = await makeController()
        let cloudflare = DNSPreset.all.first { $0.id == "cloudflare" }!
        reader.state.withLock { $0.dns["Wi-Fi"] = cloudflare.servers }
        await network.setDNSServers(cloudflare.servers)
        #expect(helper.dnsChanges.first?.service == "Wi-Fi")
        #expect(helper.dnsChanges.first?.servers == cloudflare.servers)
        #expect(network.dnsPreset == cloudflare)
        #expect(network.message?.isError == false)
    }

    @Test func badDNSServersNeverReachTheHelper() async {
        let network = await makeController()
        await network.setDNSServers(["dns.example.com"])
        #expect(helper.dnsChanges.isEmpty)
        #expect(network.message?.isError == true)
    }

    @Test func flushesTheCache() async {
        let network = await makeController()
        await network.flushDNS()
        #expect(helper.flushes == 1)
    }

    @Test func resolversAreSavedAndOnlyManagedOnesRemoved() async {
        let network = await makeController()
        #expect(await network.saveResolver(ResolverFile(domain: "test", nameservers: ["127.0.0.1"], port: 5353)))
        #expect(!(await network.saveResolver(ResolverFile(domain: "test", nameservers: []))))
        #expect(helper.resolvers.count == 1)
        var other = ResolverFile(domain: "corp", nameservers: ["10.0.0.1"])
        other.isManaged = false
        await network.removeResolver(other)
        #expect(helper.resolvers.count == 1)
        await network.removeResolver(ResolverFile(domain: "test", nameservers: ["127.0.0.1"]))
        #expect(helper.resolvers.last == ResolverFile(domain: "test", nameservers: []))
    }

    @Test func proxyToggleFlipsTheConfiguredOnes() async {
        var proxies = ProxyState()
        proxies.servers[.web] = ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: false)
        proxies.servers[.socks] = ProxyServer(kind: .socks, host: "", port: 0, isOn: false)
        reader.state.withLock { $0.proxies["Wi-Fi"] = proxies }
        let network = await makeController()
        await network.toggleProxy()
        #expect(helper.proxyChanges.first?.change.servers == [ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: true)])
    }

    /// A proxy left with a host but no port doesn't keep the others from coming on.
    @Test func proxyToggleSkipsOneWithoutAPort() async {
        var proxies = ProxyState()
        proxies.servers[.web] = ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: false)
        proxies.servers[.socks] = ProxyServer(kind: .socks, host: "127.0.0.1", port: 0, isOn: false)
        reader.state.withLock { $0.proxies["Wi-Fi"] = proxies }
        let network = await makeController()
        await network.toggleProxy()
        #expect(helper.proxyChanges.first?.change.servers == [ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: true)])
    }

    /// Turning back on brings back what the toggle turned off, not every proxy with a host.
    @Test func proxyToggleBringsBackWhatItTurnedOff() async {
        var proxies = ProxyState()
        proxies.servers[.web] = ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: true)
        proxies.servers[.socks] = ProxyServer(kind: .socks, host: "127.0.0.1", port: 1080, isOn: false)
        reader.state.withLock { $0.proxies["Wi-Fi"] = proxies }
        let network = await makeController()
        await network.toggleProxy()
        proxies.servers[.web]?.isOn = false
        reader.state.withLock { $0.proxies["Wi-Fi"] = proxies }
        await network.toggleProxy()
        #expect(helper.proxyChanges.last?.change.servers == [ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: true)])
    }

    /// Shown as on, but turned off in System Settings before the button was pressed.
    @Test func turnOffNeverTurnsProxiesOn() async {
        var proxies = ProxyState()
        proxies.servers[.web] = ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: false)
        reader.state.withLock { $0.proxies["Wi-Fi"] = proxies }
        let network = await makeController()
        await network.turnOffProxies()
        #expect(helper.proxyChanges.isEmpty)
    }

    /// A turn-off that failed keeps the list of what to turn back on.
    @Test func aFailedTurnOffKeepsWhatToBringBack() async {
        var proxies = ProxyState()
        proxies.servers[.web] = ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: true)
        proxies.servers[.socks] = ProxyServer(kind: .socks, host: "127.0.0.1", port: 1080, isOn: false)
        reader.state.withLock { $0.proxies["Wi-Fi"] = proxies }
        let network = await makeController()
        await network.toggleProxy()
        // SOCKS turned on in System Settings, then a turn-off that fails.
        proxies.servers[.socks]?.isOn = true
        reader.state.withLock { $0.proxies["Wi-Fi"] = proxies }
        helper.failure = "networksetup failed."
        await network.toggleProxy()
        helper.failure = nil
        proxies.servers[.web]?.isOn = false
        proxies.servers[.socks]?.isOn = false
        reader.state.withLock { $0.proxies["Wi-Fi"] = proxies }
        await network.toggleProxy()
        #expect(helper.proxyChanges.last?.change.servers == [ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: true)])
    }

    @Test func proxyToggleTurnsOffOneLeftWithoutAHost() async {
        var proxies = ProxyState()
        proxies.servers[.socks] = ProxyServer(kind: .socks, host: "", port: 0, isOn: true)
        reader.state.withLock { $0.proxies["Wi-Fi"] = proxies }
        let network = await makeController()
        await network.toggleProxy()
        #expect(helper.proxyChanges.first?.change.servers == [ProxyServer(kind: .socks, host: "", port: 0, isOn: false)])
    }

    /// From a shortcut, before anything read them, and after they changed in System Settings.
    @Test func proxyToggleReadsTheProxiesFirst() async {
        let network = NetworkController(defaults: store.defaults, helper: helper, reader: reader)
        var proxies = ProxyState()
        proxies.servers[.web] = ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: true)
        reader.state.withLock { $0.proxies["Wi-Fi"] = proxies }
        await network.toggleProxy()
        #expect(helper.proxyChanges.first?.service == "Wi-Fi")
        #expect(helper.proxyChanges.first?.change.servers == [ProxyServer(kind: .web, host: "127.0.0.1", port: 9090, isOn: false)])
    }

    @Test func aFailedReadKeepsTheDNSServersShown() async {
        reader.state.withLock { $0.dns["Wi-Fi"] = ["192.168.1.53"] }
        let network = await makeController()
        reader.state.withLock { $0.dnsFails = true }
        await network.refreshForMenu()
        await network.refresh()
        #expect(network.dnsServers == ["192.168.1.53"])
    }

    @Test func proxyToggleWithNothingSetSaysSo() async {
        let network = await makeController()
        await network.toggleProxy()
        #expect(helper.proxyChanges.isEmpty)
        #expect(network.message?.text == "Set a proxy's host and port first.")
    }

    @Test func proxyPresetsPointHTTPAndHTTPSAtThisMac() async {
        let network = await makeController()
        await network.useProxyPreset(ProxyPreset.all[0])
        let servers = helper.proxyChanges.first?.change.servers ?? []
        #expect(servers.map(\.kind) == [.web, .secureWeb])
        #expect(servers.allSatisfy { $0.host == "127.0.0.1" && $0.port == 9090 && $0.isOn })
    }
}

struct NetworkSpeedTests {
    private let store = TestDefaults()

    @Test func speedComesFromTheDifferenceBetweenSamples() {
        let speed = NetworkSpeedMonitor(defaults: store.defaults, read: { nil })
        let start = ContinuousClock.now
        speed.record(InterfaceCounters(bytesIn: 1_000, bytesOut: 500), at: start)
        #expect(speed.download == 0)
        speed.record(InterfaceCounters(bytesIn: 3_000_000, bytesOut: 100_500), at: start + .seconds(2))
        #expect(speed.download == 1_499_500)
        #expect(speed.upload == 50_000)
    }

    /// As when an interface went away: no burst, and not the last speed left showing either.
    @Test func countersThatWentDownShowNothingMoving() {
        let speed = NetworkSpeedMonitor(defaults: store.defaults, read: { nil })
        let start = ContinuousClock.now
        speed.record(InterfaceCounters(bytesIn: 9_000, bytesOut: 9_000), at: start)
        speed.record(InterfaceCounters(bytesIn: 10_000, bytesOut: 10_000), at: start + .seconds(1))
        speed.record(InterfaceCounters(bytesIn: 5, bytesOut: 5), at: start + .seconds(2))
        #expect(speed.download == 0)
        speed.record(InterfaceCounters(bytesIn: 2_005, bytesOut: 5), at: start + .seconds(3))
        #expect(speed.download == 2_000)
    }

    @Test func onlyInterfacesThatLeaveTheMacCount() {
        #expect(InterfaceCounters.counts("en0"))
        #expect(InterfaceCounters.counts("pdp_ip0"))
        #expect(!InterfaceCounters.counts("lo0"))
        #expect(!InterfaceCounters.counts("utun4"))
        #expect(!InterfaceCounters.counts("awdl0"))
    }

    @Test func readsThisMacsCounters() {
        #expect(InterfaceCounters.read() != nil)
    }

    @Test func stoppingClearsTheSpeed() {
        let speed = NetworkSpeedMonitor(defaults: store.defaults, read: { nil })
        let start = ContinuousClock.now
        speed.record(InterfaceCounters(bytesIn: 0, bytesOut: 0), at: start)
        speed.record(InterfaceCounters(bytesIn: 1_000, bytesOut: 0), at: start + .seconds(1))
        speed.stop()
        #expect(speed.download == 0)
        #expect(!speed.isRunning)
    }

    @Test func theItemShowsOnlyWhileTheModuleAndSettingAreOn() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        state.setShowsNetworkSpeed(true)
        #expect(!state.showsNetworkSpeed)
        #expect(!state.networkSpeed.isRunning)
        state.setEnabled(.network, true)
        #expect(state.showsNetworkSpeed)
        #expect(state.networkSpeed.isRunning)
        state.setEnabled(.network, false)
        #expect(!state.showsNetworkSpeed)
        #expect(!state.networkSpeed.isRunning)
        // The setting itself stays, for when the module comes back on.
        #expect(state.networkSpeed.showsInMenuBar)
    }
}

struct NetworkMenuRefreshTests {
    @Test func readsOnlyWhatTheTilesShow() async {
        let reader = FakeNetworkReader()
        reader.state.withLock { $0.dns["Wi-Fi"] = ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"] }
        let network = NetworkController(defaults: TestDefaults().defaults, helper: FakeNetworkHelper(), reader: reader)
        await network.refreshForMenu()
        #expect(network.primaryService == "Wi-Fi")
        #expect(network.dnsPreset?.id == "cloudflare")
        #expect(network.services.isEmpty)
    }
}

struct BandwidthWatchTests {
    @Test func oneLoopSamplesForEveryWatcher() async throws {
        let reader = FakeNetworkReader()
        let bandwidth = BandwidthController(reader: reader, appName: { _ in nil })
        let first = Task { await bandwidth.watch() }
        let second = Task { await bandwidth.watch() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(bandwidth.watchers == 2)
        first.cancel()
        await first.value
        #expect(bandwidth.watchers == 1)
        second.cancel()
        await second.value
        #expect(bandwidth.watchers == 0)
    }

    /// Reopened later, it measures afresh rather than show the last session's apps as current.
    @Test func watchingAgainStartsFromNothing() async throws {
        let bandwidth = BandwidthController(reader: FakeNetworkReader(), appName: { _ in nil })
        let start = ContinuousClock.now
        bandwidth.record([ProcessTraffic(pid: 1, name: "curl", bytesIn: 0, bytesOut: 0)], at: start)
        bandwidth.record([ProcessTraffic(pid: 1, name: "curl", bytesIn: 5_000, bytesOut: 0)], at: start + .seconds(1))
        #expect(bandwidth.isLoaded)
        let watch = Task { await bandwidth.watch() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(bandwidth.usage.isEmpty)
        watch.cancel()
        await watch.value
    }
}

struct NetworkStopTests {
    @Test func aStartWaitingOnLookupsGivesUpWhenTheModuleGoesOff() async {
        let helper = FakeNetworkHelper()
        let reader = SlowLookupReader()
        let network = NetworkController(defaults: TestDefaults().defaults, helper: helper, reader: reader)
        network.scope = .hosts
        network.hostsText = "slow.example.com"
        let start = Task { await network.startThrottle() }
        try? await Task.sleep(for: .milliseconds(50))
        network.stop()
        reader.release()
        await start.value
        #expect(helper.throttles.isEmpty)
        #expect(helper.allowed == 0)
        #expect(network.activeThrottle == nil)
    }

    /// Turning the module off closes the connection, which stops the throttle in the helper,
    /// even when its reply was already on its way.
    @Test func aStartWhoseReplyComesAfterTheModuleWentOffShowsNothing() async {
        let helper = FakeNetworkHelper()
        let replies = Gate()
        helper.replies = replies
        let network = NetworkController(defaults: TestDefaults().defaults, helper: helper, reader: FakeNetworkReader())
        let start = Task { await network.startThrottle() }
        await waitUntilBusy(network)
        network.stop()
        replies.open()
        await start.value
        #expect(network.activeThrottle == nil)
    }

    /// Pressed twice before the first start is done, the toggle ends up off.
    @Test func aSecondToggleStopsAThrottleStillStarting() async {
        let helper = FakeNetworkHelper()
        let replies = Gate()
        helper.replies = replies
        let network = NetworkController(defaults: TestDefaults().defaults, helper: helper, reader: FakeNetworkReader())
        let first = Task { await network.toggleThrottle() }
        await waitUntilBusy(network)
        let second = Task { await network.toggleThrottle() }
        try? await Task.sleep(for: .milliseconds(50))
        replies.open()
        await first.value
        await second.value
        #expect(network.activeThrottle == nil)
        #expect(helper.throttles.last == .some(nil))
    }

    /// A change asked for before the module went off doesn't register the helper again.
    @Test func aChangeAskedForBeforeTheModuleWentOffIsDropped() async {
        let helper = FakeNetworkHelper()
        let reader = SlowServiceReader()
        let network = NetworkController(defaults: TestDefaults().defaults, helper: helper, reader: reader)
        let change = Task { await network.setDNSServers(["1.1.1.1"]) }
        try? await Task.sleep(for: .milliseconds(50))
        network.stop()
        reader.release()
        await change.value
        #expect(helper.allowed == 0)
        #expect(helper.dnsChanges.isEmpty)
    }

    /// Switching services while the first one's settings are still being read shows the second's.
    @Test func aSlowReadForAServiceNoLongerPickedIsDropped() async {
        let reader = SlowDNSReader(slowService: "Wi-Fi")
        reader.inner.state.withLock {
            $0.dns = ["Wi-Fi": ["1.1.1.1"], "Ethernet": ["9.9.9.9"]]
        }
        let network = NetworkController(defaults: TestDefaults().defaults, helper: FakeNetworkHelper(), reader: reader)
        network.chosenService = "Wi-Fi"
        try? await Task.sleep(for: .milliseconds(50))
        network.chosenService = "Ethernet"
        for _ in 0..<2_000 where network.dnsServers != ["9.9.9.9"] {
            try? await Task.sleep(for: .milliseconds(5))
        }
        reader.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(network.dnsServers == ["9.9.9.9"])
    }

    @Test func aChangeWhileAnotherIsGoingThroughSaysSo() async {
        let helper = FakeNetworkHelper()
        let replies = Gate()
        helper.replies = replies
        let network = NetworkController(defaults: TestDefaults().defaults, helper: helper, reader: FakeNetworkReader())
        let start = Task { await network.startThrottle() }
        await waitUntilBusy(network)
        await network.flushDNS()
        #expect(helper.flushes == 0)
        #expect(network.message?.text == NetworkController.busyMessage)
        replies.open()
        await start.value
        #expect(network.activeThrottle != nil)
    }
}

/// Waits for the throttle request to reach the helper, however busy the machine running the tests.
private func waitUntilBusy(_ network: NetworkController) async {
    for _ in 0..<2_000 where !network.isBusy {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(network.isBusy)
}

/// Holds the lookup of which service macOS is using until released, like a slow SCDynamicStore.
nonisolated final class SlowServiceReader: NetworkReading, Sendable {
    private let gate = Gate()
    private let inner = FakeNetworkReader()

    func release() { gate.open() }

    func services() async throws -> [NetworkService] { try await inner.services() }
    func dnsServers(service: String) async throws -> [String] { try await inner.dnsServers(service: service) }
    func proxies(service: String) async throws -> ProxyState { try await inner.proxies(service: service) }
    func resolvers() async -> [ResolverFile] { await inner.resolvers() }
    func snapshot() async -> NetworkSnapshot { await inner.snapshot() }
    func publicAddress() async throws -> PublicAddress { try await inner.publicAddress() }
    func speedTest() async throws -> SpeedTestResult { try await inner.speedTest() }
    func traffic() async throws -> [ProcessTraffic] { try await inner.traffic() }
    func addresses(of host: String) async -> [String] { await inner.addresses(of: host) }

    func primaryService() async -> String? {
        await gate.wait()
        return await inner.primaryService()
    }
}

/// Holds reading one service's DNS servers until released, like a networksetup that's slow.
nonisolated final class SlowDNSReader: NetworkReading, Sendable {
    private let gate = Gate()
    private let slowService: String
    let inner = FakeNetworkReader()

    init(slowService: String) {
        self.slowService = slowService
    }

    func release() { gate.open() }

    func services() async throws -> [NetworkService] { try await inner.services() }
    func dnsServers(service: String) async throws -> [String] {
        if service == slowService { await gate.wait() }
        return try await inner.dnsServers(service: service)
    }
    func proxies(service: String) async throws -> ProxyState { try await inner.proxies(service: service) }
    func resolvers() async -> [ResolverFile] { await inner.resolvers() }
    func snapshot() async -> NetworkSnapshot { await inner.snapshot() }
    func publicAddress() async throws -> PublicAddress { try await inner.publicAddress() }
    func speedTest() async throws -> SpeedTestResult { try await inner.speedTest() }
    func traffic() async throws -> [ProcessTraffic] { try await inner.traffic() }
    func addresses(of host: String) async -> [String] { await inner.addresses(of: host) }
    func primaryService() async -> String? { await inner.primaryService() }
}

/// Holds host lookups until released, like a slow DNS server.
nonisolated final class SlowLookupReader: NetworkReading, Sendable {
    private let gate = Gate()
    private let inner = FakeNetworkReader()

    func release() { gate.open() }

    func services() async throws -> [NetworkService] { try await inner.services() }
    func dnsServers(service: String) async throws -> [String] { try await inner.dnsServers(service: service) }
    func proxies(service: String) async throws -> ProxyState { try await inner.proxies(service: service) }
    func resolvers() async -> [ResolverFile] { await inner.resolvers() }
    func snapshot() async -> NetworkSnapshot { await inner.snapshot() }
    func primaryService() async -> String? { await inner.primaryService() }
    func publicAddress() async throws -> PublicAddress { try await inner.publicAddress() }
    func speedTest() async throws -> SpeedTestResult { try await inner.speedTest() }
    func traffic() async throws -> [ProcessTraffic] { try await inner.traffic() }

    func addresses(of host: String) async -> [String] {
        await gate.wait()
        return ["203.0.113.9"]
    }
}
