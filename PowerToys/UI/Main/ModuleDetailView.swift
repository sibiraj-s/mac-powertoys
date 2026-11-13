import SwiftUI

struct ModuleDetailView: View {
    let module: ModuleDescriptor

    @Environment(AppState.self) private var state

    var body: some View {
        Page {
            PageHeader(symbol: module.symbol, title: module.name, summary: module.summary) {
                ForEach(module.permissions) { permission in
                    let status = state.permissions.status(permission)
                    if status == .denied, permission.settingsURL != nil {
                        Button {
                            state.permissions.request(permission)
                        } label: {
                            PermissionBadge(permission: permission, status: status)
                        }
                        .buttonStyle(.plain)
                        .help("Grant \(permission.title) access")
                    } else {
                        PermissionBadge(permission: permission, status: status)
                    }
                }
            } trailing: {
                HStack(spacing: 10) {
                    Text("Enabled").font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                    RowSwitch(label: "Enable \(module.name)", isOn: state.binding(for: module.id))
                }
            }

            if let rival = AppState.rival(of: module.id), state.isEnabled(rival), !state.isEnabled(module.id) {
                let other = ModuleCatalog.descriptor(rival).name
                MessageBanner(
                    message:
                        "\(other) is on. Both arrange windows, so only one can be on: turning \(module.name) on turns \(other) off.",
                    isError: true, dismiss: nil)
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
        case .lanes: LanesSettingsView()
        case .clipboard: ClipboardSettingsView()
        case .systemToggles: SystemTogglesSettingsView()
        case .hostsEnv: HostsEnvSettingsView()
        case .portsProcesses: PortsSettingsView()
        case .launchAgents: LaunchAgentsSettingsView()
        case .colorPicker: ColorPickerSettingsView()
        case .textExtractor: TextExtractorSettingsView()
        case .defaultsBrowser: DefaultsBrowserSettingsView()
        case .scrollMouse: ScrollMouseSettingsView()
        case .keys: KeysSettingsView()
        case .cleaner: CleanerSettingsView()
        case .apps: AppsSettingsView()
        case .pinCrop: PinCropSettingsView()
        case .windowSwitcher: WindowSwitcherSettingsView()
        case .displaysAudio: DisplaysAudioSettingsView()
        case .batchRename: BatchRenameSettingsView()
        case .fileLocksmith: FileLocksmithSettingsView()
        case .finderExtras: FinderExtrasSettingsView()
        case .screenRuler: ScreenRulerSettingsView()
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
                Button("Stop") { awake.turnOff() }
                    .disabled(!awake.isKeepingAwake)
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
            if awake.isLaptop {
                CardRow(
                    "While a display is connected",
                    hint: "Stays awake whenever an external display is plugged in. Stop pauses this until the display is unplugged."
                ) {
                    RowSwitch(label: "While a display is connected", isOn: $awake.whileDisplayConnected)
                }
                CardRow(
                    "With the lid closed",
                    hint: awake.lidClosedProblem
                        ?? (awake.isLidClosedPausedForBattery
                            ? "Paused: the battery is below \(AwakeController.lowBatteryPercent)%, so the Mac sleeps when its lid closes. Plug in to resume."
                            : "Keeps working with the lid closed, even on battery, until it drops below \(AwakeController.lowBatteryPercent)%. Needs a helper you allow once in System Settings. Don't pack the Mac in a bag while it's on: it can overheat.")
                ) {
                    RowSwitch(
                        label: "With the lid closed",
                        isOn: Binding(
                            get: { awake.keepsAwakeWithLidClosed },
                            set: { awake.setKeepsAwakeWithLidClosed($0) }
                        ))
                }
            }
        }

        CardSection("Shortcuts") {
            ShortcutRow(definition: AwakeController.toggleShortcut)
        }
    }

    private var statusText: String {
        let awake = state.awake
        guard awake.isActive else {
            if awake.isHeldByDisplay { return "Awake while a display is connected" }
            return awake.isDisplayHoldPaused ? "Paused until the display is unplugged" : "Off"
        }
        guard let endsAt = awake.endsAt else { return "Awake until you stop it" }
        let style: Date.FormatStyle =
            endsAt.timeIntervalSinceNow > 12 * 60 * 60
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
                        Label(
                            "Vigil is running. Use one or the other so two apps aren't holding the Mac awake.", systemImage: "info.circle"
                        )
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
