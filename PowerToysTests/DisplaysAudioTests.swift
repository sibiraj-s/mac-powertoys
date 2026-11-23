import CoreAudio
import CoreGraphics
import Foundation
import Testing

@testable import PowerToys

final class FakeAudioDevices: AudioDeviceAccess {
    var all: [AudioDevice] = [
        AudioDevice(id: 1, uid: "speakers", name: "Speakers", hasOutput: true, hasInput: false, transport: 0),
        AudioDevice(id: 2, uid: "headset", name: "Headset", hasOutput: true, hasInput: true, transport: 0),
        AudioDevice(id: 3, uid: "mic", name: "Microphone", hasOutput: false, hasInput: true, transport: 0),
    ]
    var defaults: [AudioDirection: AudioObjectID] = [.output: 1, .input: 3]
    var muted: Set<AudioObjectID> = []
    /// Devices with neither a mute control nor an input volume.
    var unmutable: Set<AudioObjectID> = []
    var onChange: (@MainActor () -> Void)?
    var volumes: [AudioObjectID: Float] = [1: 0.5, 2: 0.25]
    var canCombine = true
    private(set) var clock: String?
    /// Times the multi-output device was made, rather than changed in place.
    private(set) var made = 0

    func devices() -> [AudioDevice] { all }
    func multiOutputMembers() -> [String] {
        guard let device = all.first(where: { $0.uid == LiveAudioDevices.multiOutputUID }) else { return [] }
        return combined[device.id] ?? []
    }
    var combined: [AudioObjectID: [String]] = [:]
    func setMultiOutput(_ uids: [String], clock: String) -> AudioObjectID? {
        guard canCombine else { return nil }
        self.clock = clock
        if let existing = all.first(where: { $0.uid == LiveAudioDevices.multiOutputUID }) {
            combined[existing.id] = uids
            return existing.id
        }
        made += 1
        let id = (all.map(\.id).max() ?? 0) + 1
        all.append(
            AudioDevice(
                id: id, uid: LiveAudioDevices.multiOutputUID, name: "PowerToys Multi-Output", hasOutput: true, hasInput: false,
                transport: kAudioDeviceTransportTypeAggregate))
        combined[id] = uids
        return id
    }
    /// Whether the multi-output device was still the output when it was removed, so macOS picked another.
    private(set) var removedWhilePlaying = false
    func removeMultiOutput() {
        if let id = all.first(where: { $0.uid == LiveAudioDevices.multiOutputUID })?.id, defaults[.output] == id {
            removedWhilePlaying = true
        }
        all.removeAll { $0.uid == LiveAudioDevices.multiOutputUID }
        if let id = defaults[.output], !all.contains(where: { $0.id == id }) { defaults[.output] = 1 }
    }
    private(set) var watchedVolumes: [AudioObjectID] = []
    var onVolumeChange: (@MainActor () -> Void)?
    func watchOutputVolumes(_ ids: [AudioObjectID], onChange: @escaping @MainActor () -> Void) {
        watchedVolumes = ids
        onVolumeChange = onChange
    }
    func outputVolume(_ id: AudioObjectID) -> Float? { volumes[id] }
    func setOutputVolume(_ volume: Float, _ id: AudioObjectID) -> Bool {
        guard volumes[id] != nil else { return false }
        volumes[id] = volume
        return true
    }
    func defaultDevice(_ direction: AudioDirection) -> AudioObjectID? { defaults[direction] }
    func setDefaultDevice(_ id: AudioObjectID, for direction: AudioDirection) -> Bool {
        defaults[direction] = id
        return true
    }
    func isInputMuted(_ id: AudioObjectID) -> Bool { muted.contains(id) }
    func setInputMuted(_ muted: Bool, _ id: AudioObjectID) -> Bool {
        guard !unmutable.contains(id) else { return false }
        if muted { self.muted.insert(id) } else { self.muted.remove(id) }
        return true
    }
    func observe(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    func stopObserving() { onChange = nil }
}

final class FakeAudioProcesses: AudioProcessAccess {
    var list: [AudioProcess] = []
    var owners: [pid_t: AudioAppInfo] = [:]
    var outputs = ["speakers"]

    func processes() -> [AudioProcess] { list }
    func app(for pid: pid_t) -> AudioAppInfo? { owners[pid] }
    func defaultOutputs() -> [String] { outputs }
    func observe(_ onChange: @escaping @MainActor () -> Void) {}
    func stopObserving() {}
}

final class FakeTap: AppVolumeTapping {
    let processes: [AudioObjectID]
    let outputs: [String]
    var gain: Float
    var isInvalidated = false

    init(processes: [AudioObjectID], outputs: [String], gain: Float) {
        self.processes = processes
        self.outputs = outputs
        self.gain = gain
    }

    func setGain(_ gain: Float) { self.gain = gain }
    func invalidate() { isInvalidated = true }
}

actor FakeDDC: DDCAccess {
    var values: [UInt64: Double] = [7: 0.4]
    private(set) var writes: [Double] = []
    /// Speaker volume by display; a display not in here has no speakers.
    var volumes: [UInt64: Double] = [:]
    /// Mute by display; a display not in here has no mute of its own.
    var mutes: [UInt64: Bool] = [:]

    /// Reads of the displays, levels aside.
    private(set) var scans = 0
    /// Asleep, no display is found at all.
    var isAsleep = false
    func setAsleep(_ asleep: Bool) { isAsleep = asleep }
    /// The next read of the displays waits for `release`, so keys can be pressed meanwhile.
    private var holdsNextScan = false
    private var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }
    func holdNextScan() { holdsNextScan = true }
    func release() {
        held?.resume()
        held = nil
    }
    func displays(names: [String]) async -> [ExternalDisplay] {
        scans += 1
        if holdsNextScan {
            holdsNextScan = false
            await withCheckedContinuation { held = $0 }
        }
        guard !isAsleep else { return [] }
        return values.keys.sorted().map { ExternalDisplay(id: $0, name: names.first ?? "Display") }
    }
    func value(_ control: DDCControl, of id: UInt64) async -> Double? {
        let value =
            switch control {
            case .brightness: unreadable.contains(id) ? nil : values[id]
            case .volume: unreadable.contains(id) ? nil : volumes[id]
            }
        // Answers with the level as it was when asked, however long the answer takes.
        if holdsNextRead {
            holdsNextRead = false
            await withCheckedContinuation { held = $0 }
        }
        return value
    }
    /// The next level read waits for `release`, answering with the level from before.
    private var holdsNextRead = false
    func holdNextRead() { holdsNextRead = true }
    /// The display stays, but no longer says its brightness or volume.
    func forget(_ id: UInt64) { unreadable.insert(id) }
    private var unreadable: Set<UInt64> = []
    /// Connections that went with sleep: writes to them go nowhere.
    private var gone: Set<UInt64> = []
    /// After sleep the display comes back under a new ID, and doesn't answer until `answer` is called.
    func sleepAndWake(as newID: UInt64, from oldID: UInt64 = 7) {
        values[newID] = values.removeValue(forKey: oldID)
        volumes[newID] = volumes.removeValue(forKey: oldID)
        mutes[newID] = mutes.removeValue(forKey: oldID)
        gone.insert(oldID)
        unreadable.insert(newID)
    }
    func answer(_ id: UInt64) { unreadable.remove(id) }
    /// The next write is missed, with the display still there.
    private var missesNextWrite = false
    func missNextWrite() { missesNextWrite = true }
    func setValue(_ value: Double, _ control: DDCControl, of id: UInt64) async -> Bool {
        guard !gone.contains(id) else { return false }
        if missesNextWrite {
            missesNextWrite = false
            return false
        }
        switch control {
        case .brightness:
            writes.append(value)
            values[id] = value
        case .volume:
            volumes[id] = value
        }
        await Task.yield()
        return true
    }
    func isMuted(_ id: UInt64) -> Bool? { mutes[id] }
    func setMuted(_ muted: Bool, of id: UInt64) -> Bool {
        guard !gone.contains(id) else { return false }
        mutes[id] = muted
        return true
    }
    func setValues(_ values: [UInt64: Double]) { self.values = values }
    func addSpeakers(volume: Double, mute: Bool?) {
        volumes[7] = volume
        mutes[7] = mute
    }
}

extension DisplaysAudioController {
    static func testing(
        devices: FakeAudioDevices = FakeAudioDevices(), processes: FakeAudioProcesses = FakeAudioProcesses(),
        defaults: UserDefaults
    ) -> DisplaysAudioController {
        DisplaysAudioController(
            devices: devices,
            appVolume: AppVolumeController(
                defaults: defaults, system: processes, access: { .granted }, requestAccess: { _ in }, openAccessSettings: {},
                makeTap: { FakeTap(processes: $0, outputs: $1, gain: $2) }, workspaceCenter: NotificationCenter()),
            externalDisplays: ExternalDisplaysController(
                defaults: defaults, ddc: FakeDDC(), screenNames: { ["Studio Display"] }, isTrusted: { false }, showLevel: { _, _ in },
                workspaceCenter: NotificationCenter()),
            defaults: defaults)
    }
}

struct AudioDevicesTests {
    let store = TestDefaults()

    @Test func outputsPlayTogetherOnceTwoArePicked() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[0])
        // One pick waits for a second, without changing the output.
        #expect(controller.multiOutputMembers == ["speakers"])
        #expect(controller.multiOutput == nil)
        #expect(devices.defaults[.output] == 1)
        controller.setPlaysTogether(true, devices.all[1])
        #expect(controller.multiOutputMembers == ["speakers", "headset"])
        #expect(controller.currentOutput?.uid == LiveAudioDevices.multiOutputUID)
        // The multi-output device can't be part of itself.
        #expect(controller.multiOutputCandidates.map(\.name) == ["Speakers", "Headset"])
    }

    @Test func droppingToOneOutputPlaysThroughIt() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        controller.setPlaysTogether(false, devices.all[0])
        #expect(controller.multiOutput == nil)
        #expect(controller.multiOutputMembers == ["headset"])
        #expect(devices.defaults[.output] == 2)
    }

    @Test func readsAMultiOutputDeviceMadeInAnEarlierRun() {
        let devices = FakeAudioDevices()
        _ = devices.setMultiOutput(["speakers", "headset"], clock: "speakers")
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        #expect(controller.multiOutputMembers == ["speakers", "headset"])
    }

    @Test func changesTheMultiOutputDeviceInPlace() {
        let devices = FakeAudioDevices()
        devices.all.append(AudioDevice(id: 4, uid: "usb", name: "USB DAC", hasOutput: true, hasInput: false, transport: 0))
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        let id = controller.multiOutput?.id
        controller.setPlaysTogether(true, devices.all[3])
        #expect(devices.made == 1)
        #expect(controller.multiOutput?.id == id)
        #expect(controller.multiOutputMembers == ["speakers", "headset", "usb"])
    }

    @Test func aWiredOutputKeepsTheTime() {
        let devices = FakeAudioDevices()
        devices.all = [
            AudioDevice(
                id: 1, uid: "airpods", name: "AirPods", hasOutput: true, hasInput: false, transport: kAudioDeviceTransportTypeBluetooth),
            AudioDevice(
                id: 2, uid: "airplay", name: "HomePod", hasOutput: true, hasInput: false, transport: kAudioDeviceTransportTypeAirPlay),
            AudioDevice(id: 3, uid: "usb", name: "USB DAC", hasOutput: true, hasInput: false, transport: kAudioDeviceTransportTypeUSB),
        ]
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        // AirPlay isn't wired, so the first pick keeps the time.
        #expect(devices.clock == "airpods")
        controller.setPlaysTogether(true, devices.all[2])
        #expect(devices.clock == "usb")
    }

    @Test func aChangeLeavesOutOutputsThatArentConnected() {
        let devices = FakeAudioDevices()
        _ = devices.setMultiOutput(["gone", "speakers", "headset"], clock: "speakers")
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        #expect(controller.disconnectedMultiOutputMembers == 1)
        controller.setPlaysTogether(false, devices.all[1])
        // Only Speakers is left connected, so it plays on its own.
        #expect(controller.multiOutput == nil)
        #expect(controller.multiOutputMembers == ["speakers"])
    }

    @Test func watchesTheVolumesWithSliders() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        #expect(devices.watchedVolumes.isEmpty)
        controller.setPlaysTogether(true, devices.all[1])
        // A lone pick shows its slider, so its volume is watched before there's a multi-output device.
        #expect(devices.watchedVolumes == [2])
        controller.setPlaysTogether(true, devices.all[0])
        #expect(Set(devices.watchedVolumes) == [1, 2])
        controller.setPlaysTogether(false, devices.all[0])
        #expect(devices.watchedVolumes == [2])
        devices.volumes[2] = 0.9
        devices.onChange?()
        #expect(controller.outputVolumes[2] == 0.9)
    }

    @Test func volumeKeysStepEachOutputPlayingTogether() {
        let devices = FakeAudioDevices()
        let shown = AppVolumeTests.Box<[(LevelIndicator.Kind, Double)]>([])
        let controller = DisplaysAudioController(
            devices: devices,
            appVolume: AppVolumeController(
                defaults: store.defaults, system: FakeAudioProcesses(), access: { .granted }, requestAccess: { _ in },
                openAccessSettings: {},
                makeTap: { FakeTap(processes: $0, outputs: $1, gain: $2) }, workspaceCenter: NotificationCenter()),
            externalDisplays: ExternalDisplaysController(
                defaults: store.defaults, ddc: FakeDDC(), screenNames: { [] }, isTrusted: { false }, showLevel: { _, _ in },
                workspaceCenter: NotificationCenter()),
            defaults: store.defaults, showLevel: { shown.value.append(($0, $1)) })
        controller.start()
        // Not playing together: left to macOS.
        #expect(!controller.handleVolumeKey(.volumeUp))
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])

        // The loudest steps, and the others keep their share of it.
        #expect(controller.handleVolumeKey(.volumeUp))
        #expect(devices.volumes == [1: 0.5625, 2: 0.28125])
        #expect(shown.value.last?.1 == 0.5625)
        #expect(controller.handleVolumeKey(.volumeDown))
        #expect(devices.volumes == [1: 0.5, 2: 0.25])

        #expect(controller.handleVolumeKey(.mute))
        #expect(devices.volumes == [1: 0, 2: 0])
        #expect(shown.value.last?.0 == .muted)
        // A step while muted unmutes first, from where it was.
        #expect(controller.handleVolumeKey(.volumeDown))
        #expect(devices.volumes == [1: 0.4375, 2: 0.21875])
    }

    @Test func aVolumeRaisedElsewhereEndsTheKeysMute() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        #expect(controller.handleVolumeKey(.mute))
        controller.setOutputVolume(0.3, for: devices.all[0])
        // Not muted any more, so the key mutes rather than bringing back the old levels.
        #expect(controller.handleVolumeKey(.mute))
        #expect(devices.volumes == [1: 0, 2: 0])
        #expect(controller.handleVolumeKey(.mute))
        #expect(devices.volumes == [1: 0.3, 2: 0])
    }

    @Test func theMenuBarSliderSetsTheOutputsTogether() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        #expect(controller.groupVolume == nil)
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        #expect(controller.groupVolume == 0.5)
        controller.setGroupVolume(1)
        #expect(devices.volumes == [1: 1, 2: 0.5])
        // A change elsewhere is read without reading the devices again.
        devices.volumes[1] = 0.75
        devices.onVolumeChange?()
        #expect(controller.groupVolume == 0.75)
    }

    @Test func stoppingMovesSoundOffTheMultiOutputDevice() {
        let devices = FakeAudioDevices()
        devices.all[1] = AudioDevice(
            id: 2, uid: "headset", name: "Headset", hasOutput: true, hasInput: true, transport: kAudioDeviceTransportTypeBluetooth)
        devices.all[0] = AudioDevice(
            id: 1, uid: "speakers", name: "Speakers", hasOutput: true, hasInput: false, transport: kAudioDeviceTransportTypeBuiltIn)
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[1])
        controller.setPlaysTogether(true, devices.all[0])
        controller.stop()
        // To the wired one, which kept the time; the device stays for next time.
        #expect(devices.defaults[.output] == 1)
        #expect(devices.multiOutputMembers() == ["headset", "speakers"])
        // And back once it starts again.
        controller.start()
        #expect(controller.isPlayingTogether)
    }

    @Test func staysOnAnOutputPickedWhileStopped() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        controller.stop()
        devices.defaults[.output] = 2
        controller.start()
        #expect(!controller.isPlayingTogether)
        #expect(devices.defaults[.output] == 2)
    }

    @Test func theBalanceComesBackFromSilence() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        controller.setGroupVolume(0)
        controller.setGroupVolume(1)
        #expect(devices.volumes == [1: 1, 2: 0.5])
    }

    @Test func dropsToOneWithoutMacOSPickingAnOutputMeanwhile() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        controller.setPlaysTogether(false, devices.all[1])
        #expect(!devices.removedWhilePlaying)
        #expect(devices.defaults[.output] == 1)
    }

    @Test func theOutputTurnedOffIsntMadeTheOutput() {
        let devices = FakeAudioDevices()
        let id = devices.setMultiOutput(["gone", "headset"], clock: "headset")!
        devices.defaults[.output] = id
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(false, devices.all[1])
        #expect(devices.defaults[.output] != 2)
    }

    @Test func theVolumeKeysSettingPassesKeysToTheOutputs() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        #expect(!controller.externalDisplays.handle(.volumeUp))
        controller.externalDisplays.usesVolumeKeys = true
        #expect(controller.externalDisplays.handle(.volumeUp))
        #expect(devices.volumes[1] == 0.5625)
    }

    @Test func saysWhenOutputsCantBeCombined() {
        let devices = FakeAudioDevices()
        devices.canCombine = false
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        #expect(controller.multiOutputProblem != nil)
        #expect(devices.defaults[.output] == 1)
    }

    @Test func setsEachOutputsVolume() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        // Only outputs playing together have their volume read.
        #expect(controller.outputVolumes.isEmpty)
        controller.setPlaysTogether(true, devices.all[0])
        controller.setPlaysTogether(true, devices.all[1])
        #expect(controller.outputVolumes == [1: 0.5, 2: 0.25])
        controller.setOutputVolume(0.8, for: devices.all[1])
        #expect(devices.volumes[2] == 0.8)
        #expect(controller.outputVolumes[2] == 0.8)
    }

    @Test func listsOutputsAndInputsWithTheDefaults() {
        let controller = DisplaysAudioController.testing(defaults: store.defaults)
        controller.start()
        #expect(controller.outputs.map(\.name) == ["Speakers", "Headset"])
        #expect(controller.inputs.map(\.name) == ["Headset", "Microphone"])
        #expect(controller.currentOutput?.name == "Speakers")
        #expect(controller.currentInput?.name == "Microphone")
    }

    @Test func selectsAndCyclesOutputs() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.selectNextOutput()
        #expect(devices.defaults[.output] == 2)
        controller.selectNextOutput()
        #expect(devices.defaults[.output] == 1)
        controller.select(devices.all[2], for: .input)
        #expect(controller.defaultInput == 3)
    }

    @Test func togglesTheMicrophoneMute() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.toggleMicMute()
        #expect(controller.isMicMuted)
        #expect(devices.muted == [3])
        controller.toggleMicMute()
        #expect(!controller.isMicMuted)
        #expect(devices.muted.isEmpty)
    }

    @Test func theMuteFollowsASwitchToAnotherInput() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setMicMuted(true)
        devices.defaults[.input] = 2
        devices.onChange?()
        #expect(devices.muted == [2])
        #expect(controller.isMicMuted)
    }

    @Test func turningTheModuleOffUnmutes() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setMicMuted(true)
        controller.stop()
        #expect(devices.muted.isEmpty)
        #expect(devices.onChange == nil)
    }

    @Test func keepsTheOldMicMutedAndSaysSoWhenTheNewOneCantBeMuted() {
        let devices = FakeAudioDevices()
        devices.unmutable = [2]
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setMicMuted(true)
        devices.defaults[.input] = 2
        devices.onChange?()
        #expect(devices.muted == [3])
        #expect(!controller.isMicMuted)
        #expect(controller.muteProblem != nil)

        // Unmuting now also undoes the mute left on the microphone switched away from.
        controller.setMicMuted(false)
        #expect(devices.muted.isEmpty)
        #expect(controller.muteProblem == nil)
    }

    @Test func toggleGoesByAMuteMadeElsewhere() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        // Muted with a headset button, say, without this app hearing of it yet.
        devices.muted = [3]
        controller.toggleMicMute()
        #expect(devices.muted.isEmpty)
        #expect(!controller.isMicMuted)
    }

    @Test func aMuteUndoneElsewhereIsntCarriedToTheNextMic() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        controller.setMicMuted(true)
        // Unmuted in a call app, then the headset is picked.
        devices.muted = []
        devices.onChange?()
        devices.defaults[.input] = 2
        devices.onChange?()
        #expect(devices.muted.isEmpty)
        #expect(!controller.isMicMuted)
    }

    @Test func stopForgetsTheDevices() {
        let controller = DisplaysAudioController.testing(defaults: store.defaults)
        controller.start()
        controller.stop()
        #expect(controller.defaultInput == nil)
        #expect(controller.defaultOutput == nil)
        #expect(!controller.isMicMuted)
    }

    @Test func namesADefaultThatIsntOffered() {
        let devices = FakeAudioDevices()
        devices.defaults[.output] = 99
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        #expect(controller.deviceName(.output) == "Other device")
        #expect(controller.deviceName(.input) == "Microphone")
        devices.defaults[.input] = nil
        controller.refresh()
        #expect(controller.deviceName(.input) == "None")
    }

    @Test func leavesAMuteSetElsewhereAlone() {
        let devices = FakeAudioDevices()
        devices.muted = [3]
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.start()
        #expect(controller.isMicMuted)
        controller.stop()
        #expect(devices.muted == [3])
    }

    @Test func doesNothingWhileStopped() {
        let devices = FakeAudioDevices()
        let controller = DisplaysAudioController.testing(devices: devices, defaults: store.defaults)
        controller.setMicMuted(true)
        #expect(devices.muted.isEmpty)
        #expect(controller.outputs.isEmpty)
    }

    @Test func moduleSwitchStartsAndStopsIt() {
        let devices = FakeAudioDevices()
        let state = AppState.testing(
            defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings(),
            displaysAudio: .testing(devices: devices, defaults: store.defaults))
        state.setEnabled(.displaysAudio, false)
        #expect(state.displaysAudio.outputs.isEmpty)
        #expect(!state.shortcuts.isActive(DisplaysAudioController.muteShortcut))
        state.setEnabled(.displaysAudio, true)
        #expect(state.displaysAudio.outputs.count == 2)
        #expect(state.shortcuts.isActive(DisplaysAudioController.muteShortcut))
        #expect(state.shortcuts.isActive(DisplaysAudioController.nextOutputShortcut))
    }
}

struct AppVolumeTests {
    let store = TestDefaults()

    private func browser() -> FakeAudioProcesses {
        let processes = FakeAudioProcesses()
        processes.list = [
            AudioProcess(objectID: 20, pid: 200, isPlaying: true),
            AudioProcess(objectID: 10, pid: 100, isPlaying: false),
            AudioProcess(objectID: 30, pid: 300, isPlaying: false),
        ]
        let browser = AudioAppInfo(bundleID: "com.example.browser", name: "Browser", pid: 100)
        processes.owners = [100: browser, 200: browser, 300: AudioAppInfo(bundleID: "com.example.chat", name: "Chat", pid: 300)]
        return processes
    }

    private func controller(_ processes: FakeAudioProcesses, taps: Box<[FakeTap]>) -> AppVolumeController {
        AppVolumeController(
            defaults: store.defaults, system: processes, access: { taps.access },
            requestAccess: { answered in
                taps.requests += 1
                taps.answer = answered
            },
            openAccessSettings: { taps.settingsOpened += 1 },
            makeTap: {
                let tap = FakeTap(processes: $0, outputs: $1, gain: $2)
                taps.value.append(tap)
                return tap
            }, workspaceCenter: NotificationCenter())
    }

    final class Box<T> {
        var value: T
        var access = PermissionStatus.granted
        var requests = 0
        var settingsOpened = 0
        var answer: (@MainActor () -> Void)?
        init(_ value: T) { self.value = value }
    }

    @Test func groupsHelpersUnderTheirApp() {
        let processes = browser()
        let apps = AppVolumeController.group(processes.list, app: processes.app(for:))
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        #expect(byID["com.example.browser"]?.processes == [10, 20])
        #expect(byID["com.example.browser"]?.isPlaying == true)
        #expect(byID["com.example.chat"]?.isPlaying == false)
    }

    @Test func listsOnlyAppsPlayingOrSet() {
        let taps = Box<[FakeTap]>([])
        let controller = controller(browser(), taps: taps)
        controller.start()
        #expect(controller.apps.map(\.name) == ["Browser"])
    }

    @Test func tapsOnlyAppsBelowFullVolume() throws {
        let taps = Box<[FakeTap]>([])
        let controller = controller(browser(), taps: taps)
        controller.start()
        #expect(taps.value.isEmpty)

        let app = try #require(controller.apps.first)
        controller.setVolume(0.5, for: app)
        #expect(taps.value.count == 1)
        #expect(taps.value[0].processes == [10, 20])
        #expect(taps.value[0].outputs == ["speakers"])
        #expect(taps.value[0].gain == 0.5)

        controller.setVolume(0.25, for: app)
        #expect(taps.value.count == 1)
        #expect(taps.value[0].gain == 0.25)

        controller.setVolume(1, for: app)
        #expect(taps.value[0].isInvalidated)
        #expect(controller.settings.isEmpty)
    }

    @Test func muteKeepsTheVolume() throws {
        let taps = Box<[FakeTap]>([])
        let controller = controller(browser(), taps: taps)
        controller.start()
        let app = try #require(controller.apps.first)
        controller.setVolume(0.6, for: app)
        controller.setMuted(true, for: app)
        #expect(taps.value[0].gain == 0)
        controller.setMuted(false, for: app)
        #expect(abs(taps.value[0].gain - 0.6) < 0.0001)
    }

    @Test func rebuildsTheTapWhenProcessesOrOutputChange() throws {
        let processes = browser()
        let taps = Box<[FakeTap]>([])
        let controller = controller(processes, taps: taps)
        controller.start()
        controller.setVolume(0.5, for: try #require(controller.apps.first))

        processes.outputs = ["headset"]
        controller.refresh()
        #expect(taps.value.count == 2)
        #expect(taps.value[0].isInvalidated)
        #expect(taps.value[1].outputs == ["headset"])

        processes.list.append(AudioProcess(objectID: 40, pid: 200, isPlaying: true))
        controller.refresh()
        #expect(taps.value.count == 3)
        #expect(taps.value[2].processes == [10, 20, 40])
    }

    @Test func rebuildsTheTapWhenOutputsPlayingTogetherChange() throws {
        let processes = browser()
        processes.outputs = ["speakers", "headset"]
        let taps = Box<[FakeTap]>([])
        let controller = controller(processes, taps: taps)
        controller.start()
        controller.setVolume(0.5, for: try #require(controller.apps.first))
        #expect(taps.value[0].outputs == ["speakers", "headset"])

        // A third output joins the same multi-output device.
        processes.outputs = ["speakers", "headset", "usb"]
        controller.refresh()
        #expect(taps.value[0].isInvalidated)
        #expect(taps.value[1].outputs == ["speakers", "headset", "usb"])
    }

    @Test func wakeMakesTheTapsAgain() throws {
        let processes = browser()
        let taps = Box<[FakeTap]>([])
        let controller = controller(processes, taps: taps)
        controller.systemDidWake()
        #expect(taps.value.isEmpty)  // not running

        controller.start()
        controller.setVolume(0.5, for: try #require(controller.apps.first))
        #expect(taps.value.count == 1)

        // Same processes, same output UID: only the wake says the old tap may be playing nowhere.
        controller.systemDidWake()
        #expect(taps.value.count == 2)
        #expect(taps.value[0].isInvalidated)
        #expect(!taps.value[1].isInvalidated)
        #expect(taps.value[1].gain == 0.5)
        controller.stop()
    }

    @Test func wakeMakesTheTapsAgainOnceOutputsAreBack() async throws {
        let processes = browser()
        let taps = Box<[FakeTap]>([])
        let pauses = Box(0)
        let controller = AppVolumeController(
            defaults: store.defaults, system: processes, access: { .granted }, requestAccess: { _ in }, openAccessSettings: {},
            makeTap: {
                let tap = FakeTap(processes: $0, outputs: $1, gain: $2)
                taps.value.append(tap)
                return tap
            },
            pause: { _ in pauses.value += 1 }, workspaceCenter: NotificationCenter())
        controller.start()
        controller.setVolume(0.5, for: try #require(controller.apps.first))

        // Made at once, though the output may not be back yet, and again after a pause.
        controller.systemDidWake()
        #expect(taps.value.count == 2)
        while taps.value.count < 3 { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        #expect(taps.value.count == 3)
        #expect(pauses.value == 1)
        #expect(taps.value[2].gain == 0.5)
        controller.stop()
    }

    @Test func aTapThatCantBeMadeRightAfterWakeIsTriedAgain() async throws {
        let processes = browser()
        var outputReady = true
        var made: [FakeTap] = []
        let pauses = AppVolumeTests.Box(0)
        let controller = AppVolumeController(
            defaults: store.defaults, system: processes, access: { .granted }, requestAccess: { _ in }, openAccessSettings: {},
            makeTap: {
                guard outputReady else { throw AppVolumeTapError(step: "set up playback", status: -1) }
                let tap = FakeTap(processes: $0, outputs: $1, gain: $2)
                made.append(tap)
                return tap
            },
            pause: { _ in
                pauses.value += 1
                outputReady = true
            }, workspaceCenter: NotificationCenter())
        controller.start()
        controller.setVolume(0.5, for: try #require(controller.apps.first))
        #expect(made.count == 1)

        // The output isn't back yet when the wake is heard.
        outputReady = false
        controller.systemDidWake()
        #expect(made.count == 1)
        #expect(!controller.errors.isEmpty)
        while made.count < 2 { await Task.yield() }
        #expect(made[1].gain == 0.5)
        #expect(controller.errors.isEmpty)
        for _ in 0..<100 { await Task.yield() }
        #expect(pauses.value == 1)
        controller.stop()
    }

    @Test func volumesAreRememberedByApp() throws {
        let taps = Box<[FakeTap]>([])
        let first = controller(browser(), taps: taps)
        first.start()
        first.setVolume(0.3, for: try #require(first.apps.first))
        first.stop()
        #expect(taps.value[0].isInvalidated)

        let again = controller(browser(), taps: taps)
        again.start()
        #expect(taps.value.count == 2)
        #expect(abs(taps.value[1].gain - 0.3) < 0.0001)
    }

    @Test func asksOnceAndTapsUnlessRefused() throws {
        let taps = Box<[FakeTap]>([])
        taps.access = .unknown
        let controller = controller(browser(), taps: taps)
        controller.start()
        let app = try #require(controller.apps.first)
        controller.setVolume(0.5, for: app)
        controller.setVolume(0.4, for: app)
        #expect(taps.requests == 1)
        // macOS's check may still say "not asked" once allowed, so the tap is tried anyway.
        #expect(taps.value.count == 1)
        #expect(abs(taps.value[0].gain - 0.4) < 0.0001)
        #expect(controller.errors.isEmpty)

        taps.access = .denied
        taps.answer?()
        #expect(taps.value[0].isInvalidated)
        #expect(controller.errors[app.id] != nil)
    }

    @Test func remakesTheTapOnceThePromptIsAllowed() throws {
        let taps = Box<[FakeTap]>([])
        taps.access = .unknown
        let controller = controller(browser(), taps: taps)
        controller.start()
        controller.setVolume(0.5, for: try #require(controller.apps.first))
        #expect(taps.value.count == 1)

        // Made while the prompt was up, the first tap heard nothing.
        taps.access = .granted
        taps.answer?()
        #expect(taps.value.count == 2)
        #expect(taps.value[0].isInvalidated)
        #expect(!taps.value[1].isInvalidated)
        #expect(abs(taps.value[1].gain - 0.5) < 0.0001)
    }

    @Test func asksForAnAppSavedBelow100InAnEarlierRun() throws {
        let taps = Box<[FakeTap]>([])
        let earlier = controller(browser(), taps: taps)
        earlier.start()
        earlier.setVolume(0.2, for: try #require(earlier.apps.first))
        earlier.stop()

        taps.access = .unknown
        let controller = controller(browser(), taps: taps)
        controller.start()
        #expect(taps.requests == 0)
        controller.setVolume(0.3, for: try #require(controller.apps.first))
        #expect(taps.requests == 1)
    }

    @Test func aPausedAppStaysListedWhenDraggedBackTo100() {
        let controller = controller(browser(), taps: Box<[FakeTap]>([]))
        controller.start()
        let chat = AudioApp(id: "com.example.chat", name: "Chat", pid: 300, processes: [30], isPlaying: false)
        controller.setVolume(0.5, for: chat)
        #expect(controller.apps.contains { $0.id == chat.id })
        controller.setVolume(1, for: chat)
        #expect(controller.apps.contains { $0.id == chat.id })
    }

    @Test func aFailedTapIsntRetriedUntilSomethingChanges() throws {
        struct Failure: Error {}
        var attempts = 0
        let controller = AppVolumeController(
            defaults: store.defaults, system: browser(), access: { .granted }, requestAccess: { _ in }, openAccessSettings: {},
            makeTap: { _, _, _ in
                attempts += 1
                throw Failure()
            }, workspaceCenter: NotificationCenter())
        controller.start()
        let app = try #require(controller.apps.first)
        controller.setVolume(0.5, for: app)
        controller.refresh()
        controller.refresh()
        #expect(attempts == 1)
        #expect(controller.errors[app.id] != nil)

        // Dragging the slider on doesn't try again on every step.
        controller.setVolume(0.4, for: app)
        controller.setVolume(0.3, for: app)
        #expect(attempts == 1)

        // Back to 100% and away again does.
        controller.setVolume(1, for: app)
        controller.setVolume(0.5, for: app)
        #expect(attempts == 2)
    }

    @Test func whenDeniedOpensSettingsOnlyOnce() throws {
        let taps = Box<[FakeTap]>([])
        taps.access = .denied
        let controller = controller(browser(), taps: taps)
        controller.start()
        let app = try #require(controller.apps.first)
        for step in stride(from: Float(0.9), through: 0.1, by: -0.1) { controller.setVolume(step, for: app) }
        #expect(taps.settingsOpened == 1)
        #expect(taps.requests == 0)
        #expect(taps.value.isEmpty)
    }
}

struct AppVolumeMixTests {
    private func run(
        input: [[Float]], inputChannels: [UInt32], outputFrames: Int, outputChannels: [UInt32], gain: Float, skipped: Int = 0
    ) -> [[Float]] {
        let inputList = AudioBufferList.allocate(maximumBuffers: max(input.count, 1))
        inputList.count = input.count
        defer { free(inputList.unsafeMutablePointer) }
        let inputStorage = input.map { samples in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            return pointer
        }
        defer {
            for storage in inputStorage { storage.deallocate() }
        }
        for index in input.indices {
            inputList[index] = AudioBuffer(
                mNumberChannels: inputChannels[index], mDataByteSize: UInt32(input[index].count * 4), mData: inputStorage[index])
        }

        let outputList = AudioBufferList.allocate(maximumBuffers: outputChannels.count)
        defer { free(outputList.unsafeMutablePointer) }
        let outputStorage = outputChannels.map { channels in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: outputFrames * Int(channels))
            pointer.initialize(repeating: 9, count: outputFrames * Int(channels))
            return pointer
        }
        defer {
            for storage in outputStorage { storage.deallocate() }
        }
        for index in outputChannels.indices {
            outputList[index] = AudioBuffer(
                mNumberChannels: outputChannels[index], mDataByteSize: UInt32(outputFrames * Int(outputChannels[index]) * 4),
                mData: outputStorage[index])
        }

        AppVolumeTap.mix(inputList.unsafePointer, into: outputList.unsafeMutablePointer, gain: gain, skippingInputChannels: skipped)
        return outputChannels.indices.map { index in
            Array(UnsafeBufferPointer(start: outputStorage[index], count: outputFrames * Int(outputChannels[index])))
        }
    }

    @Test func scalesInterleavedStereo() {
        let output = run(input: [[1, -1, 0.5, -0.5]], inputChannels: [2], outputFrames: 2, outputChannels: [2], gain: 0.5)
        #expect(output == [[0.5, -0.5, 0.25, -0.25]])
    }

    @Test func splitsStereoIntoSeparateBuffers() {
        let output = run(input: [[1, 2, 3, 4]], inputChannels: [2], outputFrames: 2, outputChannels: [1, 1], gain: 1)
        #expect(output == [[1, 3], [2, 4]])
    }

    @Test func repeatsChannelsAndSilencesMissingFrames() {
        let output = run(input: [[1, 2]], inputChannels: [2], outputFrames: 2, outputChannels: [4], gain: 1)
        #expect(output == [[1, 2, 1, 2, 0, 0, 0, 0]])
    }

    @Test func skipsAnotherDevicesMicrophone() {
        // A headset's mono microphone, then the tap's stereo.
        let output = run(
            input: [[7, 7], [1, 2, 3, 4]], inputChannels: [1, 2], outputFrames: 2, outputChannels: [2], gain: 1, skipped: 1)
        let mixed = output[0]
        #expect(mixed == [1, 2, 3, 4])
    }

    @Test func silenceWithoutInput() {
        let output = run(input: [], inputChannels: [], outputFrames: 2, outputChannels: [2], gain: 1)
        #expect(output == [[0, 0, 0, 0]])
    }
}

struct DisplayBrightnessTests {
    let store = TestDefaults()

    private final class Pointer {
        var onExternal = true
        /// Whether sound plays through the display's speakers.
        var playsOnDisplay = true
        var shown: [Double] = []
        var kinds: [LevelIndicator.Kind] = []
    }

    private func keysController(_ ddc: FakeDDC, pointer: Pointer) -> ExternalDisplaysController {
        ExternalDisplaysController(
            defaults: store.defaults, ddc: ddc, screenNames: { ["Studio Display"] },
            pointerScreenNeedsDDC: { pointer.onExternal }, outputNeedsDDC: { pointer.playsOnDisplay }, isTrusted: { false },
            showLevel: {
                pointer.kinds.append($0)
                pointer.shown.append($1)
            }, workspaceCenter: NotificationCenter())
    }

    @Test func readsVolumeAndMuteKeys() {
        #expect(MediaKey.pressed(subtype: 8, data1: 0 << 16 | 0xA00) == .volumeUp)
        #expect(MediaKey.pressed(subtype: 8, data1: 1 << 16 | 0xA00) == .volumeDown)
        #expect(MediaKey.pressed(subtype: 8, data1: 7 << 16 | 0xA00) == .mute)
        #expect(MediaKey.released(subtype: 8, data1: 7 << 16 | 0xB00))
    }

    @Test func volumeKeysStepTheDisplaysSpeakers() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.25, mute: false)
        let pointer = Pointer()
        let controller = keysController(ddc, pointer: pointer)
        controller.start()
        await controller.load()
        #expect(!controller.handle(.volumeUp))  // off until turned on

        controller.usesVolumeKeys = true
        #expect(controller.handle(.volumeUp))
        #expect(controller.displays.first?.volume == 5.0 / 16)
        #expect(pointer.kinds == [.volume])

        // Through other speakers, macOS has the keys.
        pointer.playsOnDisplay = false
        #expect(!controller.handle(.volumeUp))
        controller.stop()
    }

    @Test func muteUsesTheDisplaysOwnMuteAndAStepUnmutes() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: false)
        let pointer = Pointer()
        let controller = keysController(ddc, pointer: pointer)
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()
        #expect(controller.handle(.mute))
        #expect(controller.displays.first?.isMuted == true)
        for _ in 0..<1000 where await ddc.mutes[7] != true { await Task.yield() }
        #expect(await ddc.mutes[7] == true)
        #expect(pointer.kinds == [.muted])

        #expect(controller.handle(.volumeDown))
        #expect(controller.displays.first?.isMuted == false)
        #expect(controller.displays.first?.volume == 7.0 / 16)
        controller.stop()
    }

    @Test func withoutItsOwnMuteADisplayIsMutedByTurningItDown() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: nil)
        let controller = keysController(ddc, pointer: Pointer())
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()
        #expect(controller.handle(.mute))
        #expect(controller.displays.first?.volume == 0)
        #expect(controller.handle(.mute))
        #expect(controller.displays.first?.volume == 0.5)
        controller.stop()
    }

    @Test func volumeKeysAreLeftAloneForDisplaysWithoutSpeakers() async {
        let controller = keysController(FakeDDC(), pointer: Pointer())
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()
        #expect(!controller.handle(.volumeUp))
        #expect(!controller.handle(.mute))
        controller.stop()
    }

    @Test func warnsAboutDisplayAppsThatTakeTheKeys() {
        var running: Set<String> = ["Qisda.DDPM", "com.apple.Safari"]
        let controller = ExternalDisplaysController(
            defaults: store.defaults, ddc: FakeDDC(), screenNames: { ["Dell"] }, isTrusted: { false },
            runningBundleIDs: { running }, showLevel: { _, _ in }, workspaceCenter: NotificationCenter())
        controller.start()
        // Dell's app takes the volume keys but leaves brightness alone.
        #expect(controller.brightnessKeysWarning == nil)
        #expect(controller.volumeKeysWarning?.hasPrefix("Dell Display and Peripheral Manager is running") == true)

        running = ["Qisda.DDPM", "me.guillaumeb.MonitorControl"]
        controller.stop()
        controller.start()
        #expect(controller.brightnessKeysWarning?.hasPrefix("MonitorControl is running") == true)
        #expect(controller.volumeKeysWarning?.contains("and MonitorControl are running") == true)
        controller.stop()
        #expect(controller.volumeKeysWarning == nil)
    }

    @Test func readsAMaximumWithAnUnusedHighByte() {
        // A Dell U5226KW's volume: maximum 0xFF64, which means 100.
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x62, 0x00, 0xFF, 0x64, 0x00, 0x1A, 0x57]
        #expect(DDC.parseReply(reply, code: 0x62)?.maximum == 100)
        #expect(DDC.parseReply(reply, code: 0x62)?.current == 26)
    }

    @Test func showsTheLevelAKeyChangedTo() async {
        let pointer = Pointer()
        let controller = keysController(FakeDDC(), pointer: pointer)
        controller.start()
        await controller.load()
        controller.step(.up)
        controller.step(.down)
        controller.step(.down)
        // 0.4 is 6.4 steps of 16; it snaps to 6, then goes up one and down two.
        let expected: [Double] = [7, 6, 5].map { $0 / 16 }
        #expect(pointer.shown == expected)
        controller.stop()
    }

    @Test func pressesBeforeTheFirstLoadAllCount() async {
        let ddc = FakeDDC()
        let controller = keysController(ddc, pointer: Pointer())
        controller.start()
        controller.step(.up)
        controller.step(.up)
        controller.step(.up)
        await controller.load()
        for _ in 0..<1000 where controller.displays.first?.brightness != 9.0 / 16 { await Task.yield() }
        #expect(controller.displays.first?.brightness == 9.0 / 16)
        controller.stop()
    }

    @Test func readsBrightnessKeys() {
        // Key in the top 16 bits, 0xA down or 0xB up in the next byte.
        #expect(MediaKey.pressed(subtype: 8, data1: 2 << 16 | 0xA00) == .brightnessUp)
        #expect(MediaKey.pressed(subtype: 8, data1: 3 << 16 | 0xA00) == .brightnessDown)
        #expect(MediaKey.pressed(subtype: 8, data1: 2 << 16 | 0xB00) == nil)
        #expect(MediaKey.pressed(subtype: 8, data1: 16 << 16 | 0xA00) == nil)  // play/pause
        #expect(MediaKey.pressed(subtype: 7, data1: 2 << 16 | 0xA00) == nil)
        #expect(MediaKey.released(subtype: 8, data1: 3 << 16 | 0xB00))
        #expect(!MediaKey.released(subtype: 8, data1: 3 << 16 | 0xA00))
    }

    @Test func readsF14AndF15AsBrightnessKeys() {
        // Many non-Apple keyboards send these for brightness, as macOS expects.
        #expect(MediaKey.key(keyCode: 113, flags: []) == .brightnessUp)
        #expect(MediaKey.key(keyCode: 107, flags: []) == .brightnessDown)
        #expect(MediaKey.key(keyCode: 113, flags: .maskSecondaryFn) == .brightnessUp)
        #expect(MediaKey.key(keyCode: 113, flags: .maskCommand) == nil)  // left for shortcuts
        #expect(MediaKey.key(keyCode: 106, flags: []) == nil)  // F16
    }

    @Test func brightnessKeysAreOffByDefaultAndRemembered() {
        let controller = keysController(FakeDDC(), pointer: Pointer())
        #expect(!controller.usesBrightnessKeys)
        controller.usesBrightnessKeys = true
        #expect(keysController(FakeDDC(), pointer: Pointer()).usesBrightnessKeys)
    }

    @Test func keysStepTheExternalDisplayUnderThePointer() async {
        let pointer = Pointer()
        let controller = keysController(FakeDDC(), pointer: pointer)
        controller.start()
        await controller.load()
        #expect(!controller.handle(.brightnessUp))

        controller.usesBrightnessKeys = true
        #expect(controller.handle(.brightnessUp))
        // 0.4 is nearest 6/16, so one step up is 7/16.
        #expect(controller.displays[0].brightness == 7.0 / 16)
        #expect(controller.handle(.brightnessDown))
        #expect(controller.displays[0].brightness == 6.0 / 16)

        pointer.onExternal = false
        #expect(!controller.handle(.brightnessUp))
        #expect(controller.displays[0].brightness == 6.0 / 16)
        controller.stop()
    }

    @Test func keysWorkNextToScreensThatDontAnswer() async {
        // A Sidecar iPad or an Apple display alongside the DDC one doesn't get in the way.
        let pointer = Pointer()
        let controller = ExternalDisplaysController(
            defaults: store.defaults, ddc: FakeDDC(), screenNames: { ["Dell", "iPad"] },
            pointerScreenNeedsDDC: { pointer.onExternal }, isTrusted: { false }, showLevel: { _, _ in },
            workspaceCenter: NotificationCenter())
        controller.start()
        await controller.load()
        controller.usesBrightnessKeys = true
        #expect(controller.handle(.brightnessUp))
        // On the Apple display, macOS changes it itself.
        pointer.onExternal = false
        #expect(!controller.handle(.brightnessUp))
        controller.stop()
    }

    @Test func keysAreLeftAloneForDisplaysThatDontAnswer() async {
        let ddc = FakeDDC()
        await ddc.forget(7)
        let controller = keysController(ddc, pointer: Pointer())
        controller.start()
        await controller.load()
        controller.usesBrightnessKeys = true
        #expect(!controller.handle(.brightnessUp))
        controller.stop()
    }

    @Test func stepsStopAtTheEnds() async {
        let controller = keysController(FakeDDC(), pointer: Pointer())
        controller.start()
        await controller.load()
        for _ in 0..<20 { controller.step(.up) }
        #expect(controller.displays[0].brightness == 1)
        for _ in 0..<20 { controller.step(.down) }
        #expect(controller.displays[0].brightness == 0)
        controller.stop()
    }

    @Test func brightnessShortcutsFollowTheModule() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        state.setEnabled(.displaysAudio, true)
        #expect(state.shortcuts.isActive(DisplaysAudioController.brightnessUpShortcut))
        #expect(state.shortcuts.isActive(DisplaysAudioController.brightnessDownShortcut))
        state.setEnabled(.displaysAudio, false)
        #expect(!state.shortcuts.isActive(DisplaysAudioController.brightnessUpShortcut))
    }
    @Test func setPacketHasTheChecksum() {
        let packet = DDC.setPacket(code: DDC.brightness, value: 50)
        let body: [UInt8] = [0x84, 0x03, 0x10, 0x00, 0x32]
        let checksum = body.reduce(UInt8(0x6E ^ 0x51), ^)
        #expect(packet == body + [checksum])
        #expect(checksum == 0x9A)
    }

    @Test func getPacketHasTheChecksum() {
        #expect(DDC.getPacket(code: DDC.brightness) == [0x82, 0x01, 0x10, 0xFD])
    }

    @Test func parsesAReply() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x28, 0x00]
        #expect(DDC.parseReply(reply, code: DDC.brightness)?.current == 40)
        #expect(DDC.parseReply(reply, code: DDC.brightness)?.maximum == 100)
        #expect(DDC.parseReply(reply, code: 0x12) == nil)
        #expect(DDC.parseReply(Array(reply.prefix(5)), code: DDC.brightness) == nil)
        var unsupported = reply
        unsupported[3] = 0x01
        #expect(DDC.parseReply(unsupported, code: DDC.brightness) == nil)
    }

    @Test func readsDisplaysAndSendsTheLatestValue() async {
        let ddc = FakeDDC()
        let controller = ExternalDisplaysController(
            defaults: store.defaults, ddc: ddc, screenNames: { ["Studio Display"] }, isTrusted: { false }, showLevel: { _, _ in },
            workspaceCenter: NotificationCenter())
        controller.start()
        #expect(!controller.isLoaded)
        await controller.load()
        #expect(controller.displays.map(\.name) == ["Studio Display"])
        #expect(controller.displays.first?.brightness == 0.4)

        let display = controller.displays[0]
        controller.setBrightness(0.6, for: display)
        controller.setBrightness(0.7, for: display)
        controller.setBrightness(1.5, for: display)
        #expect(controller.displays[0].brightness == 1)
        while await ddc.values[7] != 1 { await Task.yield() }
        let writes = await ddc.writes
        #expect(writes.last == 1)
        #expect(writes.count <= 2)
    }

    private final class Pauses {
        var count = 0
    }

    private final class Screens {
        var name = "Dell"
    }

    private func wakingController(_ ddc: FakeDDC, pauses: Pauses, answerAfter: Int) -> ExternalDisplaysController {
        wakingController(ddc, pauses: pauses) { if $0 == answerAfter { await ddc.answer(8) } }
    }

    /// `onPause` gets the number of each pause, from 1.
    private func wakingController(_ ddc: FakeDDC, pauses: Pauses, onPause: @escaping (Int) async -> Void) -> ExternalDisplaysController {
        ExternalDisplaysController(
            defaults: store.defaults, ddc: ddc, screenNames: { ["Dell"] }, outputNeedsDDC: { true }, isTrusted: { false },
            showLevel: { _, _ in },
            pause: { _ in
                pauses.count += 1
                await onPause(pauses.count)
            }, workspaceCenter: NotificationCenter())
    }

    @Test func wakeReadsTheDisplaysAgainUntilTheyAnswer() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: false)
        let pauses = Pauses()
        let controller = wakingController(ddc, pauses: pauses, answerAfter: 3)
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()
        #expect(controller.displays.map(\.id) == [7])

        await ddc.sleepAndWake(as: 8)
        controller.systemDidWake()
        while pauses.count < 3 || controller.displays.first?.volume == nil { await Task.yield() }
        #expect(controller.displays.map(\.id) == [8])
        #expect(controller.displays.first?.volume == 0.5)
        // The tries stop once the display answers.
        for _ in 0..<100 { await Task.yield() }
        #expect(pauses.count == 3)

        #expect(controller.handle(.volumeUp))
        while await ddc.volumes[8] != 9.0 / 16 { await Task.yield() }
        controller.stop()
    }

    @Test func wakeGivesUpOnADisplayThatNeverAnswers() async {
        let ddc = FakeDDC()
        let pauses = Pauses()
        let controller = wakingController(ddc, pauses: pauses, answerAfter: 0)
        controller.start()
        await controller.load()
        await ddc.sleepAndWake(as: 8)
        controller.systemDidWake()
        for _ in 0..<1000 { await Task.yield() }
        #expect(pauses.count == ExternalDisplaysController.wakeRetryDelays.count)
        #expect(controller.displays.first?.brightness == nil)
        controller.stop()
    }

    @Test func aStepThatGoesNowhereIsSentToTheDisplayAgain() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: false)
        let controller = wakingController(ddc, pauses: Pauses(), answerAfter: 0)
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()

        // Back from sleep without a wake being heard: the step finds the connection gone, and is
        // sent again to the display found under its new ID.
        await ddc.sleepAndWake(as: 8)
        await ddc.answer(8)
        #expect(controller.handle(.volumeUp))
        while await ddc.volumes[8] != 9.0 / 16 { await Task.yield() }
        #expect(controller.displays.map(\.id) == [8])
        #expect(controller.displays.first?.volume == 9.0 / 16)

        #expect(controller.handle(.volumeUp))
        while await ddc.volumes[8] != 10.0 / 16 { await Task.yield() }
        controller.stop()
    }

    @Test func aStepThatGoesNowhereIsntSentToAnotherDisplay() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: false)
        let screens = Screens()
        let controller = ExternalDisplaysController(
            defaults: store.defaults, ddc: ddc, screenNames: { [screens.name] }, outputNeedsDDC: { true }, isTrusted: { false },
            showLevel: { _, _ in }, workspaceCenter: NotificationCenter())
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()

        await ddc.sleepAndWake(as: 8)
        await ddc.answer(8)
        screens.name = "LG"
        #expect(controller.handle(.volumeUp))
        while controller.displays.first?.id != 8 { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        #expect(await ddc.volumes[8] == 0.5)
        #expect(controller.displays.first?.volume == 0.5)
        controller.stop()
    }

    @Test func aMuteByTurningDownLastsThroughSleep() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: nil)
        let controller = wakingController(ddc, pauses: Pauses(), answerAfter: 1)
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()
        #expect(controller.handle(.mute))
        while await ddc.volumes[7] != 0 { await Task.yield() }

        await ddc.sleepAndWake(as: 8)
        controller.systemDidWake()
        while controller.displays.first?.id != 8 { await Task.yield() }
        #expect(controller.displays.first?.isMuted == true)
        #expect(controller.handle(.mute))
        #expect(controller.displays.first?.volume == 0.5)
        controller.stop()
    }

    @Test func aMuteMadeWhileTheDisplaysAreReadIsKept() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: nil)
        let controller = wakingController(ddc, pauses: Pauses(), answerAfter: 0)
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()

        await ddc.holdNextScan()
        let reading = Task { await controller.refresh() }
        while await !ddc.isHolding { await Task.yield() }
        #expect(controller.handle(.mute))
        await ddc.release()
        #expect(await reading.value != nil)
        #expect(controller.displays.first?.isMuted == true)
        #expect(controller.handle(.mute))
        #expect(controller.displays.first?.volume == 0.5)
        controller.stop()
    }

    @Test func aMuteMovesOnlyWhenTheDisplayCanBeToldApart() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: nil)
        await ddc.setValues([7: 0.4, 9: 0.6])
        let controller = wakingController(ddc, pauses: Pauses()) { _ in
            await ddc.answer(8)
            await ddc.answer(6)
        }
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()
        #expect(controller.handle(.mute))
        while await ddc.volumes[7] != 0 { await Task.yield() }

        // Both come back, in the other order: there's no knowing which was muted.
        await ddc.sleepAndWake(as: 8, from: 7)
        await ddc.sleepAndWake(as: 6, from: 9)
        controller.systemDidWake()
        while controller.displays.map(\.id) != [6, 8] { await Task.yield() }
        #expect(controller.displays.allSatisfy { !$0.isMuted })
        controller.stop()
    }

    @Test func aMuteLastsThroughAReadThatFoundNoDisplays() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: nil)
        let controller = wakingController(ddc, pauses: Pauses()) { count in
            if count == 2 {
                await ddc.setAsleep(false)
                await ddc.answer(8)
            }
        }
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()
        #expect(controller.handle(.mute))
        while await ddc.volumes[7] != 0 { await Task.yield() }

        await ddc.sleepAndWake(as: 8)
        await ddc.setAsleep(true)
        controller.systemDidWake()
        while controller.displays.first?.id != 8 { await Task.yield() }
        #expect(controller.displays.first?.isMuted == true)
        controller.stop()
    }

    @Test func wakeTriesUntilEveryDisplayAnswers() async {
        let ddc = FakeDDC()
        await ddc.setValues([7: 0.4, 9: 0.6])
        let pauses = Pauses()
        let controller = wakingController(ddc, pauses: pauses) { count in
            if count == 1 { await ddc.answer(8) }
            if count == 3 { await ddc.answer(10) }
        }
        controller.start()
        await controller.load()
        await ddc.sleepAndWake(as: 8, from: 7)
        await ddc.sleepAndWake(as: 10, from: 9)
        controller.systemDidWake()
        while controller.displays.map(\.id) != [8, 10] || controller.displays.map(\.brightness) != [0.4, 0.6] {
            await Task.yield()
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(pauses.count == 3)
        controller.stop()
    }

    @Test func aMuteThatGoesNowhereIsSentToTheDisplayAgain() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: false)
        let controller = wakingController(ddc, pauses: Pauses(), answerAfter: 0)
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()

        await ddc.sleepAndWake(as: 8)
        await ddc.answer(8)
        #expect(controller.handle(.mute))
        while await ddc.mutes[8] != true { await Task.yield() }
        #expect(controller.displays.first?.id == 8)
        #expect(controller.displays.first?.isMuted == true)
        controller.stop()
    }

    @Test func aLevelChangedWhileTheDisplaysAreReadIsKept() async {
        let ddc = FakeDDC()
        let controller = wakingController(ddc, pauses: Pauses(), answerAfter: 0)
        controller.start()
        await controller.load()

        await ddc.holdNextRead()
        let reading = Task { await controller.refresh() }
        while await !ddc.isHolding { await Task.yield() }
        controller.setBrightness(0.7, for: controller.displays[0])
        while await ddc.values[7] != 0.7 { await Task.yield() }
        await ddc.release()
        // The display answered 0.4, from before the change, which isn't shown.
        #expect(await reading.value?.first?.brightness == 0.4)
        #expect(controller.displays.first?.brightness == 0.7)
        controller.stop()
    }

    @Test func aKeyPressedDuringAWakeReadIsntTakenForAnAnswer() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: false)
        let pauses = Pauses()
        let controller = wakingController(ddc, pauses: pauses) { if $0 == 2 { await ddc.answer(7) } }
        controller.start()
        await controller.load()

        // The screens wake: same display, not answering yet, and a brightness key while it's read.
        await ddc.forget(7)
        await ddc.holdNextRead()
        controller.systemDidWake()
        while await !ddc.isHolding { await Task.yield() }
        controller.setBrightness(0.7, for: controller.displays[0])
        await ddc.release()
        while pauses.count < 2 || controller.displays.first?.volume == nil { await Task.yield() }
        #expect(controller.displays.first?.volume == 0.5)
        for _ in 0..<100 { await Task.yield() }
        #expect(pauses.count == 2)
        controller.stop()
    }

    @Test func aMuteDoesntMoveToAnotherDisplay() async {
        let ddc = FakeDDC()
        await ddc.addSpeakers(volume: 0.5, mute: nil)
        let screens = Screens()
        let controller = ExternalDisplaysController(
            defaults: store.defaults, ddc: ddc, screenNames: { [screens.name] }, outputNeedsDDC: { true }, isTrusted: { false },
            showLevel: { _, _ in }, pause: { _ in await ddc.answer(8) }, workspaceCenter: NotificationCenter())
        controller.usesVolumeKeys = true
        controller.start()
        await controller.load()
        #expect(controller.handle(.mute))
        while await ddc.volumes[7] != 0 { await Task.yield() }

        // Another monitor is plugged in while the Mac sleeps.
        await ddc.sleepAndWake(as: 8)
        screens.name = "LG"
        controller.systemDidWake()
        while controller.displays.first?.id != 8 { await Task.yield() }
        #expect(controller.displays.first?.isMuted == false)
        controller.stop()
    }

    @Test func aMissedWriteKeepsTheLevelShown() async {
        let ddc = FakeDDC()
        let controller = wakingController(ddc, pauses: Pauses(), answerAfter: 0)
        controller.start()
        await controller.load()
        #expect(await ddc.scans == 1)

        await ddc.missNextWrite()
        controller.setBrightness(0.7, for: controller.displays[0])
        // Only the displays are looked for: the one written to is still there, so its levels aren't read again.
        while await ddc.scans < 2 { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        #expect(await ddc.scans == 2)
        #expect(controller.displays.first?.brightness == 0.7)
        controller.stop()
    }

    @Test func aRefreshAfterStopDoesntLand() async {
        let controller = ExternalDisplaysController(
            defaults: store.defaults, ddc: FakeDDC(), screenNames: { ["Studio Display"] }, isTrusted: { false }, showLevel: { _, _ in },
            workspaceCenter: NotificationCenter())
        controller.start()
        controller.stop()
        await controller.refresh()
        #expect(controller.displays.isEmpty)
        #expect(!controller.isLoaded)
    }
}
