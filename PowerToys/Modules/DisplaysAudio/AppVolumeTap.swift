import CoreAudio
import Foundation
import Synchronization

/// One app's sound, taken from its processes and played through to the output at its own volume.
protocol AppVolumeTapping: AnyObject {
    func setGain(_ gain: Float)
    func invalidate()
}

struct AppVolumeTapError: LocalizedError {
    let step: String
    let status: OSStatus

    var errorDescription: String? { "Couldn't \(step) (error \(status))." }
}

/// The volume the audio thread reads, without locks.
nonisolated final class AtomicGain: Sendable {
    private let bits: Atomic<UInt32>

    init(_ value: Float) {
        bits = Atomic(value.bitPattern)
    }

    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// A Core Audio process tap that mutes the app's own playback, and a private aggregate device
/// that plays what the tap hears through the output device, scaled by the gain.
nonisolated final class AppVolumeTap: AppVolumeTapping {
    static let uidPrefix = "dev.sibiraj.powertoys.appvolume"

    private let gain: AtomicGain
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.sibiraj.powertoys.appvolume", qos: .userInteractive)

    init(processes: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.gain = AtomicGain(gain)
        do {
            try start(processes: processes, outputUID: outputUID)
        } catch {
            invalidate()
            throw error
        }
    }

    private func start(processes: [AudioObjectID], outputUID: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "PowerToys app volume"
        description.isPrivate = true
        // The app is silent only while the tap is read, so if playing through stops, its sound comes back.
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "listen to the app")

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PowerToys app volume",
            kAudioAggregateDeviceUIDKey: "\(Self.uidPrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID), "set up playback")
        // The aggregate's input is the output device's own microphone, if it has one (a headset),
        // followed by the tap. Only the tap is played.
        let tapChannels = Int(
            AudioProperty.get(tapID, AudioProperty.address(kAudioTapPropertyFormat), as: AudioStreamBasicDescription.self)?
                .mChannelsPerFrame ?? 2)
        let skipped = max(Self.inputChannels(of: aggregateID) - tapChannels, 0)
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, Self.ioBlock(gain: gain, skipping: skipped)),
            "set up playback")
        try check(AudioDeviceStart(aggregateID, procID), "start playback")
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AppVolumeTapError(step: step, status: status) }
    }

    private static func ioBlock(gain: AtomicGain, skipping: Int) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            mix(input, into: output, gain: gain.value, skippingInputChannels: skipping)
        }
    }

    private static func inputChannels(of device: AudioObjectID) -> Int {
        var address = AudioProperty.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    nonisolated func setGain(_ gain: Float) {
        self.gain.value = gain
    }

    nonisolated func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Copies float samples from the tap's buffers to the output's, scaled by `gain`, ignoring the
    /// first `skippingInputChannels` input channels (another device's microphone). Output channels
    /// beyond the input's repeat it (mono to both speakers, stereo across surround); frames the
    /// input lacks are silence. Runs on the audio thread, so it allocates nothing.
    static func mix(
        _ input: UnsafePointer<AudioBufferList>, into output: UnsafeMutablePointer<AudioBufferList>, gain: Float,
        skippingInputChannels skipped: Int = 0
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var inputChannels = -skipped
        for buffer in inputs where buffer.mData != nil { inputChannels += Int(buffer.mNumberChannels) }

        var outputChannel = 0
        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            let stride = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / stride
            let destination = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<stride {
                var copied = 0
                if inputChannels > 0 {
                    // Find which input buffer and channel feed this output channel.
                    var wanted = skipped + (outputChannel + channel) % inputChannels
                    for source in inputs {
                        guard let sourceData = source.mData else { continue }
                        let sourceStride = Int(source.mNumberChannels)
                        if wanted >= sourceStride {
                            wanted -= sourceStride
                            continue
                        }
                        let samples = sourceData.assumingMemoryBound(to: Float.self)
                        copied = min(frames, Int(source.mDataByteSize) / MemoryLayout<Float>.size / sourceStride)
                        for frame in 0..<copied {
                            destination[frame * stride + channel] = samples[frame * sourceStride + wanted] * gain
                        }
                        break
                    }
                }
                for frame in copied..<frames { destination[frame * stride + channel] = 0 }
            }
            outputChannel += stride
        }
    }
}

/// System Audio Recording, which taps need. macOS has no public check for it; the private one
/// System Settings uses is looked up at run time. Without it, there's no telling, so taps are tried.
nonisolated enum AudioCaptureAccess {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }
    private nonisolated(unsafe) static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// Granted, denied, or unknown when it hasn't been asked yet.
    static func status() -> PermissionStatus {
        guard let symbol = dlsym(framework, "TCCAccessPreflight") else { return .granted }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows macOS's prompt; `answered` runs on the main actor once it's answered.
    static func request(answered: @escaping @MainActor @Sendable () -> Void = {}) {
        guard let symbol = dlsym(framework, "TCCAccessRequest") else {
            Task { @MainActor in answered() }
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { _ in
            Task { @MainActor in answered() }
        }
    }
}
