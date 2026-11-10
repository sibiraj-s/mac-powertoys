import AppKit
import CoreAudio
import Observation

/// A process Core Audio knows about.
struct AudioProcess: Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let isPlaying: Bool
}

/// An app and the processes that play its sound, such as a browser's helpers.
struct AudioApp: Identifiable, Hashable {
    /// Its bundle ID, which volumes are saved under.
    let id: String
    let name: String
    let pid: pid_t
    var processes: [AudioObjectID]
    var isPlaying: Bool
}

/// Who an audio process belongs to.
struct AudioAppInfo: Hashable {
    let bundleID: String
    let name: String
    let pid: pid_t
}

/// The processes with audio, and the app each belongs to.
protocol AudioProcessAccess: AnyObject {
    func processes() -> [AudioProcess]
    /// The app a process plays for: itself, or the app responsible for a helper.
    func app(for pid: pid_t) -> AudioAppInfo?
    /// The devices the default output plays through, by UID: itself, or a multi-output device's
    /// connected outputs. Empty when there's none.
    func defaultOutputs() -> [String]
    func observe(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

struct AppVolumeSetting: Codable, Equatable {
    var volume: Float = 1
    var isMuted = false

    var gain: Float { isMuted ? 0 : volume }
    var isUnchanged: Bool { gain == 1 }
}

/// Volume and mute for each app, by playing its sound through a tap only while it isn't at 100%.
@Observable
final class AppVolumeController {
    /// Apps playing sound, or set to a volume of their own, by name.
    private(set) var apps: [AudioApp] = []
    private(set) var settings: [String: AppVolumeSetting]
    /// Why an app's volume couldn't be changed, by app.
    private(set) var errors: [String: String] = [:]

    static let settingsKey = "displaysAudio.appVolumes"

    private let defaults: UserDefaults
    @ObservationIgnored private let system: any AudioProcessAccess
    @ObservationIgnored private let access: () -> PermissionStatus
    /// Shows macOS's prompt, then calls back on the main actor once it's answered.
    @ObservationIgnored private let requestAccess: (@escaping @MainActor @Sendable () -> Void) -> Void
    @ObservationIgnored private let openAccessSettings: () -> Void
    /// Asked or sent to System Settings once per run, not on every step of a slider.
    @ObservationIgnored private var hasAskedForAccess = false
    @ObservationIgnored private let makeTap: ([AudioObjectID], [String], Float) throws -> any AppVolumeTapping
    @ObservationIgnored private var taps: [String: (processes: [AudioObjectID], outputs: [String], tap: any AppVolumeTapping)] = [:]
    @ObservationIgnored private var isRunning = false
    /// Taps that couldn't be made, and for what, so they're tried again only once something changes
    /// rather than on every refresh.
    @ObservationIgnored private var failures: [String: (processes: [AudioObjectID], outputs: [String], error: String)] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Apps changed in this run, which stay listed even once back at 100%, so a row being dragged
    /// doesn't disappear when it gets there.
    @ObservationIgnored private var changed: Set<String> = []

    init(
        defaults: UserDefaults,
        system: any AudioProcessAccess = LiveAudioProcesses(),
        access: @escaping () -> PermissionStatus,
        requestAccess: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void,
        openAccessSettings: @escaping () -> Void,
        makeTap: @escaping ([AudioObjectID], [String], Float) throws -> any AppVolumeTapping = {
            try AppVolumeTap(processes: $0, outputs: $1, gain: $2)
        }
    ) {
        self.defaults = defaults
        self.system = system
        self.access = access
        self.requestAccess = requestAccess
        self.openAccessSettings = openAccessSettings
        self.makeTap = makeTap
        settings =
            defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode([String: AppVolumeSetting].self, from: $0) }
            ?? [:]
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        system.observe { [weak self] in self?.refresh() }
        refresh()
    }

    func stop() {
        isRunning = false
        system.stopObserving()
        for entry in taps.values { entry.tap.invalidate() }
        taps = [:]
        failures = [:]
        apps = []
        saveTask?.cancel()
        save()
    }

    func setting(for app: AudioApp) -> AppVolumeSetting {
        settings[app.id] ?? AppVolumeSetting()
    }

    func setVolume(_ volume: Float, for app: AudioApp) {
        update(app) { $0.volume = min(max(volume, 0), 1) }
    }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        update(app) { $0.isMuted = muted }
    }

    private func update(_ app: AudioApp, _ change: (inout AppVolumeSetting) -> Void) {
        let wasUnchanged = setting(for: app).isUnchanged
        var setting = setting(for: app)
        change(&setting)
        changed.insert(app.id)
        settings[app.id] = setting.isUnchanged ? nil : setting
        scheduleSave()
        // While a slider moves, only the tap's gain changes. Taps are made or ended only when the
        // app starts or stops needing one, not on every step, even when one couldn't be made.
        taps[app.id]?.tap.setGain(setting.gain)
        // Also for an app saved below 100% in an earlier run, whose slider never crosses 100% now.
        if !setting.isUnchanged { askForAccessIfNeeded() }
        guard setting.isUnchanged != wasUnchanged else { return }
        // Newly set apart from 100% is worth another try at a tap that failed.
        failures[app.id] = nil
        refresh()
    }

    /// Saves once a slider settles rather than on every step of it.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            self?.save()
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
    }

    private func askForAccessIfNeeded() {
        guard !hasAskedForAccess else { return }
        switch access() {
        case .granted: return
        case .unknown:
            hasAskedForAccess = true
            // Taps made while the prompt was up hear nothing, so they're made again once it's answered.
            requestAccess { [weak self] in self?.retap() }
        case .denied:
            hasAskedForAccess = true
            openAccessSettings()
        }
    }

    private func retap() {
        for entry in taps.values { entry.tap.invalidate() }
        taps = [:]
        failures = [:]
        refresh()
    }

    /// Reads the processes again and starts, changes or ends taps to match.
    func refresh() {
        guard isRunning else { return }
        let grouped = Self.group(system.processes(), app: system.app(for:))
        apps = grouped.filter { $0.isPlaying || settings[$0.id] != nil || changed.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        reconcile(grouped)
    }

    private func reconcile(_ grouped: [AudioApp]) {
        let output = system.defaultOutputs()
        let status = access()
        // macOS's check can keep answering "not asked" after access was allowed, and making the tap
        // asks anyway when it's needed, so only a refusal stops it.
        let isAllowed = status != .denied
        var wanted: [String: AudioApp] = [:]
        if !output.isEmpty, isAllowed {
            for app in grouped where !setting(for: app).isUnchanged { wanted[app.id] = app }
        }
        for (id, existing) in taps {
            guard let app = wanted[id], existing.processes == app.processes, existing.outputs == output else {
                existing.tap.invalidate()
                taps[id] = nil
                continue
            }
            existing.tap.setGain(setting(for: app).gain)
        }
        var errors: [String: String] = [:]
        for (id, app) in wanted where taps[id] == nil {
            if let failure = failures[id], failure.processes == app.processes, failure.outputs == output {
                errors[id] = failure.error
                continue
            }
            do {
                taps[id] = (app.processes, output, try makeTap(app.processes, output, setting(for: app).gain))
                failures[id] = nil
            } catch {
                failures[id] = (app.processes, output, error.localizedDescription)
                errors[id] = error.localizedDescription
            }
        }
        if !isAllowed {
            let message = "Allow \(AppInfo.name) under System Audio Recording Only in System Settings."
            for app in grouped where !setting(for: app).isUnchanged { errors[app.id] = message }
        }
        self.errors = errors
    }

    /// Groups processes under the app they play for, skipping this app and ones with no app.
    static func group(_ processes: [AudioProcess], app: (pid_t) -> AudioAppInfo?) -> [AudioApp] {
        var apps: [String: AudioApp] = [:]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for process in processes where process.pid != ownPID {
            guard let info = app(process.pid), info.pid != ownPID else { continue }
            if var existing = apps[info.bundleID] {
                existing.processes.append(process.objectID)
                existing.isPlaying = existing.isPlaying || process.isPlaying
                apps[info.bundleID] = existing
            } else {
                apps[info.bundleID] = AudioApp(
                    id: info.bundleID, name: info.name, pid: info.pid, processes: [process.objectID], isPlaying: process.isPlaying)
            }
        }
        return apps.values.map {
            var app = $0
            app.processes.sort()
            return app
        }
    }
}

final class LiveAudioProcesses: AudioProcessAccess {
    private let listener = AudioListener(
        // Devices too: a multi-output device's outputs come and go without the default changing.
        watching: [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices])

    func processes() -> [AudioProcess] {
        AudioProperty.array(
            AudioObjectID(kAudioObjectSystemObject), AudioProperty.address(kAudioHardwarePropertyProcessObjectList),
            of: AudioObjectID.self
        ).compactMap { id in
            guard let pid = AudioProperty.get(id, AudioProperty.address(kAudioProcessPropertyPID), as: pid_t.self) else { return nil }
            let playing = AudioProperty.get(id, AudioProperty.address(kAudioProcessPropertyIsRunningOutput), as: UInt32.self) == 1
            return AudioProcess(objectID: id, pid: pid, isPlaying: playing)
        }
    }

    func app(for pid: pid_t) -> AudioAppInfo? {
        let owner = Self.responsiblePID(pid) ?? pid
        guard let app = NSRunningApplication(processIdentifier: owner) ?? NSRunningApplication(processIdentifier: pid),
            let bundleID = app.bundleIdentifier
        else { return nil }
        return AudioAppInfo(bundleID: bundleID, name: app.localizedName ?? bundleID, pid: app.processIdentifier)
    }

    /// The app macOS holds responsible for a helper process, such as a browser for its audio
    /// helper. A private call, looked up at run time.
    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsible: Responsible? = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"
    ).map { unsafeBitCast($0, to: Responsible.self) }

    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let owner = responsible?(pid), owner > 0 else { return nil }
        return owner
    }

    func defaultOutputs() -> [String] {
        guard
            let id = AudioProperty.get(
                AudioObjectID(kAudioObjectSystemObject), AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice),
                as: AudioObjectID.self),
            id != kAudioObjectUnknown,
            let uid = LiveAudioDevices.uid(of: id)
        else { return [] }
        return LiveAudioDevices.connectedSubDevices(ofDeviceWithUID: uid) ?? [uid]
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        listener.start(onChange)
    }

    func stopObserving() {
        listener.stop()
    }
}
