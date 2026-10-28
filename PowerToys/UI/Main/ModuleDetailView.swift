import SwiftUI

struct ModuleDetailView: View {
    let module: ModuleDescriptor

    @Environment(AppState.self) private var state

    var body: some View {
        Page {
            PageHeader(symbol: module.symbol, title: module.name, summary: module.summary) {
                ForEach(module.permissions) { permission in
                    PermissionBadge(permission: permission, status: state.permissions.status(permission))
                }
            } trailing: {
                HStack(spacing: 10) {
                    Text("Enabled").font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                    RowSwitch(label: "Enable \(module.name)", isOn: state.binding(for: module.id))
                }
            }

            if module.isImplemented {
                settings
                    .disabled(!state.isEnabled(module.id))
                if module.id == .awake {
                    VigilSection()
                }
            } else {
                CardSection {
                    CardRow("Not built yet", hint: "Today people use \(module.replaces).") {
                        Image(systemName: "hammer").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var settings: some View {
        switch module.id {
        case .awake: AwakeSettingsView()
        case .zones: ZonesSettingsView()
        case .clipboard: ClipboardSettingsView()
        case .systemToggles: SystemTogglesSettingsView()
        case .hostsEnv: HostsEnvSettingsView()
        case .portsProcesses: PortsSettingsView()
        case .launchAgents: LaunchAgentsSettingsView()
        case .colorPicker: ColorPickerSettingsView()
        case .defaultsBrowser: DefaultsBrowserSettingsView()
        default: EmptyView()
        }
    }
}

// MARK: - Awake

private struct AwakeSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var untilTime = Date.now.addingTimeInterval(60 * 60)

    var body: some View {
        @Bindable var awake = state.awake

        CardSection("Keep awake") {
            CardRow("Status", hint: statusText) {
                Button("Stop") { awake.stop() }
                    .disabled(!awake.isActive)
            }
            CardRow("For", hint: "Starts now and ends after the chosen time.") {
                HStack(spacing: 6) {
                    ForEach(AwakeController.Duration.allCases) { duration in
                        Button(duration.title) { awake.start(duration) }
                    }
                }
            }
            CardRow("Until", hint: "Ends at this time today, or tomorrow if it has passed.") {
                HStack(spacing: 6) {
                    DatePicker("Until", selection: $untilTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Button("Start") { awake.start(untilTimeOfDay: untilTime) }
                }
            }
        }

        CardSection("Behavior") {
            CardRow("Keep the display on", hint: "Otherwise the display can sleep while the Mac stays awake.") {
                RowSwitch(label: "Keep the display on", isOn: $awake.keepsDisplayOn)
            }
        }

        CardSection("Shortcuts") {
            ShortcutRow(definition: AwakeController.toggleShortcut)
        }
    }

    private var statusText: String {
        let awake = state.awake
        guard awake.isActive else { return "Off" }
        guard let endsAt = awake.endsAt else { return "Awake until you stop it" }
        let style: Date.FormatStyle = endsAt.timeIntervalSinceNow > 12 * 60 * 60
            ? .dateTime.weekday().hour().minute()
            : .dateTime.hour().minute()
        return "Awake until \(endsAt.formatted(style))"
    }
}

private struct VigilSection: View {
    @State private var isInstalled = Vigil.installedURL != nil
    @State private var isRunning = Vigil.isRunning

    var body: some View {
        CardSection("Need more?") {
            CardRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vigil keeps your Mac awake automatically").font(.system(size: 13))
                    ForEach(Vigil.features, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if isRunning {
                        Label("Vigil is running. Use one or the other so two apps aren't holding the Mac awake.", systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .padding(.top, 4)
                    }
                }
            } trailing: {
                Button(isInstalled ? "Open Vigil" : "Get Vigil") { Vigil.open() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isInstalled = Vigil.installedURL != nil
            isRunning = Vigil.isRunning
        }
    }
}
