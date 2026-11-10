import CoreAudio
import Foundation

/// Reads and writes Core Audio object properties.
nonisolated enum AudioProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as type: T.Type = T.self) -> T? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    static func array<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of type: T.Type = T.self) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        let typed = pointer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func dictionary(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [String: Any] {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return [:] }
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        var value: Unmanaged<CFDictionary>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return [:] }
        return value.takeRetainedValue() as? [String: Any] ?? [:]
    }

    static func strings(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [String] {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return [] }
        var size = UInt32(MemoryLayout<CFArray?>.size)
        var value: Unmanaged<CFArray>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return [] }
        return value.takeRetainedValue() as? [String] ?? []
    }

    /// Sets a Core Foundation value, such as a string or an array.
    @discardableResult
    static func set(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, value: CFTypeRef) -> Bool {
        var address = address
        var value = value
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<CFTypeRef>.size), $0) == noErr
        }
    }

    @discardableResult
    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
}

enum AudioDirection: Sendable {
    case output, input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }

    var defaultSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let hasOutput: Bool
    let hasInput: Bool
    let transport: UInt32

    /// Several devices made into one, which can't be made part of another.
    var isAggregate: Bool { transport == kAudioDeviceTransportTypeAggregate }

    /// Connected by wire, so its clock is steady; not Bluetooth, AirPlay or a virtual device.
    var isWired: Bool {
        [
            kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypeThunderbolt,
        ].contains(transport)
    }

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeAggregate: "hifispeaker.2"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
        case kAudioDeviceTransportTypeUSB: "cable.connector"
        default: "speaker.wave.2"
        }
    }
}

/// The sound devices, which are the defaults, and the microphone's mute.
protocol AudioDeviceAccess: AnyObject {
    func devices() -> [AudioDevice]
    func defaultDevice(_ direction: AudioDirection) -> AudioObjectID?
    @discardableResult func setDefaultDevice(_ id: AudioObjectID, for direction: AudioDirection) -> Bool
    func isInputMuted(_ id: AudioObjectID) -> Bool
    @discardableResult func setInputMuted(_ muted: Bool, _ id: AudioObjectID) -> Bool
    /// The UIDs of the outputs the multi-output device plays through, or empty when there's none.
    func multiOutputMembers() -> [String]
    /// Makes the multi-output device play through `uids`, keeping time by `clock`, or changes the one
    /// there is in place so it plays on. Nil if Core Audio refused, leaving any there was as it was.
    func setMultiOutput(_ uids: [String], clock: String) -> AudioObjectID?
    func removeMultiOutput()
    /// An output's volume, 0–1, or nil when macOS can't change it.
    func outputVolume(_ id: AudioObjectID) -> Float?
    @discardableResult func setOutputVolume(_ volume: Float, _ id: AudioObjectID) -> Bool
    /// Calls `onChange` when one of these outputs' volumes changes, in place of the ones
    /// watched before. Headphones' own buttons count only while they play on their own: in a
    /// multi-output device, macOS isn't told of those changes.
    func watchOutputVolumes(_ ids: [AudioObjectID], onChange: @escaping @MainActor () -> Void)
    /// Calls `onChange` on the main thread whenever devices come and go or a default changes.
    func observe(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

final class LiveAudioDevices: AudioDeviceAccess {
    /// Input volume before a mute that had to turn the volume down, by device UID, so it comes
    /// back after a relaunch too.
    static let savedVolumesKey = "displaysAudio.savedInputVolumes"
    /// The multi-output device made here. It's public, so it can be the default output, and Core
    /// Audio keeps it after the app quits; it's found again by this UID.
    nonisolated static let multiOutputUID = "dev.sibiraj.powertoys.multioutput"

    private let defaults: UserDefaults
    private let listener = AudioListener(
        watching: [
            kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
        ])
    private var inputListener: AudioListener?
    /// The volumes of the outputs with sliders, by device.
    private var volumeListeners: [AudioObjectID: AudioListener] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func devices() -> [AudioDevice] {
        Self.allDeviceIDs().compactMap(Self.device)
    }

    private nonisolated static func allDeviceIDs() -> [AudioObjectID] {
        AudioProperty.array(
            AudioObjectID(kAudioObjectSystemObject), AudioProperty.address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
    }

    nonisolated static func uid(of id: AudioObjectID) -> String? {
        AudioProperty.string(id, AudioProperty.address(kAudioDevicePropertyDeviceUID))
    }

    /// Any device, hidden or not, by UID.
    nonisolated static func deviceID(uid: String) -> AudioObjectID? {
        var address = AudioProperty.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// The connected outputs a multi-output device plays the same sound through, the one keeping
    /// time first, or nil when `uid` isn't one. That's this app's or one made in Audio MIDI Setup:
    /// both are stacked aggregates. Other aggregates spread channels across their devices instead,
    /// so they're played through as they are. Microphones in one are left out.
    nonisolated static func connectedSubDevices(ofDeviceWithUID uid: String) -> [String]? {
        guard let id = deviceID(uid: uid),
            AudioProperty.dictionary(id, AudioProperty.address(kAudioAggregateDevicePropertyComposition))[
                kAudioAggregateDeviceIsStackedKey] as? Int == 1
        else { return nil }
        let members = AudioProperty.strings(id, AudioProperty.address(kAudioAggregateDevicePropertyFullSubDeviceList))
        guard !members.isEmpty else { return nil }
        let outputs = members.filter { member in
            deviceID(uid: member).map {
                !AudioProperty.array(
                    $0, AudioProperty.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput), of: AudioStreamID.self
                )
                .isEmpty
            } ?? false
        }
        let clock = AudioProperty.string(id, AudioProperty.address(kAudioAggregateDevicePropertyMainSubDevice))
        return outputs.filter { $0 == clock } + outputs.filter { $0 != clock }
    }

    private static func device(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = uid(of: id),
            let name = AudioProperty.string(id, AudioProperty.address(kAudioObjectPropertyName))
        else { return nil }
        // Aggregates the system and this app make for themselves aren't for picking.
        if uid.hasPrefix("CADefaultDeviceAggregate") || uid.hasPrefix(AppVolumeTap.uidPrefix) { return nil }
        if AudioProperty.get(id, AudioProperty.address(kAudioDevicePropertyIsHidden), as: UInt32.self) == 1 { return nil }
        func canBeDefault(_ direction: AudioDirection) -> Bool {
            !AudioProperty.array(id, AudioProperty.address(kAudioDevicePropertyStreams, scope: direction.scope), of: AudioStreamID.self)
                .isEmpty
                && AudioProperty.get(
                    id, AudioProperty.address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: direction.scope), as: UInt32.self)
                    != 0
        }
        let device = AudioDevice(
            id: id, uid: uid, name: name, hasOutput: canBeDefault(.output), hasInput: canBeDefault(.input),
            transport: AudioProperty.get(id, AudioProperty.address(kAudioDevicePropertyTransportType), as: UInt32.self) ?? 0)
        return device.hasOutput || device.hasInput ? device : nil
    }

    func defaultDevice(_ direction: AudioDirection) -> AudioObjectID? {
        let id = AudioProperty.get(
            AudioObjectID(kAudioObjectSystemObject), AudioProperty.address(direction.defaultSelector), as: AudioObjectID.self)
        return id == kAudioObjectUnknown ? nil : id
    }

    func setDefaultDevice(_ id: AudioObjectID, for direction: AudioDirection) -> Bool {
        AudioProperty.set(AudioObjectID(kAudioObjectSystemObject), AudioProperty.address(direction.defaultSelector), id)
    }

    /// Whether sound plays through a display's speakers that macOS has no volume for, so it's left
    /// to the display itself.
    func outputNeedsDDC() -> Bool {
        guard let id = defaultDevice(.output),
            let transport = AudioProperty.get(id, AudioProperty.address(kAudioDevicePropertyTransportType), as: UInt32.self),
            [kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI].contains(transport)
        else { return false }
        return Self.outputVolumeAddresses(id).isEmpty
    }

    // MARK: Multi-output

    func multiOutputMembers() -> [String] {
        guard let id = Self.deviceID(uid: Self.multiOutputUID) else { return [] }
        return AudioProperty.strings(id, AudioProperty.address(kAudioAggregateDevicePropertyFullSubDeviceList))
    }

    func setMultiOutput(_ uids: [String], clock: String) -> AudioObjectID? {
        guard let id = Self.deviceID(uid: Self.multiOutputUID) else { return makeMultiOutput(uids, clock: clock) }
        // Changed in place: destroying it while it plays would send the sound elsewhere for a moment.
        let list = AudioProperty.address(kAudioAggregateDevicePropertyFullSubDeviceList)
        let previous = AudioProperty.strings(id, list)
        guard AudioProperty.set(id, list, value: uids as CFArray) else { return nil }
        guard AudioProperty.set(id, AudioProperty.address(kAudioAggregateDevicePropertyMainSubDevice), value: clock as CFString) else {
            // Put back as it was, so a refusal leaves it playing as before.
            AudioProperty.set(id, list, value: previous as CFArray)
            return nil
        }
        // Sub-devices other than the clock follow it, correcting their drift.
        for sub in AudioProperty.array(id, AudioProperty.address(kAudioObjectPropertyOwnedObjects), of: AudioObjectID.self)
        where AudioProperty.get(sub, AudioProperty.address(kAudioObjectPropertyClass), as: AudioClassID.self) == kAudioSubDeviceClassID {
            let follows = Self.uid(of: sub) != clock
            AudioProperty.set(sub, AudioProperty.address(kAudioSubDevicePropertyDriftCompensation), UInt32(follows ? 1 : 0))
        }
        return id
    }

    private func makeMultiOutput(_ uids: [String], clock: String) -> AudioObjectID? {
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(AppInfo.name) Multi-Output",
            kAudioAggregateDeviceUIDKey: Self.multiOutputUID,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: clock,
            kAudioAggregateDeviceSubDeviceListKey: uids.map {
                [kAudioSubDeviceUIDKey: $0, kAudioSubDeviceDriftCompensationKey: $0 != clock] as [String: Any]
            },
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    func removeMultiOutput() {
        if let id = Self.deviceID(uid: Self.multiOutputUID) { AudioHardwareDestroyAggregateDevice(id) }
    }

    // MARK: Output volume

    /// The main volume, or else each of the first two channels'.
    private static func outputVolumeAddresses(_ id: AudioObjectID) -> [AudioObjectPropertyAddress] {
        let addresses = ([kAudioObjectPropertyElementMain] + (1...2).map { AudioObjectPropertyElement($0) }).map {
            AudioProperty.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: $0)
        }
        let settable = addresses.filter { AudioProperty.isSettable(id, $0) }
        return settable.first?.mElement == kAudioObjectPropertyElementMain ? [settable[0]] : settable
    }

    func outputVolume(_ id: AudioObjectID) -> Float? {
        let volumes = Self.outputVolumeAddresses(id).compactMap { AudioProperty.get(id, $0, as: Float32.self) }
        return volumes.isEmpty ? nil : volumes.max()
    }

    /// With a volume per channel, the loudest is set to `volume` and the rest keep their share of it,
    /// so a balance set in System Settings stays.
    func setOutputVolume(_ volume: Float, _ id: AudioObjectID) -> Bool {
        let addresses = Self.outputVolumeAddresses(id)
        let current = addresses.compactMap { AudioProperty.get(id, $0, as: Float32.self) }
        let loudest = current.max() ?? 0
        // A channel that couldn't be read leaves no balance to keep, rather than counting as silent.
        let volumes =
            current.count == addresses.count && loudest > 0 ? current.map { volume * $0 / loudest } : addresses.map { _ in volume }
        return !addresses.isEmpty && zip(addresses, volumes).map { AudioProperty.set(id, $0, Float32($1)) }.allSatisfy { $0 }
    }

    func watchOutputVolumes(_ ids: [AudioObjectID], onChange: @escaping @MainActor () -> Void) {
        let wanted = Set(ids)
        for (id, listener) in volumeListeners where !wanted.contains(id) {
            listener.stop()
            volumeListeners[id] = nil
        }
        for id in wanted where volumeListeners[id] == nil {
            let listener = AudioListener(object: id, watching: Self.outputVolumeAddresses(id))
            listener.start(onChange)
            volumeListeners[id] = listener
        }
    }

    // MARK: Mute

    private static let inputMute = AudioProperty.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)

    /// Channels with their own input volume: the main one, or else each channel.
    private static func volumeElements(_ id: AudioObjectID) -> [AudioObjectPropertyElement] {
        let elements = [kAudioObjectPropertyElementMain] + (1...8).map { AudioObjectPropertyElement($0) }
        let settable = elements.filter { AudioProperty.isSettable(id, volumeAddress($0)) }
        return settable.first == kAudioObjectPropertyElementMain ? [kAudioObjectPropertyElementMain] : settable
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioProperty.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element)
    }

    func isInputMuted(_ id: AudioObjectID) -> Bool {
        if AudioProperty.isSettable(id, Self.inputMute) {
            return AudioProperty.get(id, Self.inputMute, as: UInt32.self) == 1
        }
        let elements = Self.volumeElements(id)
        return !elements.isEmpty && elements.allSatisfy { AudioProperty.get(id, Self.volumeAddress($0), as: Float32.self) == 0 }
    }

    func setInputMuted(_ muted: Bool, _ id: AudioObjectID) -> Bool {
        if AudioProperty.isSettable(id, Self.inputMute) {
            return AudioProperty.set(id, Self.inputMute, UInt32(muted ? 1 : 0))
        }
        // Without a mute control, turn the input volume down, and back up to where it was.
        guard let uid = Self.uid(of: id) else { return false }
        let elements = Self.volumeElements(id)
        guard !elements.isEmpty else { return false }
        var saved = defaults.dictionary(forKey: Self.savedVolumesKey) as? [String: [Float]] ?? [:]
        let volumes: [Float32]
        if muted {
            let current = elements.map { AudioProperty.get(id, Self.volumeAddress($0), as: Float32.self) ?? 1 }
            if current.contains(where: { $0 > 0 }) { saved[uid] = current }
            volumes = elements.map { _ in 0 }
        } else {
            let previous = saved[uid] ?? []
            volumes = elements.indices.map { $0 < previous.count ? previous[$0] : 0.75 }
            saved[uid] = nil
        }
        defaults.set(saved, forKey: Self.savedVolumesKey)
        // Done only if every channel took its volume, so a mic that's still live isn't said to be muted.
        return zip(elements, volumes).map { AudioProperty.set(id, Self.volumeAddress($0), $1) }.allSatisfy { $0 }
    }

    // MARK: Changes

    /// Also watches the default input's mute and volume, so a mute from a headset button or
    /// another app shows up here; that listener moves along when the default input changes.
    func observe(_ onChange: @escaping @MainActor () -> Void) {
        listener.start { [weak self] in
            self?.watchDefaultInput(onChange)
            onChange()
        }
        watchDefaultInput(onChange)
    }

    func stopObserving() {
        listener.stop()
        inputListener?.stop()
        inputListener = nil
        for listener in volumeListeners.values { listener.stop() }
        volumeListeners = [:]
    }

    private func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) {
        let input = defaultDevice(.input)
        guard input != inputListener?.object else { return }
        inputListener?.stop()
        inputListener = input.map { id in
            let listener = AudioListener(object: id, watching: [Self.inputMute] + Self.volumeElements(id).map(Self.volumeAddress))
            listener.start(onChange)
            return listener
        }
    }
}

/// Calls back on the main actor when any of an audio object's properties at `addresses` changes.
final class AudioListener {
    let object: AudioObjectID
    private let addresses: [AudioObjectPropertyAddress]
    private var block: AudioObjectPropertyListenerBlock?

    init(object: AudioObjectID, watching addresses: [AudioObjectPropertyAddress]) {
        self.object = object
        self.addresses = addresses
    }

    /// Watches the system object's `selectors`.
    convenience init(watching selectors: [AudioObjectPropertySelector]) {
        self.init(object: AudioObjectID(kAudioObjectSystemObject), watching: selectors.map { AudioProperty.address($0) })
    }

    func start(_ onChange: @escaping @MainActor () -> Void) {
        stop()
        let block = Self.listenerBlock(onChange)
        for address in addresses {
            var address = address
            AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
        }
        self.block = block
    }

    func stop() {
        guard let block else { return }
        for address in addresses {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        self.block = nil
    }

    /// Made outside the main actor: Core Audio calls it on the queue given, without Swift's checks.
    private nonisolated static func listenerBlock(_ onChange: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in MainActor.assumeIsolated { onChange() } }
    }
}
