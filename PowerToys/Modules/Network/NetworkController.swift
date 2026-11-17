import Foundation
import Observation

/// Throttling, DNS, resolvers and proxies: everything in the Network module that changes the
/// system, which goes through the root helper.
@Observable
final class NetworkController {
    /// The last thing that went wrong, or that worked, shown as a banner.
    private(set) var message: (text: String, isError: Bool)?
    /// Something is being changed; buttons wait for it.
    private(set) var isBusy = false

    // MARK: Services

    private(set) var services: [NetworkService] = []
    /// The service DNS and proxy changes apply to; nil follows the one macOS is using.
    var chosenService: String? {
        didSet {
            defaults.set(chosenService, forKey: Self.chosenServiceKey)
            // `refresh` reads the service's settings itself after resetting this.
            if !isRefreshing { Task { await refreshServiceSettings() } }
        }
    }
    /// The service macOS sends traffic through now, such as Wi‑Fi.
    private(set) var primaryService: String?

    var service: String? { chosenService ?? primaryService ?? services.first(where: \.isEnabled)?.name }

    // MARK: Throttle

    private(set) var customProfiles: [ThrottleProfile]
    var profileID: String {
        didSet { defaults.set(profileID, forKey: Self.profileKey) }
    }
    var scope: ThrottleScope {
        didSet { defaults.set(scope.rawValue, forKey: Self.scopeKey) }
    }
    var hostsText: String {
        didSet { defaults.set(hostsText, forKey: Self.hostsKey) }
    }
    var portsText: String {
        didSet { defaults.set(portsText, forKey: Self.portsKey) }
    }
    var excludesLocalNetwork: Bool {
        didSet { defaults.set(excludesLocalNetwork, forKey: Self.excludesLocalKey) }
    }
    var duration: ThrottleDuration {
        didSet { defaults.set(duration.rawValue, forKey: Self.durationKey) }
    }

    struct ActiveThrottle: Equatable {
        let profile: ThrottleProfile
        let scope: ThrottleScope
        let endsAt: Date?
    }

    private(set) var activeThrottle: ActiveThrottle?

    // MARK: DNS, resolvers, proxies

    /// The DNS servers set by hand on `service`; empty means the network's own.
    private(set) var dnsServers: [String] = []
    private(set) var resolvers: [ResolverFile] = []
    private(set) var proxies = ProxyState()

    static let chosenServiceKey = "network.service"
    static let profileKey = "network.throttle.profile"
    static let customProfilesKey = "network.throttle.customProfiles"
    static let scopeKey = "network.throttle.scope"
    static let hostsKey = "network.throttle.hosts"
    static let portsKey = "network.throttle.ports"
    static let excludesLocalKey = "network.throttle.excludesLocal"
    static let durationKey = "network.throttle.duration"
    static let toggledOffProxiesKey = "network.proxy.toggledOff"

    static let toggleThrottleShortcut = ShortcutDefinition(
        id: "network.toggleThrottle", module: .network, title: "Turn throttling on or off", defaultHotKey: nil)
    static let flushDNSShortcut = ShortcutDefinition(
        id: "network.flushDNS", module: .network, title: "Flush the DNS cache", defaultHotKey: nil)
    static let toggleProxyShortcut = ShortcutDefinition(
        id: "network.toggleProxy", module: .network, title: "Turn the proxy on or off", defaultHotKey: nil)

    private let defaults: UserDefaults
    @ObservationIgnored private let helper: any NetworkPrivileges
    @ObservationIgnored private let reader: any NetworkReading
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    /// The last throttle start or stop, which the next one waits for, so they reach the helper
    /// in the order they were asked for.
    @ObservationIgnored private var throttleQueue: Task<Void, Never>?
    /// Counts `stop`s, so a start that was looking up hosts when the module went off gives up.
    @ObservationIgnored private var stops = 0
    /// Counts the throttles lost to the helper going away. The connection reports that as the
    /// next request goes out, so the request mustn't replace what `helperWentAway` said.
    @ObservationIgnored private var throttlesLost = 0

    init(defaults: UserDefaults = .standard, helper: any NetworkPrivileges, reader: any NetworkReading = LiveNetworkReader()) {
        self.defaults = defaults
        self.helper = helper
        self.reader = reader
        chosenService = defaults.string(forKey: Self.chosenServiceKey)
        customProfiles =
            defaults.data(forKey: Self.customProfilesKey)
            .flatMap { try? JSONDecoder().decode([ThrottleProfile].self, from: $0) } ?? []
        profileID = defaults.string(forKey: Self.profileKey) ?? ThrottleProfile.builtIn[0].id
        scope = defaults.string(forKey: Self.scopeKey).flatMap(ThrottleScope.init(rawValue:)) ?? .all
        hostsText = defaults.string(forKey: Self.hostsKey) ?? ""
        portsText = defaults.string(forKey: Self.portsKey) ?? ""
        excludesLocalNetwork = defaults.object(forKey: Self.excludesLocalKey) as? Bool ?? true
        duration = ThrottleDuration(rawValue: defaults.integer(forKey: Self.durationKey)) ?? .untilStopped
        helper.onInterrupted = { [weak self] in self?.helperWentAway() }
        isHelperAllowed = helper.isAllowed
    }

    /// Whether the helper is allowed in System Settings, as last checked. Kept here rather than
    /// asked each time, so views redraw when it changes.
    private(set) var isHelperAllowed = false

    /// Checks again whether the helper is allowed, as when coming back from System Settings.
    func refreshHelperStatus() {
        let allowed = helper.isAllowed
        if allowed != isHelperAllowed { isHelperAllowed = allowed }
    }

    func dismissMessage() { message = nil }

    // MARK: Reading

    /// Reads services, the chosen service's DNS and proxies, and resolver files again.
    func refresh() async {
        refreshHelperStatus()
        async let listed = try? reader.services()
        async let primary = reader.primaryService()
        if let listed = await listed { services = listed }
        primaryService = await primary
        // A chosen service that's gone goes back to following macOS.
        if let chosen = chosenService, !services.isEmpty, !services.contains(where: { $0.name == chosen }) {
            isRefreshing = true
            chosenService = nil
            isRefreshing = false
        }
        await refreshServiceSettings()
    }

    /// Reads just what the menu bar tiles show: the service macOS is using, and its DNS and proxies.
    func refreshForMenu() async {
        primaryService = await reader.primaryService()
        guard let service else { return }
        async let dns = try? reader.dnsServers(service: service)
        async let proxies = try? reader.proxies(service: service)
        let (readDNS, readProxies) = await (dns, proxies)
        guard service == self.service else { return }
        // A read that failed keeps what was shown, rather than claim DNS is automatic.
        if let readDNS { dnsServers = readDNS }
        if let readProxies { self.proxies = readProxies }
    }

    /// Reads the chosen service's DNS and proxies, and the resolver files, at the same time.
    private func refreshServiceSettings() async {
        async let resolvers = reader.resolvers()
        guard let service else {
            self.resolvers = await resolvers
            return
        }
        async let dns = try? reader.dnsServers(service: service)
        async let proxies = try? reader.proxies(service: service)
        self.resolvers = await resolvers
        let (readDNS, readProxies) = await (dns, proxies)
        // Another service was picked while this one was read; its own read shows its settings.
        guard service == self.service else { return }
        if let readDNS { dnsServers = readDNS }
        if let readProxies { self.proxies = readProxies }
    }

    // MARK: Helper

    /// Runs a change through the helper, registering it first if need be. A helper waiting for
    /// approval in System Settings says so instead. Returns false without trying while another
    /// change is running, and says so, or when the module went off since the change was asked
    /// for at `stops`, which would register the helper again for a module that's off.
    @discardableResult
    private func withHelper(since stops: Int, success: String? = nil, _ change: () async throws -> Void) async -> Bool {
        guard stops == self.stops else { return false }
        guard !isBusy else {
            message = (Self.busyMessage, true)
            return false
        }
        isBusy = true
        defer {
            isBusy = false
            refreshHelperStatus()
        }
        let throttlesLost = throttlesLost
        // What `helperWentAway` said if the helper went away as this went out, ahead of this
        // change's own result.
        var lostNotice: String? { self.throttlesLost == throttlesLost ? nil : message?.text }
        do {
            // Every time, so the helper knows the Network module uses it even when lid sleep
            // registered it, and isn't unregistered when lid sleep lets go.
            try helper.allow()
            try await change()
            if let lostNotice {
                message = (lostNotice, true)
            } else {
                message = success.map { ($0, false) }
            }
            return true
        } catch {
            message = ([lostNotice, error.localizedDescription].compactMap(\.self).joined(separator: " "), true)
            return false
        }
    }

    /// The module was turned off: stops a throttle and lets the helper go. DNS, resolver and
    /// proxy settings stay, as they're the Mac's own settings.
    func stop() {
        stops += 1
        expiry?.cancel()
        expiry = nil
        activeThrottle = nil
        // Closing the connection stops the throttle in the helper.
        helper.disallow()
    }

    /// The helper restarted or was turned off, which stopped any throttle.
    private func helperWentAway() {
        refreshHelperStatus()
        guard activeThrottle != nil else { return }
        expiry?.cancel()
        expiry = nil
        activeThrottle = nil
        throttlesLost += 1
        message = (
            helper.isAllowed
                ? "The helper restarted, so throttling stopped."
                : "The helper was turned off in System Settings, so throttling stopped.", true
        )
    }

    static let busyMessage = "Another change is still going through. Try again once it's done."

    // MARK: Throttle

    var profiles: [ThrottleProfile] { ThrottleProfile.builtIn + customProfiles }

    var profile: ThrottleProfile { profiles.first { $0.id == profileID } ?? ThrottleProfile.builtIn[0] }

    /// The settings to send, or why they can't be. Host names are looked up now, since pf takes
    /// only addresses.
    func throttleSettings(for profile: ThrottleProfile) async throws -> ThrottleSettings {
        let target: ThrottleTarget
        switch scope {
        case .all: target = .all
        case .dns: target = .dns
        case .hosts:
            var addresses: [String] = []
            for host in listItems(hostsText) {
                let found = await reader.addresses(of: host)
                guard !found.isEmpty else { throw CommandError(errorDescription: "Couldn't find an address for “\(host)”.") }
                addresses += found.filter { !addresses.contains($0) }
            }
            target = .hosts(addresses)
        case .ports:
            let items = listItems(portsText)
            let ports = items.compactMap(Int.init)
            guard ports.count == items.count else { throw CommandError(errorDescription: "Ports are numbers, such as 443.") }
            target = .ports(ports)
        }
        let settings = ThrottleSettings(
            download: profile.download, upload: profile.upload, target: target, excludesLocalNetwork: excludesLocalNetwork)
        if let problem = settings.problem { throw CommandError(errorDescription: problem) }
        return settings
    }

    /// Runs throttle starts and stops one after another.
    private func inOrder(_ operation: @escaping () async -> Void) async {
        let previous = throttleQueue
        let task = Task {
            await previous?.value
            await operation()
        }
        throttleQueue = task
        await task.value
    }

    /// Starts throttling with `profile`, or the chosen one, replacing a throttle already running.
    func startThrottle(_ profile: ThrottleProfile? = nil) async {
        let stops = stops
        startsQueued += 1
        defer { startsQueued -= 1 }
        await inOrder { [weak self] in await self?.performStart(profile, stops: stops) }
    }

    /// Starts on their way, so a second press of the toggle stops the throttle a first press is
    /// still starting.
    @ObservationIgnored private var startsQueued = 0

    private func performStart(_ profile: ThrottleProfile?, stops: Int) async {
        guard stops == self.stops else { return }
        guard !isBusy else {
            message = (Self.busyMessage, true)
            return
        }
        let profile = profile ?? self.profile
        // A problem found here leaves a throttle already running as it is.
        let settings: ThrottleSettings
        do {
            settings = try await throttleSettings(for: profile)
        } catch {
            message = (error.localizedDescription, true)
            return
        }
        let endsAt = duration.interval.map { Date.now.addingTimeInterval($0) }
        // Another change may have started while host names were looked up, or the module gone
        // off. Nothing was sent, so what's running stays as it is. No await between here and
        // withHelper's own check.
        guard stops == self.stops else { return }
        guard !isBusy else {
            message = (Self.busyMessage, true)
            return
        }
        guard await withHelper(since: stops, { try await helper.setThrottle(settings) }) else {
            // The helper stops what was running when a new throttle fails, so nothing is on now.
            expiry?.cancel()
            expiry = nil
            activeThrottle = nil
            return
        }
        // Turned off while the reply was on its way: closing the connection then stopped it.
        guard stops == self.stops else { return }
        // A throttle lost as this one went out no longer matters with this one running.
        message = nil
        // Chosen once it's running, so one that couldn't start leaves the choice as it was.
        if profile.id != profileID { profileID = profile.id }
        activeThrottle = ActiveThrottle(profile: profile, scope: scope, endsAt: endsAt)
        scheduleExpiry(endsAt)
    }

    /// Stops even while another change is running, as when a timed throttle runs out, but after
    /// a start that's already on its way.
    func stopThrottle() async {
        await inOrder { [weak self] in await self?.performStop() }
    }

    private func performStop() async {
        guard activeThrottle != nil else { return }
        expiry?.cancel()
        expiry = nil
        activeThrottle = nil
        do {
            try await helper.setThrottle(nil)
        } catch {
            // Closing the connection makes the helper stop it, and keeps the helper registered.
            helper.disconnect()
        }
    }

    func toggleThrottle() async {
        if activeThrottle == nil, startsQueued == 0 { await startThrottle() } else { await stopThrottle() }
    }

    private func scheduleExpiry(_ endsAt: Date?) {
        expiry?.cancel()
        expiry = endsAt.map { endsAt in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, endsAt.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                await self?.stopThrottle()
            }
        }
    }

    /// Adds or replaces a profile of your own and picks it.
    func saveProfile(_ profile: ThrottleProfile) {
        var profile = profile
        profile.isBuiltIn = false
        if let index = customProfiles.firstIndex(where: { $0.id == profile.id }) {
            customProfiles[index] = profile
        } else {
            customProfiles.append(profile)
        }
        saveCustomProfiles()
        profileID = profile.id
    }

    func deleteProfile(_ profile: ThrottleProfile) {
        customProfiles.removeAll { $0.id == profile.id }
        saveCustomProfiles()
        if profileID == profile.id { profileID = ThrottleProfile.builtIn[0].id }
    }

    private func saveCustomProfiles() {
        defaults.set(try? JSONEncoder().encode(customProfiles), forKey: Self.customProfilesKey)
    }

    // MARK: DNS

    var dnsPreset: DNSPreset? { DNSPreset.matching(dnsServers) }

    func setDNSServers(_ servers: [String]) async {
        let stops = stops
        // From the menu, nothing may have read which service macOS is using yet.
        if service == nil { await refreshForMenu() }
        guard let service else {
            message = ("There's no network service to set DNS for.", true)
            return
        }
        if let bad = servers.first(where: { !NetworkValidation.isAddress($0) }) {
            message = ("“\(bad)” isn't an IP address.", true)
            return
        }
        let name = DNSPreset.matching(servers)?.name ?? "your servers"
        let done = await withHelper(since: stops, success: "\(service) now uses \(name) for DNS.") {
            try await helper.setDNSServers(servers, service: service)
        }
        if done { dnsServers = servers }
        await refreshServiceSettings()
    }

    func flushDNS() async {
        await withHelper(since: stops, success: "DNS cache flushed.") { try await helper.flushDNSCache() }
    }

    // MARK: Resolvers

    /// Returns whether it was saved.
    @discardableResult
    func saveResolver(_ resolver: ResolverFile) async -> Bool {
        if let problem = resolver.problem {
            message = (problem, true)
            return false
        }
        let saved = await withHelper(
            since: stops, success: "Lookups for .\(resolver.domain) now go to \(resolver.nameservers.joined(separator: ", "))."
        ) {
            try await helper.setResolver(resolver)
        }
        resolvers = await reader.resolvers()
        return saved
    }

    func removeResolver(_ resolver: ResolverFile) async {
        guard resolver.isManaged else { return }
        await withHelper(since: stops) {
            try await helper.setResolver(ResolverFile(domain: resolver.domain, nameservers: []))
        }
        resolvers = await reader.resolvers()
    }

    // MARK: Proxies

    /// Sets one proxy's host and port and turns it on or off.
    func setProxy(_ server: ProxyServer) async {
        await applyProxy(ProxyChange(servers: [server], bypass: nil))
    }

    /// Points HTTP and HTTPS at a debugging proxy on this Mac.
    func useProxyPreset(_ preset: ProxyPreset) async {
        await applyProxy(
            ProxyChange(
                servers: [ProxyKind.web, .secureWeb].map { ProxyServer(kind: $0, host: "127.0.0.1", port: preset.port, isOn: true) },
                bypass: nil),
            success: "HTTP and HTTPS go through \(preset.name) on port \(preset.port).")
    }

    func setBypass(_ entries: [String]) async {
        await applyProxy(ProxyChange(servers: [], bypass: entries))
    }

    /// Turns every proxy off, or back on the ones the toggle turned off.
    func toggleProxy() async {
        await switchProxies(on: nil)
    }

    /// Turns every proxy off, even one switched on since the proxies were last read.
    func turnOffProxies() async {
        await switchProxies(on: false)
    }

    /// `on` nil flips them. Reads them first, as from a shortcut nothing may have read them yet,
    /// or they may have changed in System Settings.
    private func switchProxies(on: Bool?) async {
        let stops = stops
        await refreshForMenu()
        let turningOn = on ?? !proxies.isAnyOn
        let servers: [ProxyServer]
        if turningOn {
            // The ones the toggle last turned off, if they're still usable, else every usable one.
            let usable = proxies.usable
            let toggledOff = Set((defaults.stringArray(forKey: Self.toggledOffProxiesKey) ?? []).compactMap(ProxyKind.init(rawValue:)))
            let remembered = usable.filter { toggledOff.contains($0.kind) }
            servers = remembered.isEmpty ? usable : remembered
        } else {
            // Every one that's on, including one left without a host.
            servers = ProxyKind.allCases.map(proxies.server).filter(\.isOn)
            // Already off, as when it was turned off in System Settings meanwhile.
            if servers.isEmpty { return }
        }
        guard !servers.isEmpty else {
            message = ("Set a proxy's host and port first.", true)
            return
        }
        let change = servers.map {
            var server = $0
            server.isOn = turningOn
            return server
        }
        let applied = await applyProxy(ProxyChange(servers: change, bypass: nil), since: stops)
        // What to turn back on next time, kept only once they're off, so a failed try doesn't
        // lose the last list.
        if applied, !turningOn { defaults.set(servers.map(\.kind.rawValue), forKey: Self.toggledOffProxiesKey) }
    }

    /// `stops` is when the change was asked for, if that was before an await. Returns whether
    /// the helper made the change.
    @discardableResult
    private func applyProxy(_ change: ProxyChange, success: String? = nil, since stops: Int? = nil) async -> Bool {
        let stops = stops ?? self.stops
        guard let service else {
            message = ("There's no network service to set a proxy for.", true)
            return false
        }
        if let problem = change.problem {
            message = (problem, true)
            return false
        }
        let applied = await withHelper(since: stops, success: success) { try await helper.setProxy(change, service: service) }
        await refreshServiceSettings()
        return applied
    }
}
