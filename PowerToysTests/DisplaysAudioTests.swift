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

    func devices() -> [AudioDevice] { all }
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
    var outputUID: String? = "speakers"

    func processes() -> [AudioProcess] { list }
    func app(for pid: pid_t) -> AudioAppInfo? { owners[pid] }
    func defaultOutputUID() -> String? { outputUID }
    func observe(_ onChange: @escaping @MainActor () -> Void) {}
    func stopObserving() {}
}

final class FakeTap: AppVolumeTapping {
    let processes: [AudioObjectID]
    let outputUID: String
    var gain: Float
    var isInvalidated = false

    init(processes: [AudioObjectID], outputUID: String, gain: Float) {
        self.processes = processes
        self.outputUID = outputUID
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

    func displays(names: [String]) -> [ExternalDisplay] {
        values.keys.sorted().map { ExternalDisplay(id: $0, name: names.first ?? "Display") }
    }
    func value(_ control: DDCControl, of id: UInt64) -> Double? {
        switch control {
        case .brightness: unreadable.contains(id) ? nil : values[id]
        case .volume: volumes[id]
        }
    }
    /// The display stays, but no longer says its brightness.
    func forget(_ id: UInt64) { unreadable.insert(id) }
    private var unreadable: Set<UInt64> = []
    func setValue(_ value: Double, _ control: DDCControl, of id: UInt64) async -> Bool {
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
        mutes[id] = muted
        return true
    }
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
                makeTap: { FakeTap(processes: $0, outputUID: $1, gain: $2) }),
            externalDisplays: ExternalDisplaysController(
                defaults: defaults, ddc: FakeDDC(), screenNames: { ["Studio Display"] }, isTrusted: { false }, showLevel: { _, _ in }))
    }
}

struct AudioDevicesTests {
    let store = TestDefaults()

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
                let tap = FakeTap(processes: $0, outputUID: $1, gain: $2)
                taps.value.append(tap)
                return tap
            })
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
        #expect(taps.value[0].outputUID == "speakers")
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

        processes.outputUID = "headset"
        controller.refresh()
        #expect(taps.value.count == 2)
        #expect(taps.value[0].isInvalidated)
        #expect(taps.value[1].outputUID == "headset")

        processes.list.append(AudioProcess(objectID: 40, pid: 200, isPlaying: true))
        controller.refresh()
        #expect(taps.value.count == 3)
        #expect(taps.value[2].processes == [10, 20, 40])
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
            })
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
            })
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
            runningBundleIDs: { running }, showLevel: { _, _ in })
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
            pointerScreenNeedsDDC: { pointer.onExternal }, isTrusted: { false }, showLevel: { _, _ in })
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
            defaults: store.defaults, ddc: ddc, screenNames: { ["Studio Display"] }, isTrusted: { false }, showLevel: { _, _ in })
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

    @Test func aRefreshAfterStopDoesntLand() async {
        let controller = ExternalDisplaysController(
            defaults: store.defaults, ddc: FakeDDC(), screenNames: { ["Studio Display"] }, isTrusted: { false }, showLevel: { _, _ in })
        controller.start()
        controller.stop()
        await controller.refresh()
        #expect(controller.displays.isEmpty)
        #expect(!controller.isLoaded)
    }
}
