import AppKit
import CoreAudio
import Foundation
import Observation

/// Sound devices and the microphone's mute, plus per-app volume and external displays' brightness and volume.
@Observable
final class DisplaysAudioController {
    /// Starts out unset; people pick their own keys.
    static let muteShortcut = ShortcutDefinition(
        id: "displaysAudio.toggleMicMute", module: .displaysAudio, title: "Mute or unmute the microphone", defaultHotKey: nil)
    static let nextOutputShortcut = ShortcutDefinition(
        id: "displaysAudio.nextOutput", module: .displaysAudio, title: "Switch to the next output", defaultHotKey: nil)
    static let brightnessUpShortcut = ShortcutDefinition(
        id: "displaysAudio.brightnessUp", module: .displaysAudio, title: "Brightness up", defaultHotKey: nil)
    static let brightnessDownShortcut = ShortcutDefinition(
        id: "displaysAudio.brightnessDown", module: .displaysAudio, title: "Brightness down", defaultHotKey: nil)

    private(set) var outputs: [AudioDevice] = []
    private(set) var inputs: [AudioDevice] = []
    private(set) var defaultOutput: AudioObjectID?
    private(set) var defaultInput: AudioObjectID?
    private(set) var isMicMuted = false
    /// Set when the microphone switched to couldn't be muted, so it's live although it was muted before.
    private(set) var muteProblem: String?

    let appVolume: AppVolumeController
    let externalDisplays: ExternalDisplaysController

    @ObservationIgnored private let devices: any AudioDeviceAccess
    @ObservationIgnored private var isRunning = false
    /// The input muted here, so switching inputs moves the mute along instead of leaving one muted out of sight.
    @ObservationIgnored private var mutedInput: AudioObjectID?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    init(
        devices: any AudioDeviceAccess, appVolume: AppVolumeController,
        externalDisplays: ExternalDisplaysController
    ) {
        self.devices = devices
        self.appVolume = appVolume
        self.externalDisplays = externalDisplays
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        devices.observe { [weak self] in self?.devicesChanged() }
        // A mute set elsewhere stays the user's: only one made here is undone when the module turns off.
        refresh()
        appVolume.start()
        externalDisplays.start()
        // The mute outlives the app, and the next launch wouldn't know it made it, so it's undone on quit.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Unmutes what it muted in this run, so turning the module off doesn't leave the microphone silent.
    func stop() {
        guard isRunning else { return }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
        // Only if it's still muted: unmuting a mic without a mute control sets its volume back.
        if let mutedInput, devices.isInputMuted(mutedInput) { devices.setInputMuted(false, mutedInput) }
        mutedInput = nil
        devices.stopObserving()
        appVolume.stop()
        externalDisplays.stop()
        isRunning = false
        outputs = []
        inputs = []
        defaultOutput = nil
        defaultInput = nil
        isMicMuted = false
        muteProblem = nil
    }

    func refresh() {
        guard isRunning else { return }
        let all = devices.devices()
        outputs = all.filter(\.hasOutput)
        inputs = all.filter(\.hasInput)
        defaultOutput = devices.defaultDevice(.output)
        defaultInput = devices.defaultDevice(.input)
        isMicMuted = defaultInput.map(devices.isInputMuted) ?? false
        // Unmuted somewhere else, such as in a call app or System Settings: it's no longer this app's mute.
        if let mutedInput, mutedInput == defaultInput, !isMicMuted { self.mutedInput = nil }
    }

    private func devicesChanged() {
        let previousInput = defaultInput
        refresh()
        // Unmuted elsewhere after being switched away from: there's no mute left to carry along.
        if let mutedInput, mutedInput != defaultInput, !devices.isInputMuted(mutedInput) { self.mutedInput = nil }
        // Keep the microphone muted across a switch to another input. The old one is only unmuted
        // once the new one is muted; if it can't be, say so rather than go live unnoticed.
        if let mutedInput, defaultInput != previousInput, defaultInput != mutedInput {
            if let defaultInput, devices.setInputMuted(true, defaultInput) {
                devices.setInputMuted(false, mutedInput)
                self.mutedInput = defaultInput
                muteProblem = nil
            } else if let input = currentInput {
                muteProblem = "\(input.name) can't be muted from here, so it's live."
            }
            refresh()
        } else if defaultInput == mutedInput {
            muteProblem = nil
        }
    }

    var currentOutput: AudioDevice? { outputs.first { $0.id == defaultOutput } }
    var currentInput: AudioDevice? { inputs.first { $0.id == defaultInput } }

    func select(_ device: AudioDevice, for direction: AudioDirection) {
        devices.setDefaultDevice(device.id, for: direction)
        devicesChanged()
    }

    func selectNextOutput() {
        guard !outputs.isEmpty else { return }
        let index = outputs.firstIndex { $0.id == defaultOutput }.map { ($0 + 1) % outputs.count } ?? 0
        select(outputs[index], for: .output)
    }

    /// Goes by the mute as it is now: it may have changed elsewhere since it was last shown.
    func toggleMicMute() {
        changeMute { !$0 }
    }

    func setMicMuted(_ muted: Bool) {
        changeMute { _ in muted }
    }

    /// `decide` gets the current mute, just read, and says what it should be.
    private func changeMute(_ decide: (Bool) -> Bool) {
        guard isRunning else { return }
        refresh()
        let muted = decide(isMicMuted)
        // Undo a mute left on a microphone switched away from.
        if !muted, let mutedInput, mutedInput != defaultInput {
            if devices.isInputMuted(mutedInput) { devices.setInputMuted(false, mutedInput) }
            self.mutedInput = nil
            muteProblem = nil
        }
        guard let input = defaultInput else { return }
        if devices.setInputMuted(muted, input) {
            mutedInput = muted ? input : nil
            muteProblem = nil
        } else if muted {
            muteProblem = "\(currentInput?.name ?? "This microphone") can't be muted from here."
        }
        refresh()
    }

    /// The default device's name: "Other device" when it's one that isn't offered for picking, such
    /// as a Multi-Output Device.
    func deviceName(_ direction: AudioDirection) -> String {
        let (current, id) = direction == .output ? (currentOutput, defaultOutput) : (currentInput, defaultInput)
        return current?.name ?? (id == nil ? "None" : "Other device")
    }
}
