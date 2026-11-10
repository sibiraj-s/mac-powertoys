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
    /// The outputs picked to play together, by UID. With two or more, they're the multi-output
    /// device's; a single pick waits here for a second.
    private(set) var multiOutputMembers: [String] = []
    /// Set when the multi-output device couldn't be made.
    private(set) var multiOutputProblem: String?
    /// The volumes of the outputs playing together, read with the devices; missing for one macOS can't change.
    private(set) var outputVolumes: [AudioObjectID: Float] = [:]

    let appVolume: AppVolumeController
    let externalDisplays: ExternalDisplaysController

    @ObservationIgnored private let devices: any AudioDeviceAccess
    @ObservationIgnored private var isRunning = false
    /// The input muted here, so switching inputs moves the mute along instead of leaving one muted out of sight.
    @ObservationIgnored private var mutedInput: AudioObjectID?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let showLevel: (LevelIndicator.Kind, Double) -> Void
    /// Volumes before the outputs playing together were muted, which have no mute as one. Only
    /// counts as a mute while they're all still silent.
    @ObservationIgnored private var volumesBeforeMute: [AudioObjectID: Float] = [:]
    /// Each output's share of the loudest, from the last time they could be heard, so their balance
    /// comes back after the group volume goes down to silence and up again.
    @ObservationIgnored private var groupShares: [AudioObjectID: Float] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    /// The output sound was moved to from the multi-output device when the module stopped, by UID.
    static let movedFromMultiOutputKey = "displaysAudio.movedFromMultiOutputTo"

    init(
        devices: any AudioDeviceAccess, appVolume: AppVolumeController,
        externalDisplays: ExternalDisplaysController, defaults: UserDefaults,
        showLevel: @escaping (LevelIndicator.Kind, Double) -> Void = { LevelIndicator.show($0, $1) }
    ) {
        self.devices = devices
        self.defaults = defaults
        self.appVolume = appVolume
        self.externalDisplays = externalDisplays
        self.showLevel = showLevel
        // The display's keys setting covers this too: same keys, same Accessibility.
        externalDisplays.outputVolumeKey = { [weak self] in self?.handleVolumeKey($0) ?? false }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        devices.observe { [weak self] in self?.devicesChanged() }
        // A mute set elsewhere stays the user's: only one made here is undone when the module turns off.
        refresh()
        // Back to playing together, if it stopped only because the module did, and nothing else
        // was picked meanwhile.
        if let movedTo = defaults.string(forKey: Self.movedFromMultiOutputKey) {
            defaults.removeObject(forKey: Self.movedFromMultiOutputKey)
            if currentOutput?.uid == movedTo, let multiOutput {
                devices.setDefaultDevice(multiOutput.id, for: .output)
                refresh()
            }
        }
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
    /// Moves sound off the multi-output device too, which has no volume once the keys and sliders
    /// here are gone; the device stays, ready for next time.
    func stop() {
        guard isRunning else { return }
        refresh()
        if isPlayingTogether, let clock = clock(for: multiOutputMembers), let device = outputs.first(where: { $0.uid == clock }),
            devices.setDefaultDevice(device.id, for: .output)
        {
            defaults.set(clock, forKey: Self.movedFromMultiOutputKey)
        }
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
        multiOutputMembers = []
        multiOutputProblem = nil
        outputVolumes = [:]
        volumesBeforeMute = [:]
        groupShares = [:]
    }

    func refresh() {
        guard isRunning else { return }
        let all = devices.devices()
        outputs = all.filter(\.hasOutput)
        inputs = all.filter(\.hasInput)
        defaultOutput = devices.defaultDevice(.output)
        defaultInput = devices.defaultDevice(.input)
        isMicMuted = defaultInput.map(devices.isInputMuted) ?? false
        let made = devices.multiOutputMembers()
        // A lone pick has no device to hold it yet, so it's kept until there's one to read.
        if !made.isEmpty || multiOutputMembers.count > 1 { multiOutputMembers = made }
        readVolumes()
        // Watched for as long as their sliders show, which a lone pick's does too. A change reads
        // only the volumes, as a key held down changes them many times a second.
        devices.watchOutputVolumes(outputVolumes.keys.sorted()) { [weak self] in self?.readVolumes() }
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

    // MARK: Multi-output

    /// Reads the volumes of the picked outputs that are connected and have one.
    private func readVolumes() {
        guard isRunning else { return }
        let members = outputs.filter { multiOutputMembers.contains($0.uid) }
        outputVolumes = Dictionary(
            uniqueKeysWithValues: members.compactMap { device in devices.outputVolume(device.id).map { (device.id, $0) } })
    }

    /// Outputs that can play together: aggregates, the multi-output device among them, can't.
    var multiOutputCandidates: [AudioDevice] { outputs.filter { !$0.isAggregate } }

    var multiOutput: AudioDevice? { outputs.first { $0.uid == LiveAudioDevices.multiOutputUID } }

    var isPlayingTogether: Bool { multiOutput.map { $0.id == defaultOutput } ?? false }

    /// The output that keeps time among `members`: a wired one where there is one, as Bluetooth's
    /// clock drifts most, or else the first connected.
    private func clock(for members: [String]) -> String? {
        let connected = members.filter { uid in multiOutputCandidates.contains { $0.uid == uid } }
        return connected.first { uid in multiOutputCandidates.contains { $0.uid == uid && $0.isWired } } ?? connected.first
    }

    /// Outputs playing together that aren't connected now. They play again once they're back, unless
    /// the outputs are changed first: they can't be turned off here, so a change leaves them out.
    var disconnectedMultiOutputMembers: Int {
        let connected = Set(multiOutputCandidates.map(\.uid))
        return multiOutputMembers.filter { !connected.contains($0) }.count
    }

    /// Adds an output to the ones playing together, or takes it out. With two or more, they play
    /// as one device, which becomes the output; down to one, the one left plays and the device goes.
    func setPlaysTogether(_ on: Bool, _ device: AudioDevice) {
        guard isRunning else { return }
        refresh()
        let candidates = multiOutputCandidates
        var members = multiOutputMembers.filter { uid in uid != device.uid && candidates.contains { $0.uid == uid } }
        if on { members.append(device.uid) }
        multiOutputProblem = nil
        volumesBeforeMute = [:]
        groupShares = [:]
        if members.count > 1, let clock = clock(for: members) {
            if let id = devices.setMultiOutput(members, clock: clock) {
                multiOutputMembers = members
                devices.setDefaultDevice(id, for: .output)
            } else {
                multiOutputProblem = "macOS couldn't combine these outputs."
            }
        } else {
            multiOutputMembers = members
            // Switched before the device goes, so macOS doesn't play through one of its choosing
            // meanwhile. With none left, it's macOS's choice.
            if isPlayingTogether, let remaining = outputs.first(where: { members.contains($0.uid) }) {
                devices.setDefaultDevice(remaining.id, for: .output)
            }
            devices.removeMultiOutput()
        }
        devicesChanged()
        // The device's name stays the same as its outputs change, so app volume is told to look again.
        appVolume.refresh()
    }

    func setOutputVolume(_ volume: Float, for device: AudioDevice) {
        guard devices.setOutputVolume(volume, device.id) else { return }
        outputVolumes[device.id] = volume
    }

    /// The loudest of the outputs playing together, which stands for them all; nil unless the
    /// multi-output device plays.
    var groupVolume: Float? {
        guard isPlayingTogether else { return nil }
        return outputVolumes.values.max()
    }

    /// Sets the loudest output playing together to `volume`, and the others to their share of it,
    /// so they keep their balance.
    func setGroupVolume(_ volume: Float) {
        guard let loudest = groupVolume else { return }
        volumesBeforeMute = [:]
        if loudest > 0 { groupShares = outputVolumes.mapValues { $0 / loudest } }
        for id in outputVolumes.keys {
            let level = volume * (groupShares[id] ?? 1)
            if devices.setOutputVolume(level, id) { outputVolumes[id] = level }
        }
    }

    /// Muted with the keys, and still silent: a volume raised elsewhere ends the mute.
    private func isGroupMuted() -> Bool {
        if !volumesBeforeMute.isEmpty, outputVolumes.values.contains(where: { $0 > 0 }) { volumesBeforeMute = [:] }
        return !volumesBeforeMute.isEmpty
    }

    /// The volume and mute keys while the multi-output device plays, which macOS has no volume
    /// for, showing the loudest. Says whether it used the key. Runs while macOS waits on the key,
    /// so it goes by the volumes already read rather than reading the devices again.
    func handleVolumeKey(_ key: MediaKey) -> Bool {
        guard isRunning, isPlayingTogether, let loudest = groupVolume else { return false }
        switch key {
        case .mute where isGroupMuted():
            for (id, volume) in volumesBeforeMute where outputVolumes[id] != nil {
                if devices.setOutputVolume(volume, id) { outputVolumes[id] = volume }
            }
            volumesBeforeMute = [:]
            showLevel(.volume, Double(groupVolume ?? 0))
        case .mute:
            let saved = outputVolumes
            setGroupVolume(0)
            volumesBeforeMute = saved
            showLevel(.muted, 0)
        case .volumeUp, .volumeDown:
            // Like macOS's keys, a step while muted unmutes first, from where it was.
            var from = loudest
            if isGroupMuted() {
                for (id, volume) in volumesBeforeMute where outputVolumes[id] != nil { outputVolumes[id] = volume }
                volumesBeforeMute = [:]
                from = groupVolume ?? 0
            }
            let level = Float(ExternalDisplaysController.stepped(Double(from), key == .volumeUp ? .up : .down))
            setGroupVolume(level)
            showLevel(.volume, Double(level))
        default:
            return false
        }
        return true
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
