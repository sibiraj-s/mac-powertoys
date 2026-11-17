import AppKit
import SwiftUI

struct NetworkSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case throttle, dns, proxy, info, usage

        var id: Self { self }

        var title: String {
            switch self {
            case .throttle: "Throttle"
            case .dns: "DNS"
            case .proxy: "Proxy"
            case .info: "Info"
            case .usage: "Usage"
            }
        }

        /// Changes made here go through the root helper.
        var usesHelper: Bool { self == .throttle || self == .dns || self == .proxy }
    }

    @AppStorage("network.tab") private var tab = Tab.throttle
    @Environment(AppState.self) private var state

    var body: some View {
        let network = state.network
        let isEnabled = state.isEnabled(.network)

        VStack(alignment: .leading, spacing: 16) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if let message = network.message {
                MessageBanner(message: message.text, isError: message.isError, dismiss: { network.dismissMessage() })
            } else if tab.usesHelper, !network.isHelperAllowed {
                HelperNotice()
            }

            Group {
                switch tab {
                case .throttle: ThrottleView()
                case .dns: DNSView()
                case .proxy: ProxyView()
                case .info: NetworkInfoView()
                case .usage: BandwidthView()
                }
            }
            .padding(.top, 4)
        }
        // Turning the module on refreshes from AppState, so this covers the pane opening.
        .task {
            if isEnabled { await network.refresh() }
        }
        // Coming back from System Settings, where the helper may just have been allowed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            network.refreshHelperStatus()
        }
    }
}

// MARK: - Shared pieces

/// One quiet line saying the helper still needs allowing.
private struct HelperNotice: View {
    var body: some View {
        Label {
            Text(
                "Changes here need administrator rights. The first one asks you to allow \(AppInfo.name) once under Login Items & Extensions in System Settings."
            )
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondaryText)
        .padding(.horizontal, 2)
    }
}

/// A row of figures across a card, such as download, upload and latency.
private struct StatStrip: View {
    struct Stat: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    let stats: [Stat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                VStack(alignment: .leading, spacing: 3) {
                    Text(stat.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                    Text(stat.value)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(alignment: .leading) {
                    if index > 0 { Rectangle().fill(Palette.divider).frame(width: 1) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider).frame(height: 1)
        }
    }
}

/// An icon, a title and a line under it, with an action on the right: the top of a card that
/// says what state something is in.
private struct StatusHeader<Action: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isOn: Bool
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Palette.secondaryText)
                .frame(width: 32, height: 32)
                .background(Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider).frame(height: 1)
        }
    }
}

/// Which network service DNS and proxy changes apply to.
private struct ServicePicker: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var network = state.network
        CardRow("Network service", hint: "Settings are kept for each service. Automatic follows the one macOS is using.") {
            Picker("Network service", selection: $network.chosenService) {
                Text("Automatic (\(network.primaryService ?? "none"))").tag(String?.none)
                Divider()
                ForEach(network.services) { service in
                    Text(service.isEnabled ? service.name : "\(service.name) (off)").tag(Optional(service.name))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

// MARK: - Throttle

private struct ThrottleView: View {
    @Environment(AppState.self) private var state
    @State private var editing: ProfileDraft?

    var body: some View {
        @Bindable var network = state.network
        let active = network.activeThrottle
        let shown = active?.profile ?? network.profile

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            CardSection {
                StatusHeader(symbol: "tortoise.fill", title: statusTitle, subtitle: statusSubtitle, isOn: active != nil) {
                    if active != nil {
                        Button("Stop") { Task { await network.stopThrottle() } }
                    } else {
                        Button("Start") { Task { await network.startThrottle() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .disabled(network.isBusy)
                StatStrip(stats: Self.stats(for: shown))
                CardRow("Profile") {
                    HStack(spacing: 4) {
                        Picker("Profile", selection: $network.profileID) {
                            ForEach(ThrottleProfile.builtIn) { Text($0.name).tag($0.id) }
                            if !network.customProfiles.isEmpty {
                                Divider()
                                ForEach(network.customProfiles) { Text($0.name).tag($0.id) }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Menu {
                            Button("New Profile…") { editing = ProfileDraft(copying: network.profile, isNew: true) }
                            if !network.profile.isBuiltIn {
                                Button("Edit Profile…") { editing = ProfileDraft(copying: network.profile, isNew: false) }
                                Divider()
                                Button("Delete Profile", role: .destructive) { network.deleteProfile(network.profile) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Profile options")
                    }
                }
                CardRow("Traffic", hint: scopeHint) {
                    Picker("Traffic", selection: $network.scope) {
                        ForEach(ThrottleScope.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if network.scope == .hosts {
                    FieldRow(title: "Hosts", text: $network.hostsText, prompt: "api.example.com 203.0.113.7")
                }
                if network.scope == .ports {
                    FieldRow(title: "Ports", text: $network.portsText, prompt: "443 8080")
                }
                if network.scope == .all || network.scope == .ports {
                    CardRow("Leave the local network alone", hint: "Devices and servers on your own network stay at full speed.") {
                        RowSwitch(label: "Leave the local network alone", isOn: $network.excludesLocalNetwork)
                    }
                }
                CardRow("Stops after", hint: "It also stops when \(AppInfo.name) quits.") {
                    Picker("Stops after", selection: $network.duration) {
                        ForEach(ThrottleDuration.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            CardSection("Shortcuts") {
                ShortcutRow(definition: NetworkController.toggleThrottleShortcut)
                ShortcutRow(definition: NetworkController.flushDNSShortcut)
                ShortcutRow(definition: NetworkController.toggleProxyShortcut)
            }
        }
        .sheet(item: $editing) { ProfileEditor(draft: $0) }
    }

    static func stats(for profile: ThrottleProfile) -> [StatStrip.Stat] {
        let roundTrip = profile.download.delayMilliseconds + profile.upload.delayMilliseconds
        let loss = max(profile.download.packetLoss, profile.upload.packetLoss)
        return [
            .init(title: "Download", value: ThrottleProfile.rate(profile.download.kilobitsPerSecond)),
            .init(title: "Upload", value: ThrottleProfile.rate(profile.upload.kilobitsPerSecond)),
            .init(title: "Added latency", value: roundTrip == 0 ? "None" : "\(roundTrip) ms"),
            .init(title: "Packet loss", value: loss == 0 ? "None" : ThrottleProfile.percent(loss)),
        ]
    }

    private var statusTitle: String {
        guard let active = state.network.activeThrottle else { return "Not throttling" }
        return "Throttling to \(active.profile.name)"
    }

    private var statusSubtitle: String {
        guard let active = state.network.activeThrottle else {
            return "Slow the whole Mac down like a worse connection, to see how apps and sites cope. Localhost is never slowed."
        }
        let scope = active.scope == .all ? "All traffic" : active.scope.title
        guard let endsAt = active.endsAt else { return "\(scope) · until you stop it" }
        return "\(scope) · stops at \(endsAt.formatted(date: .omitted, time: .shortened))"
    }

    private var scopeHint: String {
        switch state.network.scope {
        case .all: "Everything this Mac sends and receives."
        case .dns: "Only name lookups. Encrypted DNS and iCloud Private Relay aren't slowed."
        case .hosts: "Names are looked up when it starts. Sites behind a CDN may move to other addresses."
        case .ports: "Traffic to these ports on other machines, over TCP and UDP."
        }
    }
}

/// A titled text field taking the row's width.
private struct FieldRow: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        CardRow {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 13)).frame(width: 64, alignment: .leading)
                TextField(title, text: $text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
        } trailing: {
            EmptyView()
        }
    }
}

private struct ProfileDraft: Identifiable {
    let id: String
    let isNew: Bool
    var name: String
    var downloadKbps: String
    var uploadKbps: String
    var downloadDelay: String
    var uploadDelay: String
    var downloadLoss: String
    var uploadLoss: String

    init(copying profile: ThrottleProfile, isNew: Bool) {
        id = isNew ? UUID().uuidString : profile.id
        self.isNew = isNew
        name = isNew ? "\(profile.name) copy" : profile.name
        downloadKbps = profile.download.kilobitsPerSecond.map(String.init) ?? ""
        uploadKbps = profile.upload.kilobitsPerSecond.map(String.init) ?? ""
        downloadDelay = String(profile.download.delayMilliseconds)
        uploadDelay = String(profile.upload.delayMilliseconds)
        downloadLoss = Self.percent(profile.download.packetLoss)
        uploadLoss = Self.percent(profile.upload.packetLoss)
    }

    private static func percent(_ fraction: Double) -> String {
        let percent = fraction * 100
        return percent == percent.rounded() ? String(Int(percent)) : String(percent)
    }

    /// The profile, or nil while something doesn't read as a number in range.
    var profile: ThrottleProfile? {
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }
        func rate(_ text: String) -> Int?? {
            trimmed(text).isEmpty ? .some(nil) : Int(trimmed(text)).map { .some($0) }
        }
        let name = trimmed(name)
        guard !name.isEmpty, let down = rate(downloadKbps), let up = rate(uploadKbps),
            let downDelay = Int(trimmed(downloadDelay)), let upDelay = Int(trimmed(uploadDelay)),
            let downLoss = Double(trimmed(downloadLoss).isEmpty ? "0" : trimmed(downloadLoss)),
            let upLoss = Double(trimmed(uploadLoss).isEmpty ? "0" : trimmed(uploadLoss))
        else { return nil }
        let profile = ThrottleProfile(
            id: id, name: name,
            download: ThrottleLink(kilobitsPerSecond: down, delayMilliseconds: downDelay, packetLoss: downLoss / 100),
            upload: ThrottleLink(kilobitsPerSecond: up, delayMilliseconds: upDelay, packetLoss: upLoss / 100))
        return profile.download.isValid && profile.upload.isValid ? profile : nil
    }
}

private struct ProfileEditor: View {
    @State var draft: ProfileDraft

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NetworkEditorSheet(
            title: draft.isNew ? "New Profile" : "Edit Profile",
            problem: draft.profile == nil
                ? "Speeds are in Kbps (empty for no limit), delays in ms up to 10,000, loss from 0 to 100%." : nil,
            saveTitle: draft.isNew ? "Create" : "Save",
            canSave: draft.profile != nil
        ) {
            guard let profile = draft.profile else { return }
            state.network.saveProfile(profile)
            dismiss()
        } content: {
            Form {
                TextField("Name", text: $draft.name, prompt: Text("Hotel Wi‑Fi"))
                Section {
                    TextField("Download (Kbps)", text: $draft.downloadKbps, prompt: Text("No limit"))
                    TextField("Upload (Kbps)", text: $draft.uploadKbps, prompt: Text("No limit"))
                }
                Section {
                    TextField("Download delay (ms)", text: $draft.downloadDelay, prompt: Text("0"))
                    TextField("Upload delay (ms)", text: $draft.uploadDelay, prompt: Text("0"))
                    TextField("Download loss (%)", text: $draft.downloadLoss, prompt: Text("0"))
                    TextField("Upload loss (%)", text: $draft.uploadLoss, prompt: Text("0"))
                }
            }
        }
    }
}

// MARK: - DNS

private struct DNSView: View {
    @Environment(AppState.self) private var state
    /// Custom picked in the menu, before its servers are applied.
    @State private var isEnteringCustom = false
    @State private var customServers = ""
    @State private var editingResolver: ResolverDraft?

    private static let customTag = "custom"

    var body: some View {
        let network = state.network
        let preset = network.dnsPreset
        let showsCustom = isEnteringCustom || preset == nil

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            CardSection("DNS") {
                ServicePicker()
                CardRow("Servers", hint: serversHint) {
                    Picker(
                        "Servers",
                        selection: Binding(
                            get: { showsCustom ? Self.customTag : preset?.id ?? Self.customTag },
                            set: { choose($0) })
                    ) {
                        ForEach(DNSPreset.all) { Text($0.name).tag($0.id) }
                        Divider()
                        Text("Custom…").tag(Self.customTag)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if showsCustom {
                    CardRow {
                        HStack(spacing: 12) {
                            Text("Custom").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                            TextField("Custom servers", text: $customServers, prompt: Text("192.168.1.2 1.1.1.1"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .onSubmit(applyCustom)
                        }
                    } trailing: {
                        Button("Apply", action: applyCustom)
                            .disabled(listItems(customServers).isEmpty || listItems(customServers) == network.dnsServers)
                    }
                }
                CardRow("Flush the DNS cache", hint: "Forgets looked-up addresses, so changes to DNS or /etc/hosts show at once.") {
                    Button("Flush") { Task { await network.flushDNS() } }
                }
            }
            .disabled(network.isBusy)

            CardSection("Resolvers") {
                CardRow(
                    "Per-domain resolvers",
                    hint: "Send lookups for a domain and everything under it elsewhere, such as .test to a local DNS server."
                ) {
                    Button("Add…") { editingResolver = ResolverDraft() }
                }
                ForEach(network.resolvers, id: \.domain) { resolver in
                    ResolverRow(resolver: resolver) { editingResolver = ResolverDraft(editing: resolver) }
                }
            }
            .disabled(network.isBusy)
        }
        .sheet(item: $editingResolver) { ResolverEditor(draft: $0) }
        .onAppear { customServers = network.dnsServers.joined(separator: " ") }
        .onChange(of: network.dnsServers) { _, servers in
            if !isEnteringCustom { customServers = servers.joined(separator: " ") }
        }
    }

    private var serversHint: String {
        let network = state.network
        if let preset = network.dnsPreset, !isEnteringCustom {
            return preset.servers.isEmpty ? "The servers your router or VPN gives out." : preset.servers.joined(separator: ", ")
        }
        return "Your own servers, such as a Pi-hole, separated by spaces."
    }

    private func choose(_ id: String) {
        if id == Self.customTag {
            isEnteringCustom = true
            return
        }
        isEnteringCustom = false
        guard let preset = DNSPreset.all.first(where: { $0.id == id }), preset != state.network.dnsPreset else { return }
        Task { await state.network.setDNSServers(preset.servers) }
    }

    private func applyCustom() {
        let servers = listItems(customServers)
        guard !servers.isEmpty else { return }
        Task {
            await state.network.setDNSServers(servers)
            isEnteringCustom = false
        }
    }
}

private struct ResolverRow: View {
    let resolver: ResolverFile
    let edit: () -> Void

    @Environment(AppState.self) private var state

    var body: some View {
        CardRow {
            HStack(spacing: 12) {
                Text(".\(resolver.domain)")
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 64, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondaryText)
                Text(destination)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } trailing: {
            if resolver.isManaged {
                HStack(spacing: 10) {
                    Button(action: edit) { Image(systemName: "pencil") }
                        .help("Edit")
                    Button {
                        Task { await state.network.removeResolver(resolver) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove")
                }
                .buttonStyle(.borderless)
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .help("Made by another app or by hand, so \(AppInfo.name) leaves it alone")
            }
        }
    }

    private var destination: String {
        let servers = resolver.nameservers.joined(separator: ", ")
        return resolver.port.map { "\(servers) : \($0)" } ?? servers
    }
}

private struct ResolverDraft: Identifiable {
    let id = UUID()
    let isNew: Bool
    var domain: String
    var nameservers: String
    var port: String

    init(editing resolver: ResolverFile? = nil) {
        isNew = resolver == nil
        domain = resolver?.domain ?? ""
        nameservers = resolver?.nameservers.joined(separator: " ") ?? "127.0.0.1"
        port = resolver?.port.map(String.init) ?? ""
    }

    var resolver: ResolverFile {
        let domain = domain.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return ResolverFile(domain: domain, nameservers: listItems(nameservers), port: Int(port.trimmingCharacters(in: .whitespaces)))
    }

    var problem: String? {
        let port = port.trimmingCharacters(in: .whitespaces)
        if !port.isEmpty, Int(port) == nil { return "The port is a number, such as 5353." }
        return resolver.problem
    }
}

private struct ResolverEditor: View {
    @State var draft: ResolverDraft

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NetworkEditorSheet(
            title: draft.isNew ? "Add Resolver" : "Edit Resolver",
            problem: draft.domain.isEmpty ? nil : draft.problem,
            saveTitle: draft.isNew ? "Add" : "Save",
            canSave: draft.problem == nil
        ) {
            if await state.network.saveResolver(draft.resolver) { dismiss() }
        } content: {
            Form {
                TextField("Domain", text: $draft.domain, prompt: Text("test"))
                    .disabled(!draft.isNew)
                TextField("Name servers", text: $draft.nameservers, prompt: Text("127.0.0.1"))
                TextField("Port", text: $draft.port, prompt: Text("53"))
            }
        }
    }
}

// MARK: - Proxy

private struct ProxyView: View {
    @Environment(AppState.self) private var state
    @State private var bypass = ""

    var body: some View {
        let network = state.network
        let on = network.proxies.configured.filter(\.isOn)

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            CardSection {
                StatusHeader(
                    symbol: "arrow.triangle.branch",
                    title: on.isEmpty ? "No proxy" : "Proxy on",
                    subtitle: on.isEmpty
                        ? "Traffic goes straight out. Point it at a debugging proxy to inspect requests. One on this Mac turns off again when \(AppInfo.name) quits."
                        : on.map { "\($0.kind.title) → \($0.host):\(String($0.port))" }.joined(separator: " · "),
                    isOn: !on.isEmpty
                ) {
                    HStack(spacing: 8) {
                        Menu("Use App") {
                            ForEach(ProxyPreset.all) { preset in
                                Button("\(preset.name) (port \(String(preset.port)))") {
                                    Task { await network.useProxyPreset(preset) }
                                }
                            }
                        }
                        .fixedSize()
                        if !on.isEmpty {
                            Button("Turn Off") { Task { await network.turnOffProxies() } }
                        }
                    }
                }
                ServicePicker()
                ForEach(ProxyKind.allCases, id: \.self) { kind in
                    ProxyRow(kind: kind)
                }
            }
            .disabled(network.isBusy)

            CardSection("Bypass") {
                CardRow {
                    HStack(spacing: 12) {
                        Text("Skip for").font(.system(size: 13)).frame(width: 64, alignment: .leading)
                        TextField("Bypass", text: $bypass, prompt: Text("*.local 169.254/16"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                } trailing: {
                    Button("Save") { Task { await network.setBypass(listItems(bypass)) } }
                        .disabled(listItems(bypass) == network.proxies.bypass)
                }
            }
            .disabled(network.isBusy)
        }
        .onAppear { bypass = network.proxies.bypass.joined(separator: " ") }
        .onChange(of: network.proxies.bypass) { _, entries in bypass = entries.joined(separator: " ") }
    }
}

private struct ProxyRow: View {
    let kind: ProxyKind

    @Environment(AppState.self) private var state
    @State private var host = ""
    @State private var port = ""

    var body: some View {
        let server = state.network.proxies.server(kind)
        CardRow {
            HStack(spacing: 12) {
                Text(kind.title)
                    .font(.system(size: 13))
                    .frame(width: 64, alignment: .leading)
                TextField("\(kind.title) host", text: $host, prompt: Text("Host"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Text(":").foregroundStyle(Palette.secondaryText)
                TextField("\(kind.title) port", text: $port, prompt: Text("Port"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 64)
            }
        } trailing: {
            RowSwitch(
                label: "\(kind.title) proxy",
                isOn: Binding(
                    get: { server.isOn },
                    set: { on in
                        let change = ProxyServer(
                            kind: kind, host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 0, isOn: on)
                        Task { await state.network.setProxy(change) }
                    }))
        }
        .onAppear(perform: load)
        .onChange(of: server) { load() }
    }

    private func load() {
        let server = state.network.proxies.server(kind)
        host = server.host
        port = server.port > 0 ? String(server.port) : ""
    }
}

// MARK: - Info

private struct NetworkInfoView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let info = state.networkInfo
        let snapshot = info.snapshot
        let isEnabled = state.isEnabled(.network)

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            CardSection {
                StatusHeader(
                    symbol: snapshot.wifi != nil ? "wifi" : "network",
                    title: snapshot.serviceName ?? "Not connected",
                    subtitle: connectionSubtitle(snapshot),
                    isOn: snapshot.serviceName != nil
                ) { EmptyView() }
                InfoRow("IPv4 address", snapshot.ipv4.joined(separator: ", "))
                if !snapshot.ipv6.isEmpty { InfoRow("IPv6 address", snapshot.ipv6.joined(separator: ", ")) }
                InfoRow("Router", snapshot.router ?? "")
                InfoRow("DNS servers", snapshot.dnsServers.joined(separator: ", "))
                InfoRow("Tunnels", snapshot.tunnels.isEmpty ? "None" : snapshot.tunnels.joined(separator: ", "))
            }

            if let wifi = snapshot.wifi {
                CardSection("Wi‑Fi") {
                    StatStrip(stats: [
                        .init(title: "Signal", value: "\(wifi.quality) · \(wifi.rssi) dBm"),
                        .init(title: "Noise", value: "\(wifi.noise) dBm"),
                        .init(title: "Channel", value: Self.channel(wifi)),
                        .init(title: "Link speed", value: "\(Int(wifi.transmitRate)) Mbps"),
                    ])
                    if let name = wifi.networkName {
                        InfoRow("Network", name)
                    } else {
                        CardRow(
                            "Network name",
                            hint: info.isWiFiNameDenied
                                ? "macOS shows it only to apps allowed under Location Services in System Settings."
                                : "macOS shows it only to apps allowed to use Location. Nothing else is read."
                        ) {
                            if info.canAskForWiFiName {
                                Button("Show Name") { info.requestWiFiName() }
                            }
                        }
                    }
                }
            }

            CardSection("Internet") {
                if let result = info.speedTest {
                    StatStrip(stats: [
                        .init(title: "Download", value: SpeedTestResult.megabits(result.download)),
                        .init(title: "Upload", value: SpeedTestResult.megabits(result.upload)),
                        .init(title: "Responsiveness", value: Self.responsiveness(result)),
                        .init(title: "Idle latency", value: result.idleLatency.map { "\(Int($0.rounded())) ms" } ?? "–"),
                    ])
                }
                CardRow(
                    info.isTestingSpeed ? "Testing speed…" : "Speed test",
                    hint: info.speedTestProblem ?? "Apple's networkQuality test. Takes about 20 seconds and uses some data."
                ) {
                    if info.isTestingSpeed {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { info.cancelSpeedTest() }
                        }
                    } else {
                        Button(info.speedTest == nil ? "Run" : "Run Again") { info.runSpeedTest() }
                    }
                }
                CardRow(
                    "Public address",
                    hint: info.addressProblem
                        ?? (info.publicAddress == nil
                            ? "Asks Cloudflare which address sites see. Only when you click." : nil)
                ) {
                    HStack(spacing: 10) {
                        if let address = info.publicAddress {
                            Text(address.address + (address.country.map { " · \($0)" } ?? ""))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Palette.secondaryText)
                                .textSelection(.enabled)
                        }
                        Button(info.publicAddress == nil ? "Look Up" : "Again") { Task { await info.lookUpPublicAddress() } }
                            .disabled(info.isLookingUpAddress)
                    }
                }
            }
        }
        .task(id: isEnabled) {
            if isEnabled { await info.watch() }
        }
    }

    static func channel(_ wifi: WiFiDetails) -> String {
        [wifi.channel.map { String($0) }, wifi.band].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Medium · 640", the rating and round trips a minute.
    static func responsiveness(_ result: SpeedTestResult) -> String {
        guard let rating = result.responsivenessRating, let rpm = result.responsiveness else { return "–" }
        return "\(rating) · \(Int(rpm))"
    }

    private func connectionSubtitle(_ snapshot: NetworkSnapshot) -> String {
        guard snapshot.serviceName != nil else { return "No network service is carrying traffic." }
        var parts = [snapshot.interface.map { "Interface \($0)" }]
        if !snapshot.tunnels.isEmpty { parts.append("VPN or tunnel up") }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// A label and a value that can be selected and copied.
private struct InfoRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        CardRow(title) {
            Text(value.isEmpty ? "–" : value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.secondaryText)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .contextMenu {
            if !value.isEmpty { Button("Copy") { NSPasteboard.general.copy(value) } }
        }
    }
}

// MARK: - Usage

private struct BandwidthView: View {
    static let limit = 30
    static let rateWidth: CGFloat = 84

    @Environment(AppState.self) private var state

    var body: some View {
        let bandwidth = state.bandwidth
        let isEnabled = state.isEnabled(.network)

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            CardSection {
                StatStrip(stats: [
                    .init(title: "Download", value: NetworkSpeedMonitor.detailed(bandwidth.totalDownload)),
                    .init(title: "Upload", value: NetworkSpeedMonitor.detailed(bandwidth.totalUpload)),
                    .init(title: "Apps", value: String(bandwidth.usage.count)),
                ])
                // Column headings, lined up with the rates below.
                HStack(spacing: 12) {
                    Text("App").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Download").frame(width: Self.rateWidth, alignment: .trailing)
                    Text("Upload").frame(width: Self.rateWidth, alignment: .trailing)
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.divider).frame(height: 1) }
                if let problem = bandwidth.problem {
                    CardRow(problem, hint: nil) { EmptyView() }
                } else if !bandwidth.isLoaded {
                    CardRow("Measuring…", hint: nil) { ProgressView().controlSize(.small) }
                } else if bandwidth.usage.isEmpty {
                    CardRow("Nothing is using the network", hint: nil) { EmptyView() }
                }
                ForEach(bandwidth.usage.prefix(Self.limit)) { usage in
                    HStack(spacing: 12) {
                        HStack(spacing: 10) {
                            ProcessIcon(pid: usage.pid, size: 18)
                            Text(usage.name)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("PID \(String(usage.pid))")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.secondaryText)
                                .fixedSize()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        RateText(symbol: "arrow.down", rate: usage.download, width: Self.rateWidth)
                        RateText(symbol: "arrow.up", rate: usage.upload, width: Self.rateWidth)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.divider).frame(height: 1) }
                }
            }

            CardSection("Menu bar") {
                CardRow(
                    "Show speed in the menu bar",
                    hint: "Upload and download speed as its own item beside \(AppInfo.name)'s icon. Click it to see the busiest apps."
                ) {
                    RowSwitch(
                        label: "Show speed in the menu bar",
                        isOn: Binding(get: { state.networkSpeed.showsInMenuBar }, set: { state.setShowsNetworkSpeed($0) }))
                }
            }
        }
        .task(id: isEnabled) {
            if isEnabled { await bandwidth.watch() }
        }
    }
}

// MARK: - Sheets

/// A small sheet with a form, a problem line, and Cancel and Save buttons.
private struct NetworkEditorSheet<Content: View>: View {
    let title: String
    let problem: String?
    let saveTitle: String
    let canSave: Bool
    let save: () async -> Void
    @ViewBuilder let content: Content

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content
                .controlSize(.regular)
            Text(problem ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if state.network.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || state.network.isBusy)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
