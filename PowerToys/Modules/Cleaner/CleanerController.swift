import AppKit
import Observation
import Synchronization

/// Shows how much processor, memory and disk the Mac is using, kept up to date while it's on
/// screen, and frees them: quitting busy processes and deleting caches.
@Observable
final class CleanerController {
    /// How busy all cores were over the last refresh, from 0 to 1.
    private(set) var cpu: Double?
    private(set) var memory: MemoryUsage?
    private(set) var storage: StorageUsage?
    private(set) var processes: [ProcessUsage] = []
    /// Recent CPU and memory readings, oldest first, from 0 to 1, for the graphs.
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    /// Why usage couldn't be read, until a reading works.
    private(set) var readError: String?
    /// Why the last quit failed.
    private(set) var actionError: String?
    /// Whether the last scan couldn't tell which files are in use, so it left everything alone.
    private(set) var cantCheckActivity = false
    /// The problem to show, most pressing first.
    var error: String? {
        actionError ?? readError ?? (cantCheckActivity ? Self.unknownActivityError : nil)
    }
    /// What the last cleanup did.
    private(set) var result: String?

    /// What each cleanup target holds, once scanned.
    private(set) var scans: [CleanupTarget: CleanupScan] = [:] {
        didSet { updateSizes() }
    }
    /// What the current or last clean did, oldest first; the latest `eventLimit` or a few more.
    private(set) var cleanEvents: [CleanupEvent] = []
    /// The targets the current or last clean went through.
    private(set) var cleanedTargets: [CleanupTarget] = []
    /// Space freed so far in the current or last clean, counting events no longer listed.
    private(set) var cleanFreed: Int64 = 0
    /// Space the current or last clean moved to the Trash, which frees nothing until it's emptied.
    private(set) var cleanTrashed: Int64 = 0
    /// Items the current or last clean couldn't remove.
    private(set) var cleanFailed = 0
    /// Targets the current or last clean ran out of time on, which went on deleting unseen.
    private(set) var cleanTimedOut: [CleanupTarget] = []
    private(set) var progressByTarget: [CleanupTarget: CleanProgress] = [:]
    /// Events kept for the progress list; older ones still reach the log file. They're trimmed
    /// in batches, so each event doesn't move the whole list.
    static let eventLimit = 2000
    static let eventTrimBatch = 500
    /// Targets asked to be scanned while a scan ran.
    @ObservationIgnored private var pendingRescan: Set<CleanupTarget> = []
    /// Targets whose last scan took too long, scanned again on the next visit.
    @ObservationIgnored private var timedOut: Set<CleanupTarget> = []
    nonisolated static let tookTooLong = "Took too long"
    /// When the last scan finished.
    private(set) var scannedAt: Date?
    private(set) var isScanning = false
    private(set) var isCleaning = false
    /// Processes asked to quit, until they're gone.
    private(set) var quitting: Set<pid_t> = []
    var selected: Set<CleanupTarget> = CleanupTarget.selectedByDefault {
        didSet { updateSizes() }
    }
    /// Paths of items unticked in a target's list, which cleanups leave alone from then on.
    private(set) var kept: Set<String> {
        didSet {
            defaults.set(kept.sorted(), forKey: Self.keptKey)
            updateSizes()
        }
    }

    static let keptKey = "cleaner.keptPaths"
    /// Whether Docker also removes tagged images no container uses, which may not download again.
    private(set) var dockerPrunesTagged: Bool {
        didSet { defaults.set(dockerPrunesTagged, forKey: Self.dockerPrunesTaggedKey) }
    }

    static let dockerPrunesTaggedKey = "cleaner.dockerPrunesTagged"

    static let refreshInterval: Duration = .seconds(2)
    static let topCount = 6
    /// Readings kept for the graphs: two minutes at `refreshInterval`.
    static let historyLength = 60

    /// Uninstalls apps with their data.
    @ObservationIgnored let uninstaller: AppUninstaller

    private let defaults: UserDefaults
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let sampler: any UsageSampling
    @ObservationIgnored private let signaling: any ProcessSignaling
    @ObservationIgnored private let readActivity: @Sendable () async -> ActivitySnapshot
    /// How long an asked process gets before it's offered a quit again, as an app can cancel
    /// quitting at its save prompt.
    @ObservationIgnored private let quitTimeout: Duration
    @ObservationIgnored private var quitDeadlines: [pid_t: ContinuousClock.Instant] = [:]
    @ObservationIgnored private let cleanupLog: URL?
    /// Whether this app has Full Disk Access, which changing other apps' containers needs.
    @ObservationIgnored private let fullDiskAccess: () -> Bool
    /// What's installed, read at each scan and clean, for telling leftovers apart.
    @ObservationIgnored private let installedApps: @Sendable () async -> InstalledApps?
    /// Looked for at each clean, like Docker.
    @ObservationIgnored private let findNpm: () -> NpmCLI?
    /// Looked for at each scan and clean, so Docker installed after launch is found.
    @ObservationIgnored private let findDocker: () -> DockerCLI?
    @ObservationIgnored private var lastTicks: CPUTicks?
    /// When free disk space was last read; it's slow to work out and rarely changes.
    @ObservationIgnored private var storageReadAt: ContinuousClock.Instant?
    @ObservationIgnored private let scanTimeout: Duration
    @ObservationIgnored private let cleanTimeout: Duration
    /// When the process with an ID started, or nil once none has it, to make sure the ID hasn't
    /// passed to another process.
    @ObservationIgnored private let startTime: (pid_t) -> Date?

    init(
        defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        sampler: any UsageSampling = LiveUsageSampler(),
        signaling: any ProcessSignaling = LiveProcessSignaling(),
        readActivity: @escaping @Sendable () async -> ActivitySnapshot = { await ActivitySnapshot.read() },
        quitTimeout: Duration = .seconds(5),
        cleanupLog: URL? = CleanerController.defaultCleanupLog,
        docker: @escaping @autoclosure () -> DockerCLI? = DockerCLI.find(),
        npm: @escaping @autoclosure () -> NpmCLI? = NpmCLI.find(),
        scanTimeout: Duration = CleanerController.scanTimeout,
        cleanTimeout: Duration = CleanerController.cleanTimeout,
        startTime: @escaping (pid_t) -> Date? = { ProcessStart.read($0) },
        installedApps: @escaping @Sendable () async -> InstalledApps? = { await InstalledApps.read() },
        fullDiskAccess: @escaping () -> Bool = { FullDiskAccess.isGranted() },
        uninstaller: AppUninstaller? = nil
    ) {
        self.uninstaller =
            uninstaller ?? AppUninstaller(home: home, readActivity: readActivity, fullDiskAccess: fullDiskAccess)
        self.fullDiskAccess = fullDiskAccess
        self.installedApps = installedApps
        self.startTime = startTime
        self.scanTimeout = scanTimeout
        self.cleanTimeout = cleanTimeout
        findDocker = docker
        findNpm = npm
        self.defaults = defaults
        kept = Set(defaults.stringArray(forKey: Self.keptKey) ?? [])
        dockerPrunesTagged = defaults.bool(forKey: Self.dockerPrunesTaggedKey)
        self.readActivity = readActivity
        self.quitTimeout = quitTimeout
        self.cleanupLog = cleanupLog
        self.home = home
        self.sampler = sampler
        self.signaling = signaling
        updateSizes()
    }

    // MARK: Usage

    /// The busiest processes, kept with each reading rather than sorted on every redraw.
    private(set) var topByCPU: [ProcessUsage] = []
    private(set) var topByMemory: [ProcessUsage] = []

    private static func top<Value: Comparable>(_ processes: [ProcessUsage], by value: KeyPath<ProcessUsage, Value>)
        -> [ProcessUsage]
    {
        Array(processes.sorted { $0[keyPath: value] > $1[keyPath: value] }.prefix(topCount))
    }

    func refresh() async {
        do {
            let now = ContinuousClock.now
            let readsStorage = storageReadAt.map { now - $0 >= Self.storageInterval } ?? true
            let sample = try await sampler.sample(includesStorage: readsStorage)
            if readsStorage { storageReadAt = now }
            if let ticks = sample.cpuTicks {
                if let lastTicks, let usage = ticks.usage(since: lastTicks) {
                    cpu = usage
                    Self.record(usage, in: &cpuHistory)
                }
                lastTicks = ticks
            }
            if let memory = sample.memory {
                self.memory = memory
                Self.record(memory.fraction, in: &memoryHistory)
            }
            storage = sample.storage ?? storage
            // Start times tell a process from a later one given its ID; only the rows shown
            // can be quit, so only theirs are read.
            let shown = Set(Self.top(sample.processes, by: \.cpu) + Self.top(sample.processes, by: \.memory))
            processes = sample.processes.map { process in
                guard shown.contains(process) else { return process }
                var shownProcess = process
                shownProcess.started = startTime(process.pid)
                return shownProcess
            }
            topByCPU = Self.top(processes, by: \.cpu)
            topByMemory = Self.top(processes, by: \.memory)
            let running = Set(sample.processes.map(\.pid))
            quitting = quitting.filter { running.contains($0) && (quitDeadlines[$0] ?? now) > now }
            quitDeadlines = quitDeadlines.filter { quitting.contains($0.key) }
            readError = nil
        } catch is CancellationError {
            return
        } catch {
            readError = "Couldn't read usage: \(error.localizedDescription)"
        }
    }

    static let storageInterval: Duration = .seconds(30)

    private static func record(_ value: Double, in history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    /// Refreshes until the calling task is cancelled, as when the view showing it goes away.
    /// Each watch starts the graphs afresh, so time spent away isn't averaged into one reading.
    func watch() async {
        lastTicks = nil
        cpu = nil
        cpuHistory = []
        memoryHistory = []
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// Watches usage and, until every target has been scanned, scans what can be cleaned
    /// alongside. Both stop when the calling task is cancelled, and a cancelled scan leaves the
    /// lists as they were.
    func watchAndScan() async {
        // Targets never scanned, too slow last time, unavailable, such as Docker not running, or
        // asked for by a scan that was cancelled. Ones still deleting are left out by the scan.
        let stale = Set(CleanupTarget.allCases.filter { scans[$0]?.unavailable != nil || scans[$0] == nil })
            .union(timedOut)
            .union(pendingRescan)
        pendingRescan = []
        guard !stale.isEmpty else { return await watch() }
        async let scanning: Void = scan(stale)
        await watch()
        await scanning
    }

    /// Parts of macOS, such as loginwindow and the Dock, other users' processes and this app
    /// can't be quit from here.
    func canQuit(_ process: ProcessUsage) -> Bool {
        process.pid > 1 && process.pid != getpid() && process.uid == getuid() && !process.isSystem
    }

    /// Apps are asked to quit as from their menu, so they can offer to save; other processes, and
    /// apps that won't take the request, get SIGTERM, as `kill` sends.
    func quit(_ process: ProcessUsage) {
        guard canQuit(process), !quitting.contains(process.pid) else { return }
        // The list is a moment old, so the process may have quit and its ID gone to another,
        // which started later. Without a start time from the list there's no telling.
        guard let listed = process.started, startTime(process.pid) == listed else {
            actionError = "\(process.name) has already quit."
            return
        }
        if NSRunningApplication(processIdentifier: process.pid)?.terminate() != true {
            let result = signaling.send(SIGTERM, to: process.pid)
            guard result == 0 else {
                actionError =
                    result == EPERM
                    ? "\(process.name) belongs to another user, so it can't be quit from here."
                    : "Couldn't quit \(process.name): \(String(cString: strerror(result)))"
                return
            }
        }
        actionError = nil
        quitting.insert(process.pid)
        quitDeadlines[process.pid] = .now + quitTimeout
    }

    // MARK: Cleanup

    /// The space cleaning frees in each target, once scanned, leaving out kept items. Worked out
    /// when the lists or the ticks change, not on every redraw.
    private(set) var sizes: [CleanupTarget: Int64] = [:]

    private func updateSizes() {
        sizes = scans.mapValues { $0.size(keeping: kept) }
        nextReview = makeReview()
    }

    /// Targets whose clean ran out of time and may still be deleting, kept out of the next clean,
    /// and of any scan, until they stop.
    private(set) var stillDeleting: Set<CleanupTarget> = [] {
        didSet { updateSizes() }
    }

    /// What a clean would take right now: the ticked items of the selected targets that can be
    /// cleaned, kept up to date as the lists, ticks and selection change. The confirmation shows
    /// one, and the clean takes only what it lists.
    private(set) var nextReview = CleanReview(targets: [])

    private func makeReview() -> CleanReview {
        let targets = CleanupTarget.allCases.filter {
            selected.contains($0) && scans[$0]?.unavailable == nil && !stillDeleting.contains($0)
        }
        var review = CleanReview(targets: targets)
        for target in targets {
            for item in scans[target]?.cleanable ?? [] where willClean(item) {
                review.sizes[item.id] = item.size
                if target.movesToTrash { review.trashSize += item.size } else { review.deleteSize += item.size }
            }
        }
        return review
    }

    /// Takes effect at once; the Docker list is rescanned now, or as soon as a running scan or
    /// clean finishes, so it soon matches. A clean already running keeps the setting it started
    /// with.
    func setDockerPrunesTagged(_ prunesTagged: Bool) async {
        dockerPrunesTagged = prunesTagged
        await scan([.docker])
    }

    /// Selects or clears a target. One that needs Full Disk Access stays off without it, and this
    /// returns false so the reason can be shown.
    @discardableResult
    func setSelected(_ isOn: Bool, _ target: CleanupTarget) -> Bool {
        guard isOn else {
            selected.remove(target)
            return true
        }
        guard !target.needsFullDiskAccess || fullDiskAccess() else { return false }
        selected.insert(target)
        return true
    }

    /// Whether a cleanup deletes the item: it's not protected and not kept.
    func willClean(_ item: CleanupItem) -> Bool {
        item.skipReason == nil && !kept.contains(item.id)
    }

    func setWillClean(_ willClean: Bool, _ item: CleanupItem) {
        guard item.skipReason == nil else { return }
        if willClean { kept.remove(item.id) } else { kept.insert(item.id) }
    }

    /// Ticks or unticks every item a target can clean.
    func setWillCleanAll(_ willClean: Bool, in target: CleanupTarget) {
        let paths = (scans[target]?.cleanable ?? []).map(\.id)
        if willClean { kept.subtract(paths) } else { kept.formUnion(paths) }
    }

    /// The log this controller writes, if any.
    var logFile: URL? { cleanupLog }

    /// Where each deletion is recorded: date, bytes and path, a line each.
    static var defaultCleanupLog: URL {
        URL.powerToysSupportDirectory.appending(path: "Cleaner.log")
    }

    /// How long a target's scan may take, so a slow folder or Docker doesn't hold up the rest.
    static let scanTimeout: Duration = .seconds(60)
    /// How long a target's clean may take; deleting gigabytes can be slow, but a stuck disk
    /// shouldn't keep the page busy for good.
    static let cleanTimeout: Duration = .seconds(600)

    static let unknownActivityError = "Couldn't check which files are in use, so they're left alone."

    /// Docker, npm, the installed apps and Full Disk Access are looked up only for the targets
    /// that use them.
    private func context(for targets: some Sequence<CleanupTarget>, reviewed: Set<String>? = nil) async
        -> Cleanup.Context
    {
        let targets = Set(targets)
        let activity = await readActivity()
        // Say why everything is skipped, rather than leaving a cleanup that silently does nothing.
        cantCheckActivity = activity.openFiles == nil || activity.commandLines == nil
        let readsApps = targets.contains(.leftovers)
        return Cleanup.Context(
            home: home, activity: activity, kept: kept, reviewed: reviewed,
            docker: targets.contains(.docker) ? findDocker() : nil,
            npm: targets.contains(.developerCaches) ? findNpm() : nil,
            dockerPrunesTagged: dockerPrunesTagged, apps: readsApps ? await installedApps() : nil,
            canChangeAppContainers: readsApps && fullDiskAccess())
    }

    /// Hides the last result and quit error. Usage problems stay until they're gone.
    func dismissMessage() {
        result = nil
        actionError = nil
    }

    /// Lists what the targets, every one unless given, hold again, all at once.
    func scan(_ targets: Set<CleanupTarget> = Set(CleanupTarget.allCases)) async {
        // Asked for during a clean, it runs after the clean's own rescan.
        guard !isCleaning else {
            pendingRescan.formUnion(targets)
            return
        }
        await rescan(targets)
    }

    /// A scan asked for while one runs follows it, so nothing asked for is dropped, such as the
    /// rescan after Full Disk Access is granted.
    private func rescan(_ targets: Set<CleanupTarget>) async {
        guard !isScanning else {
            pendingRescan.formUnion(targets)
            return
        }
        var targets = targets
        while true {
            await scanOnce(targets)
            guard !pendingRescan.isEmpty, !Task.isCancelled else { return }
            targets = pendingRescan
            pendingRescan = []
        }
    }

    private func scanOnce(_ targets: Set<CleanupTarget>) async {
        // A target still deleting would be listed half-gone, so it waits for the next visit.
        let targets = targets.subtracting(stillDeleting)
        guard !targets.isEmpty else { return }
        isScanning = true
        defer { isScanning = false }
        let context = await context(for: targets)
        let timeout = scanTimeout
        await withTaskGroup(of: (CleanupTarget, CleanupScan).self) { group in
            for target in targets {
                group.addTask { (target, await Self.scan(target, context: context, timeout: timeout)) }
            }
            for await (target, scan) in group where !Task.isCancelled {
                if scan.unavailable == Self.tookTooLong {
                    timedOut.insert(target)
                    // An earlier list is more use than none.
                    if scans[target] != nil { continue }
                } else {
                    timedOut.remove(target)
                }
                scans[target] = scan
            }
        }
        if !Task.isCancelled { scannedAt = .now }
    }

    /// One target's scan, or a note that it took too long. A scan stuck on a slow disk isn't
    /// waited for: it's cancelled and left to finish on its own. Cancelling the caller ends the
    /// wait at once, the same way.
    @concurrent
    private nonisolated static func scan(
        _ target: CleanupTarget, context: Cleanup.Context, timeout: Duration
    ) async -> CleanupScan {
        await finish(within: timeout) { await Cleanup.scan(target, context: context) }
            ?? CleanupScan(items: [], unavailable: tookTooLong)
    }

    /// The work's result, or nil once `timeout` passes, when the work is cancelled and left to
    /// stop on its own. Cancelling the caller ends the wait at once, the same way.
    @concurrent
    private nonisolated static func finish<Value: Sendable>(
        within timeout: Duration, _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let work = Task { await operation() }
        let timer = Task { try? await Task.sleep(for: timeout) }
        let waiting = Mutex<CheckedContinuation<Value?, Never>?>(nil)
        let finished: Value? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting.withLock { $0 = continuation }
                Task {
                    let value = await work.value
                    waiting.withLock {
                        $0?.resume(returning: value)
                        $0 = nil
                    }
                }
                Task {
                    await timer.value
                    waiting.withLock {
                        $0?.resume(returning: nil)
                        $0 = nil
                    }
                }
            }
        } onCancel: {
            // Ends the timer early, which ends the wait.
            timer.cancel()
        }
        timer.cancel()
        if finished == nil { work.cancel() }
        return finished
    }

    /// Deletes, or moves to the Trash, what the review listed, by default what's ticked now, then
    /// scans those targets and the disk again. Nothing outside the review is touched, so a list
    /// that changed after it was confirmed doesn't matter.
    func clean(_ review: CleanReview? = nil) async {
        let review = review ?? nextReview
        guard !isCleaning, !review.targets.isEmpty else { return }
        // The list being confirmed may be about to change, so nothing is deleted.
        guard !isScanning else {
            actionError = "Couldn't clean while scanning. Try again when the scan is done."
            return
        }
        isCleaning = true
        defer { isCleaning = false }
        actionError = nil
        var reviewing = await context(for: review.targets, reviewed: Set(review.sizes.keys))
        reviewing.sizes = review.sizes
        let context = reviewing
        let log = cleanupLog
        cleanedTargets = review.targets
        cleanEvents = []
        cleanFreed = 0
        cleanTrashed = 0
        cleanFailed = 0
        cleanTimedOut = []
        progressByTarget = [:]
        // Events come from every target at once; they're shown in the order they arrive.
        let (events, reporter) = AsyncStream.makeStream(of: CleanupEvent.self)
        let showing = Task {
            for await event in events { record(event) }
        }
        let timeout = cleanTimeout
        // What the rules keep is told too, so nothing is left alone silently. Targets listed again
        // when cleaning tell it themselves, with the reason as it is then.
        let leftAlone = Dictionary(
            uniqueKeysWithValues: cleanedTargets.map { target in
                (target, target.listsAgainWhenCleaning ? [] : (scans[target]?.items ?? []).filter { $0.skipReason != nil })
            })
        stillDeleting.formUnion(cleanedTargets)
        let tooSlow = await withTaskGroup(of: CleanupTarget?.self) { group in
            for target in cleanedTargets {
                let kept = leftAlone[target] ?? []
                group.addTask {
                    reporter.yield(CleanupEvent(target: target, kind: .started))
                    for item in kept {
                        reporter.yield(
                            CleanupEvent(target: target, kind: .skipped(item.skipReason ?? ""), detail: item.url?.path ?? item.name))
                    }
                    let handled = await Self.finish(within: timeout) {
                        let handled = await Cleanup.clean(target, context: context, log: log) { reporter.yield($0) }
                        // Only once deleting has really stopped, even after running out of time.
                        await self.finishedDeleting(target)
                        return handled
                    }
                    // Still deleting in the background, so neither done nor failed.
                    reporter.yield(CleanupEvent(target: target, kind: handled.map { .finished($0) } ?? .timedOut))
                    return handled == nil ? target : nil
                }
            }
            var tooSlow: Set<CleanupTarget> = []
            for await target in group { if let target { tooSlow.insert(target) } }
            return tooSlow
        }
        reporter.finish()
        await showing.value
        result = Self.summary(
            freed: cleanFreed, trashed: cleanTrashed, failed: cleanFailed, cantCheck: cantCheckActivity,
            stillDeleting: cleanTimedOut)
        // A clean that ran out of time stops only after the item it's on, so its target is scanned
        // on the next visit, not while it may still be deleting.
        timedOut.formUnion(tooSlow)
        await rescan(Set(cleanedTargets).subtracting(tooSlow))
        storage = await StorageUsage.readInBackground() ?? storage
        storageReadAt = .now
    }

    private func finishedDeleting(_ target: CleanupTarget) {
        stillDeleting.remove(target)
    }

    static func summary(
        freed: Int64, trashed: Int64, failed: Int, cantCheck: Bool, stillDeleting: [CleanupTarget] = []
    ) -> String {
        var parts: [String] = []
        if freed > 0 { parts.append("Freed \(format(freed)).") }
        // The Trash frees nothing until it's emptied, so it's told apart.
        if trashed > 0 { parts.append("Moved \(format(trashed)) to the Trash.") }
        if parts.isEmpty {
            parts.append(
                cantCheck
                    ? "Nothing was deleted, to be safe."
                    : !stillDeleting.isEmpty
                        ? "Nothing was removed yet."
                        : failed > 0 ? "Nothing was removed." : "Nothing could be deleted.")
        }
        if failed > 0 { parts.append(failed == 1 ? "1 item couldn't be removed." : "\(failed) items couldn't be removed.") }
        if !stillDeleting.isEmpty {
            let names = stillDeleting.map(\.title).formatted(.list(type: .and))
            parts.append("\(names) took too long and may still be deleting; the log lists what went.")
        }
        return parts.joined(separator: " ")
    }

    private func record(_ event: CleanupEvent) {
        switch event.kind {
        case .started: progressByTarget[event.target] = .cleaning
        case .finished(let freed): progressByTarget[event.target] = .done(freed)
        case .deleted(let bytes): cleanFreed += bytes
        case .trashed(let bytes): cleanTrashed += bytes
        case .failed: cleanFailed += 1
        case .skipped: break
        case .timedOut:
            progressByTarget[event.target] = .stillDeleting
            cleanTimedOut.append(event.target)
        }
        cleanEvents.append(event)
        if cleanEvents.count >= Self.eventLimit + Self.eventTrimBatch {
            cleanEvents.removeFirst(cleanEvents.count - Self.eventLimit)
        }
    }

    /// Where a target is in the current or last clean.
    func cleanProgress(of target: CleanupTarget) -> CleanProgress {
        progressByTarget[target] ?? .waiting
    }

    static func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

enum CleanProgress: Hashable {
    case waiting, cleaning
    case done(Int64)
    /// Ran out of time and was left deleting in the background.
    case stillDeleting
}

/// What a clean takes: the targets, each item's ID with its listed size, and how much is deleted
/// for good and how much goes to the Trash.
struct CleanReview: Equatable {
    var targets: [CleanupTarget]
    var sizes: [String: Int64] = [:]
    var deleteSize: Int64 = 0
    var trashSize: Int64 = 0

    /// Nothing ticked; ticked items that take no space, such as empty folders, still count.
    var isEmpty: Bool { sizes.isEmpty }
}
