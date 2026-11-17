import AppKit
import CoreLocation
import Foundation
import Observation

/// What the network looks like now, the public address on request, and Apple's speed test.
@Observable
final class NetworkInfoController {
    private(set) var snapshot = NetworkSnapshot()
    private(set) var isLoaded = false

    /// Looked up only when asked, since it means a request to an outside service.
    private(set) var publicAddress: PublicAddress?
    private(set) var isLookingUpAddress = false
    private(set) var addressProblem: String?

    private(set) var speedTest: SpeedTestResult?
    private(set) var isTestingSpeed = false
    private(set) var speedTestProblem: String?
    @ObservationIgnored private var speedTask: Task<Void, Never>?

    /// macOS shows the Wi‑Fi network's name only to apps allowed to use Location.
    private(set) var locationStatus: CLAuthorizationStatus = .notDetermined

    static let refreshInterval: Duration = .seconds(3)

    @ObservationIgnored private let reader: any NetworkReading
    @ObservationIgnored private let makeLocation: (() -> CLLocationManager)?
    /// Made the first time the Info tab shows, not at launch.
    @ObservationIgnored private var location: CLLocationManager?
    @ObservationIgnored private let locationDelegate = LocationDelegate()

    /// `makeLocation` is nil in tests, so they never ask for access.
    init(reader: any NetworkReading = LiveNetworkReader(), makeLocation: (() -> CLLocationManager)? = { CLLocationManager() }) {
        self.reader = reader
        self.makeLocation = makeLocation
        locationDelegate.changed = { [weak self] status in
            guard self?.locationStatus != status else { return }
            self?.locationStatus = status
            Task { await self?.refresh() }
        }
    }

    private func startLocation() {
        guard location == nil, let location = makeLocation?() else { return }
        self.location = location
        locationStatus = location.authorizationStatus
        location.delegate = locationDelegate
    }

    func refresh() async {
        snapshot = await reader.snapshot()
        isLoaded = true
    }

    /// Refreshes until the calling task is cancelled, as when the view showing it goes away.
    func watch() async {
        startLocation()
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func lookUpPublicAddress() async {
        guard !isLookingUpAddress else { return }
        isLookingUpAddress = true
        defer { isLookingUpAddress = false }
        do {
            publicAddress = try await reader.publicAddress()
            addressProblem = nil
        } catch {
            addressProblem = "Couldn't look it up: \(error.localizedDescription)"
        }
    }

    func runSpeedTest() {
        guard !isTestingSpeed else { return }
        isTestingSpeed = true
        speedTestProblem = nil
        speedTask = Task {
            defer {
                isTestingSpeed = false
                speedTask = nil
            }
            do {
                speedTest = try await reader.speedTest()
            } catch is CancellationError {
            } catch {
                speedTestProblem = "The speed test didn't finish: \(error.localizedDescription)"
            }
        }
    }

    func cancelSpeedTest() {
        speedTask?.cancel()
    }

    /// Asks for Location so the Wi‑Fi name shows. Once denied, it can only be allowed in System Settings.
    func requestWiFiName() {
        location?.requestWhenInUseAuthorization()
    }

    var canAskForWiFiName: Bool { locationStatus == .notDetermined }

    var isWiFiNameDenied: Bool { locationStatus == .denied || locationStatus == .restricted }

    private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
        var changed: ((CLAuthorizationStatus) -> Void)?

        nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let status = manager.authorizationStatus
            Task { @MainActor in self.changed?(status) }
        }
    }
}

/// How fast each process is sending and receiving, from `nettop` samples a moment apart.
@Observable
final class BandwidthController {
    struct Usage: Identifiable, Hashable {
        let pid: pid_t
        let name: String
        /// Bytes a second.
        let download: Double
        let upload: Double

        var id: pid_t { pid }
        var total: Double { download + upload }
    }

    private(set) var usage: [Usage] = []
    private(set) var isLoaded = false
    private(set) var problem: String?

    static let interval: Duration = .seconds(2)

    @ObservationIgnored private let reader: any NetworkReading
    @ObservationIgnored private let appName: (pid_t) -> String?
    @ObservationIgnored private var last: (sample: [pid_t: ProcessTraffic], at: ContinuousClock.Instant)?

    /// nettop cuts names at 15 characters, so apps' own names are used where there's one.
    init(reader: any NetworkReading = LiveNetworkReader(), appName: ((pid_t) -> String?)? = nil) {
        self.reader = reader
        self.appName = appName ?? { NSRunningApplication(processIdentifier: $0)?.localizedName }
    }

    var totalDownload: Double { usage.reduce(0) { $0 + $1.download } }
    var totalUpload: Double { usage.reduce(0) { $0 + $1.upload } }

    func sample(at now: ContinuousClock.Instant = .now) async {
        do {
            let traffic = try await reader.traffic()
            record(traffic, at: now)
            problem = nil
        } catch is CancellationError {
        } catch {
            problem = "Couldn't read network use: \(error.localizedDescription)"
        }
    }

    /// Works out rates against the previous sample. Processes that started since, and new ones
    /// with a reused ID, show from the next sample.
    func record(_ traffic: [ProcessTraffic], at now: ContinuousClock.Instant) {
        let current = Dictionary(traffic.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        defer { last = (current, now) }
        guard let last else { return }
        let elapsed = (now - last.at) / .seconds(1)
        guard elapsed > 0 else { return }
        usage =
            current.values.compactMap { entry -> Usage? in
                // A process seen for the first time brings its whole history, and so does a new
                // one with a reused ID, whose counts went down: only what moved since counts.
                guard let before = last.sample[entry.pid], entry.bytesIn >= before.bytesIn, entry.bytesOut >= before.bytesOut
                else { return nil }
                let downloaded = entry.bytesIn - before.bytesIn
                let uploaded = entry.bytesOut - before.bytesOut
                guard downloaded + uploaded > 0 else { return nil }
                return Usage(
                    pid: entry.pid, name: appName(entry.pid) ?? entry.name,
                    download: Double(downloaded) / elapsed, upload: Double(uploaded) / elapsed)
            }
            .sorted { $0.total == $1.total ? $0.name < $1.name : $0.total > $1.total }
        isLoaded = true
    }

    /// Keeps the list up to date until the calling task is cancelled, as when the view showing
    /// it goes away. However many views watch, such as settings and the menu bar's panel at
    /// once, one loop samples for them all, and stops when the last goes.
    func watch() async {
        watchers += 1
        if watchers == 1 {
            // What was measured last time is no longer current.
            last = nil
            usage = []
            isLoaded = false
            problem = nil
            sampling = Task { [weak self] in
                while !Task.isCancelled {
                    // Ends once nothing holds the controller.
                    guard let controller = self else { return }
                    await controller.sample()
                    try? await Task.sleep(for: Self.interval)
                }
            }
        }
        // Sleeps until cancelled; Task.sleep throws as soon as it is.
        while (try? await Task.sleep(for: .seconds(3_600))) != nil {}
        watchers -= 1
        if watchers == 0 {
            sampling?.cancel()
            sampling = nil
        }
    }

    /// How many views are watching now.
    @ObservationIgnored private(set) var watchers = 0
    @ObservationIgnored private var sampling: Task<Void, Never>?
}
