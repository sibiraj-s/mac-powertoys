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

    var symbol: String {
        switch transport {
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
    /// Calls `onChange` on the main thread whenever devices come and go or a default changes.
    func observe(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

final class LiveAudioDevices: AudioDeviceAccess {
    /// Input volume before a mute that had to turn the volume down, by device UID, so it comes
    /// back after a relaunch too.
    static let savedVolumesKey = "displaysAudio.savedInputVolumes"

    private let defaults: UserDefaults
    private let listener = AudioListener(
        watching: [
            kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
        ])
    private var inputListener: AudioListener?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func devices() -> [AudioDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return AudioProperty.array(system, AudioProperty.address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
            .compactMap(Self.device)
    }

    private static func device(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = AudioProperty.string(id, AudioProperty.address(kAudioDevicePropertyDeviceUID)),
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
        let elements = [kAudioObjectPropertyElementMain] + (1...2).map { AudioObjectPropertyElement($0) }
        return !elements.contains {
            AudioProperty.isSettable(
                id, AudioProperty.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: $0))
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
        guard let uid = AudioProperty.string(id, AudioProperty.address(kAudioDevicePropertyDeviceUID)) else { return false }
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
