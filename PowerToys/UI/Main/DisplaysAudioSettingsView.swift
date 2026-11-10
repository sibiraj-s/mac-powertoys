import CoreAudio
import SwiftUI

struct DisplaysAudioSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let audio = state.displaysAudio

        CardSection("Sound") {
            DevicePickerRow(title: "Output", devices: audio.outputs, selection: audio.defaultOutput) {
                audio.select($0, for: .output)
            }
            DevicePickerRow(title: "Input", devices: audio.inputs, selection: audio.defaultInput) {
                audio.select($0, for: .input)
            }
            CardRow("Mute microphone", hint: audio.muteProblem ?? "Stays muted when you switch to another microphone.") {
                RowSwitch(label: "Mute microphone", isOn: Binding(get: { audio.isMicMuted }, set: { audio.setMicMuted($0) }))
                    .disabled(audio.defaultInput == nil)
            }
        }
        // Devices also change in Control Center and when headphones connect; read them again here.
        .onAppear { audio.refresh() }

        MultiOutputSection()

        AppVolumeSection()

        DisplaysSection()

        CardSection("Shortcuts") {
            ShortcutRow(definition: DisplaysAudioController.muteShortcut)
            ShortcutRow(definition: DisplaysAudioController.nextOutputShortcut)
            ShortcutRow(definition: DisplaysAudioController.brightnessUpShortcut)
            ShortcutRow(definition: DisplaysAudioController.brightnessDownShortcut)
        }
    }
}

private struct DevicePickerRow: View {
    let title: String
    let devices: [AudioDevice]
    let selection: AudioObjectID?
    let select: (AudioDevice) -> Void

    var body: some View {
        CardRow(title) {
            Picker(
                title,
                selection: Binding(
                    get: { devices.contains { $0.id == selection } ? selection ?? 0 : 0 },
                    set: { id in devices.first { $0.id == id }.map(select) })
            ) {
                // The default can be one that isn't offered, such as a Multi-Output Device.
                if !devices.contains(where: { $0.id == selection }) {
                    Text(selection == nil ? "None" : "Other device").tag(AudioObjectID(0))
                }
                ForEach(devices) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Outputs playing the same sound at once, like a Multi-Output Device in Audio MIDI Setup.
private struct MultiOutputSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let audio = state.displaysAudio
        CardSection("Play together") {
            CardRow(
                "Play on several outputs at once",
                hint: audio.multiOutputProblem
                    ?? "Turn on two or more, such as two pairs of Bluetooth headphones. They play as one output, \(AppInfo.name) Multi-Output, which has no volume of its own, so each has its own here, and the volume keys change them all with Use volume keys under Displays. Wireless ones may lag a little behind wired ones."
            ) { EmptyView() }
            if audio.disconnectedMultiOutputMembers > 0 {
                let count = audio.disconnectedMultiOutputMembers
                CardRow(
                    count == 1 ? "1 output isn't connected" : "\(count) outputs aren't connected",
                    hint: "They play again once they're back. Changing the outputs here leaves them out."
                ) { EmptyView() }
            }
            ForEach(audio.multiOutputCandidates) { device in
                let isOn = audio.multiOutputMembers.contains(device.uid)
                CardRow(device.name) {
                    HStack(spacing: 8) {
                        if isOn, let volume = audio.outputVolumes[device.id] {
                            Slider(
                                value: Binding(get: { Double(volume) }, set: { audio.setOutputVolume(Float($0), for: device) }), in: 0...1
                            )
                            .controlSize(.small)
                            .frame(width: 160)
                            .accessibilityLabel("\(device.name) volume")
                        }
                        RowSwitch(
                            label: "Play through \(device.name)",
                            isOn: Binding(get: { isOn }, set: { audio.setPlaysTogether($0, device) }))
                    }
                }
            }
        }
    }
}

private struct AppVolumeSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let appVolume = state.displaysAudio.appVolume
        CardSection("App volume") {
            if appVolume.apps.isEmpty {
                CardRow("No apps are playing sound", hint: "Apps show up here while they play, and stay once you change their volume.") {
                    EmptyView()
                }
            }
            ForEach(appVolume.apps) { app in
                AppVolumeRow(app: app)
            }
        }
        // Core Audio doesn't say when an app starts or stops playing; look again every few seconds.
        .task {
            while !Task.isCancelled {
                appVolume.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct AppVolumeRow: View {
    let app: AudioApp

    @Environment(AppState.self) private var state

    var body: some View {
        let appVolume = state.displaysAudio.appVolume
        let setting = appVolume.setting(for: app)
        CardRow {
            HStack(spacing: 10) {
                ProcessIcon(pid: app.pid, size: 20)
                RowLabel(title: app.name, hint: appVolume.errors[app.id])
            }
        } trailing: {
            HStack(spacing: 8) {
                Button {
                    appVolume.setMuted(!setting.isMuted, for: app)
                } label: {
                    Image(systemName: setting.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(setting.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
                Slider(
                    value: Binding(get: { Double(setting.volume) }, set: { appVolume.setVolume(Float($0), for: app) }),
                    in: 0...1
                )
                .controlSize(.small)
                .frame(width: 160)
                .disabled(setting.isMuted)
                .accessibilityLabel("\(app.name) volume")
                Text("\(Int((setting.volume * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}

private struct DisplaysSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let displays = state.displaysAudio.externalDisplays
        CardSection("Displays") {
            KeysRow(
                title: "Use brightness keys",
                warning: displays.brightnessKeysWarning,
                hint:
                    "The keyboard's brightness keys change the external display the pointer is on; elsewhere they work as usual. With more than one external display, they all change. Needs Accessibility.",
                isOn: Binding(get: { displays.usesBrightnessKeys }, set: { displays.usesBrightnessKeys = $0 }))
            KeysRow(
                title: "Use volume keys",
                warning: displays.volumeKeysWarning,
                hint:
                    "While sound plays through a display's speakers or \(AppInfo.name) Multi-Output, which macOS can't change the volume of, the volume and mute keys change the display's own volume or each output's. Elsewhere they work as usual. Needs Accessibility.",
                isOn: Binding(get: { displays.usesVolumeKeys }, set: { displays.usesVolumeKeys = $0 }))
            if displays.isLoaded, displays.displays.isEmpty {
                CardRow(
                    "No external displays to control",
                    hint:
                        "Brightness works over DDC with displays connected to an Apple silicon Mac. Built-in displays, AirPlay and some docks and adapters don't support it."
                ) { EmptyView() }
            }
            ForEach(displays.displays) { display in
                CardRow(
                    display.name, hint: display.brightness == nil ? "Doesn't report its brightness; it may not support DDC." : nil
                ) {
                    LevelSlider(
                        label: "\(display.name) brightness", low: "sun.min", high: "sun.max", value: display.brightness,
                        set: { displays.setBrightness($0, for: display) })
                }
                if let volume = display.volume {
                    CardRow("\(display.name) speakers") {
                        LevelSlider(
                            label: "\(display.name) volume", low: display.isMuted ? "speaker.slash" : "speaker",
                            high: "speaker.wave.3", value: display.isMuted ? 0 : volume,
                            set: { displays.setVolume($0, for: display) })
                    }
                }
            }
        }
        .task { await displays.load() }
    }
}

/// A switch for keys that need Accessibility, which is asked for when it's turned on.
private struct KeysRow: View {
    let title: String
    /// Said in place of the hint while another app may take the keys.
    let warning: String?
    let hint: String
    let isOn: Binding<Bool>

    @Environment(AppState.self) private var state

    var body: some View {
        CardRow(title, hint: warning ?? hint) {
            RowSwitch(
                label: title,
                isOn: Binding(
                    get: { isOn.wrappedValue },
                    set: { on in
                        isOn.wrappedValue = on
                        if on, state.permissions.currentStatus(.accessibility) != .granted {
                            state.permissions.request(.accessibility)
                        }
                    }))
        }
    }
}

/// A small slider between two symbols, turned off while there's no value to show.
private struct LevelSlider: View {
    let label: String
    let low: String
    let high: String
    let value: Double?
    let set: @MainActor @Sendable (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: low).foregroundStyle(.secondary).frame(width: 16)
            Slider(value: Binding(get: { value ?? 0.5 }, set: set), in: 0...1)
                .controlSize(.small)
                .frame(width: 160)
                .disabled(value == nil)
                .accessibilityLabel(label)
            Image(systemName: high).foregroundStyle(.secondary).frame(width: 16)
        }
    }
}
