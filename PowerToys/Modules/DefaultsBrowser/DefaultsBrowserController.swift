import AppKit
import Foundation
import Observation

/// A preferences domain: an app's settings, or the global ones every app reads.
nonisolated struct DefaultsDomain: Hashable, Identifiable, Sendable {
    let id: String
    /// The app with this bundle identifier, when there is one.
    var appName: String?
    var appURL: URL?
    /// The plist in ~/Library/Preferences, which may not exist yet.
    var fileURL: URL?

    static let global = "NSGlobalDomain"

    var isGlobal: Bool { id == Self.global }
    var isApple: Bool { isGlobal || id.hasPrefix("com.apple.") }
    var title: String { isGlobal ? "Global" : appName ?? id }

    /// Looks up the app for `id`, and where its plist would be.
    static func named(_ id: String, in preferences: URL) -> DefaultsDomain {
        let fileName = id == global ? ".GlobalPreferences" : id
        let appURL = id == global ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let appName = appURL.map { FileManager.default.displayName(atPath: $0.path).replacing(#/\.app$/#, with: "") }
        return DefaultsDomain(id: id, appName: appName, appURL: appURL,
                              fileURL: preferences.appending(path: "\(fileName).plist"))
    }

    /// The global domain first, then by name.
    static func sorted(_ domains: [DefaultsDomain]) -> [DefaultsDomain] {
        domains.sorted { first, second in
            if first.isGlobal != second.isGlobal { return first.isGlobal }
            return first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending
        }
    }
}

/// A key to set, or to delete when `value` is nil.
nonisolated struct DefaultsChange: Hashable, Sendable {
    let key: String
    let value: DefaultsValue?
}

/// Reads and writes preferences; a protocol so tests don't change real ones.
protocol DefaultsStoring: Sendable {
    func domains() async -> [DefaultsDomain]
    /// Each domain's keys, for finding the domains a key is in.
    func keys(in domains: [String]) async -> [String: [String]]
    func values(in domain: String) async -> [String: DefaultsValue]
    func write(_ changes: [DefaultsChange], in domain: String) async throws
}

/// The current user's preferences, through cfprefsd as `defaults` uses them.
nonisolated struct LiveDefaultsStore: DefaultsStoring {
    static let preferencesDirectory = URL.libraryDirectory.appending(path: "Preferences")

    @concurrent
    func domains() async -> [DefaultsDomain] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.preferencesDirectory.path)) ?? []
        let ids = names.compactMap { name -> String? in
            guard name.hasSuffix(".plist") else { return nil }
            let id = String(name.dropLast(".plist".count))
            if id == ".GlobalPreferences" { return DefaultsDomain.global }
            return id.hasPrefix(".") ? nil : id
        }
        return DefaultsDomain.sorted(ids.map { DefaultsDomain.named($0, in: Self.preferencesDirectory) })
    }

    @concurrent
    func keys(in domains: [String]) async -> [String: [String]] {
        var keys: [String: [String]] = [:]
        for domain in domains {
            // Drops what this process cached, so keys added elsewhere are found.
            CFPreferencesAppSynchronize(Self.application(domain))
            keys[domain] = CFPreferencesCopyKeyList(Self.application(domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        }
        return keys
    }

    @concurrent
    func values(in domain: String) async -> [String: DefaultsValue] {
        let application = Self.application(domain)
        // Drops what this process cached, so changes made elsewhere show.
        CFPreferencesAppSynchronize(application)
        let values = CFPreferencesCopyMultiple(nil, application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
        return values?.compactMapValues(DefaultsValue.init(plist:)) ?? [:]
    }

    @concurrent
    func write(_ changes: [DefaultsChange], in domain: String) async throws {
        let application = Self.application(domain)
        for change in changes {
            CFPreferencesSetValue(change.key as CFString, change.value?.plistObject, application,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        guard CFPreferencesSynchronize(application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw CommandError(errorDescription: "macOS didn't save it. The domain may belong to another user or to the system.")
        }
    }

    private static func application(_ domain: String) -> CFString {
        domain == DefaultsDomain.global ? kCFPreferencesAnyApplication : domain as CFString
    }
}

/// Browses preference domains and changes their keys, keeping a copy of each domain from
/// before its first change.
@Observable
final class DefaultsBrowserController {
    private(set) var domains: [DefaultsDomain] = []
    private(set) var isLoaded = false
    /// Each domain's keys, filled in after the domains, for filtering them by key.
    private(set) var keyIndex: [String: [String]] = [:] {
        didSet { matchCache = nil }
    }

    private(set) var openDomain: DefaultsDomain?
    /// The open domain's keys and values.
    private(set) var values: [String: DefaultsValue] = [:]
    /// The open domain's app while it's running; it may not notice changes until it restarts.
    private(set) var runningApp: NSRunningApplication?
    private(set) var error: String?
    private(set) var backedUpDomains: Set<String> = []
    /// Filters the open domain's keys by key or value.
    var keyFilter = ""

    /// The hidden settings' stored values, by domain and key.
    private(set) var tweakValues: [String: [String: DefaultsValue]] = [:]
    /// The Dock or Finder when a hidden setting of theirs changed and they haven't restarted since.
    private(set) var pendingRestarts: Set<DefaultsTweak.Restart> = []

    static let refreshInterval: Duration = .seconds(3)

    @ObservationIgnored private let store: any DefaultsStoring
    @ObservationIgnored let backupDirectory: URL?
    /// Bumped by every change, so a read started before one doesn't overwrite what it wrote.
    @ObservationIgnored private var generation = 0
    /// The last change queued. Changes run one at a time, so a domain's original is saved once,
    /// before the first, and each reads back what it wrote before the next starts.
    @ObservationIgnored private var lastChange: Task<Void, Never>?
    /// The open domain's keys changed here, to put back if its app saves over them when it quits.
    @ObservationIgnored private var edits: [String: DefaultsChange] = [:]
    /// The keys matching the last query, by domain, as the list asks for them once per row.
    @ObservationIgnored private var matchCache: (query: String, matches: [String: [String]])?
    /// Quits every process with the bundle identifier; a parameter so tests don't quit the Dock.
    @ObservationIgnored private let quitProcesses: @MainActor (String) -> Void

    static var defaultBackupDirectory: URL {
        URL.powerToysSupportDirectory.appending(path: "Defaults Backups")
    }

    init(
        store: any DefaultsStoring = LiveDefaultsStore(),
        backupDirectory: URL? = DefaultsBrowserController.defaultBackupDirectory,
        quitProcesses: @escaping @MainActor (String) -> Void = DefaultsBrowserController.quitProcesses
    ) {
        self.store = store
        self.backupDirectory = backupDirectory
        self.quitProcesses = quitProcesses
        if let backupDirectory, let files = try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path) {
            backedUpDomains = Set(files.filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(".plist".count)) })
        }
    }

    // MARK: Domains

    func loadDomains() async {
        let domains = await store.domains()
        if domains != self.domains { self.domains = domains }
        isLoaded = true
        let keyIndex = await store.keys(in: domains.map(\.id))
        if keyIndex != self.keyIndex { self.keyIndex = keyIndex }
    }

    /// Domains whose name, identifier or one of whose keys has `query` in it.
    func domains(matching query: String) -> [DefaultsDomain] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return domains }
        let keyMatches = keyMatches(query)
        return domains.filter { domain in
            domain.title.localizedCaseInsensitiveContains(query)
                || domain.id.localizedCaseInsensitiveContains(query)
                || keyMatches[domain.id] != nil
        }
    }

    func matchingKeys(in domain: DefaultsDomain, _ query: String) -> [String] {
        keyMatches(query.trimmingCharacters(in: .whitespaces))[domain.id] ?? []
    }

    /// Each domain's keys with `query` in them, leaving out domains with none. Worked out once
    /// per query, as there can be tens of thousands of keys.
    private func keyMatches(_ query: String) -> [String: [String]] {
        if let matchCache, matchCache.query == query { return matchCache.matches }
        var matches: [String: [String]] = [:]
        if !query.isEmpty {
            for (id, keys) in keyIndex {
                let found = keys.filter { $0.range(of: query, options: .caseInsensitive) != nil }
                if !found.isEmpty { matches[id] = found.sorted() }
            }
        }
        matchCache = (query, matches)
        return matches
    }

    /// A domain by its identifier, listed or not, for apps that haven't saved any settings yet.
    func domain(named id: String) -> DefaultsDomain {
        var id = id.trimmingCharacters(in: .whitespaces)
        if ["-g", "-globalDomain", ".GlobalPreferences"].contains(id) { id = DefaultsDomain.global }
        return domains.first { $0.id == id } ?? DefaultsDomain.named(id, in: LiveDefaultsStore.preferencesDirectory)
    }

    /// Opens a domain, with its keys filtered by `filter`, such as the key it was found by.
    func open(_ domain: DefaultsDomain, filter: String = "") async {
        openDomain = domain
        values = [:]
        error = nil
        keyFilter = filter
        edits = [:]
        await reload()
    }

    func close() {
        openDomain = nil
        values = [:]
        runningApp = nil
        error = nil
        keyFilter = ""
        edits = [:]
    }

    /// Reads the open domain again, and whether its app is running.
    func reload() async {
        guard let domain = openDomain else { return }
        updateRunningApp()
        let started = generation
        let values = await store.values(in: domain.id)
        guard openDomain?.id == domain.id, started == generation else { return }
        if values != self.values { self.values = values }
    }

    /// Reads the open domain until the calling task is cancelled, for changes made elsewhere.
    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.refreshInterval)
            await reload()
        }
    }

    // MARK: Changes

    func set(_ value: DefaultsValue, for key: String) async {
        guard let domain = openDomain else { return }
        await write([DefaultsChange(key: key, value: value)], in: domain.id)
    }

    func delete(_ key: String) async {
        guard let domain = openDomain else { return }
        await write([DefaultsChange(key: key, value: nil)], in: domain.id)
    }

    /// Adds a key that isn't in the domain yet; false when it is, or the value can't be read.
    @discardableResult
    func add(_ key: String, text: String, as kind: DefaultsValue.Kind) async -> Bool {
        let key = key.trimmingCharacters(in: .whitespaces)
        guard let domain = openDomain, !key.isEmpty else { return false }
        guard values[key] == nil else {
            error = "“\(key)” is already set. Change it in the list."
            return false
        }
        guard let value = DefaultsValue.parse(text, as: kind) else {
            error = "“\(text)” isn't a valid \(kind.title.lowercased())."
            return false
        }
        return await write([DefaultsChange(key: key, value: value)], in: domain.id)
    }

    /// Runs `change` after the changes queued before it.
    private func serially<T: Sendable>(_ change: @escaping @MainActor () async -> T) async -> T {
        let previous = lastChange
        let task = Task { @MainActor in
            await previous?.value
            return await change()
        }
        lastChange = Task { _ = await task.value }
        return await task.value
    }

    /// Writes to any domain, the open one or a hidden setting's, saving its original first.
    @discardableResult
    private func write(_ changes: [DefaultsChange], in id: String) async -> Bool {
        await serially { await self.performWrite(changes, in: id, backingUp: true) }
    }

    /// Only from inside `serially`.
    private func performWrite(_ changes: [DefaultsChange], in id: String, backingUp: Bool) async -> Bool {
        generation += 1
        defer { generation += 1 }
        do {
            if backingUp { try await backUpIfNeeded(id) }
            try await store.write(changes, in: id)
            error = nil
        } catch {
            let title = openDomain?.id == id ? openDomain?.title : nil
            self.error = "Couldn't change \(title ?? domain(named: id).title): \(error.localizedDescription)"
            return false
        }
        if openDomain?.id == id {
            for change in changes { edits[change.key] = change }
        }
        // Read back rather than assumed, as cfprefsd may not have taken every change.
        let values = await store.values(in: id)
        if openDomain?.id == id { self.values = values }
        if tweakValues[id] != nil { tweakValues[id] = values }
        keyIndex[id] = Array(values.keys)
        if !values.isEmpty, !domains.contains(where: { $0.id == id }) {
            domains = DefaultsDomain.sorted(domains + [domain(named: id)])
        }
        return true
    }

    // MARK: Backups

    func backupURL(for domain: DefaultsDomain) -> URL? {
        backupURL(for: domain.id)
    }

    func hasBackup(_ domain: DefaultsDomain) -> Bool {
        hasBackup(domain.id)
    }

    private func backupURL(for id: String) -> URL? {
        backupDirectory?.appending(path: "\(id.replacing("/", with: "_")).plist")
    }

    private func hasBackup(_ id: String) -> Bool {
        backedUpDomains.contains(id.replacing("/", with: "_"))
    }

    /// Saves the domain as it is now, once: later changes keep the copy from before the first.
    private func backUpIfNeeded(_ id: String) async throws {
        guard let url = backupURL(for: id), !hasBackup(id) else { return }
        let current = await store.values(in: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DefaultsValue.plistData(current).write(to: url, options: .atomic)
        backedUpDomains.insert(url.deletingPathExtension().lastPathComponent)
    }

    /// Puts the open domain back as it was before its first change: keys added since are
    /// deleted, and changed ones get their old values. The copy is kept.
    func restoreBackup() async {
        guard let domain = openDomain, let url = backupURL(for: domain), hasBackup(domain) else { return }
        let original: [String: DefaultsValue]
        do {
            original = try DefaultsValue.values(fromPlist: Data(contentsOf: url))
        } catch {
            self.error = "Couldn't read the saved copy of \(domain.title): \(error.localizedDescription)"
            return
        }
        let restored = await serially { () -> Bool in
            let current = await self.store.values(in: domain.id)
            let removed = current.keys.filter { original[$0] == nil }.map { DefaultsChange(key: $0, value: nil) }
            let changed = original.filter { current[$0.key] != $0.value }.map { DefaultsChange(key: $0.key, value: $0.value) }
            guard !removed.isEmpty || !changed.isEmpty else { return false }
            return await self.performWrite((removed + changed).sorted { $0.key < $1.key }, in: domain.id, backingUp: false)
        }
        if restored, tweakValues[domain.id] != nil {
            pendingRestarts.formUnion(DefaultsTweak.all.filter { $0.domain == domain.id && $0.restart.processName != nil }.map(\.restart))
        }
    }

    // MARK: Hidden settings

    func loadTweaks() async {
        var values: [String: [String: DefaultsValue]] = [:]
        for domain in Set(DefaultsTweak.all.map(\.domain)) {
            values[domain] = await store.values(in: domain)
        }
        if values != tweakValues { tweakValues = values }
    }

    func storedValue(of tweak: DefaultsTweak) -> DefaultsValue? {
        tweakValues[tweak.domain]?[tweak.key]
    }

    /// Sets the tweak's key, or deletes it for the default with nil.
    func apply(_ tweak: DefaultsTweak, _ value: DefaultsValue?) async {
        guard storedValue(of: tweak) != value else { return }
        guard await write([DefaultsChange(key: tweak.key, value: value)], in: tweak.domain) else { return }
        if tweak.restart.processName != nil { pendingRestarts.insert(tweak.restart) }
    }

    /// Quits the Dock or Finder, which launchd opens again straight away with the new settings.
    func restart(_ restart: DefaultsTweak.Restart) {
        guard restart.processName != nil else { return }
        quitProcesses(restart.rawValue)
        pendingRestarts.remove(restart)
    }

    /// Asks each process to quit as `killall` does, which the Dock and Finder take as a restart.
    static func quitProcesses(_ bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            kill(app.processIdentifier, SIGTERM)
        }
    }

    // MARK: Running apps

    private func updateRunningApp() {
        var app: NSRunningApplication?
        if let domain = openDomain, !domain.isGlobal, domain.id != Bundle.main.bundleIdentifier {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: domain.id).first { !$0.isTerminated }
        }
        if app?.processIdentifier != runningApp?.processIdentifier { runningApp = app }
    }

    /// Quits the open domain's app and opens it again, unless it comes back by itself as the
    /// Dock and Finder do. Apps can save their settings as they quit, over changes made here
    /// while they ran, so those are written again once it has quit.
    func restartApp() async {
        guard let domain = openDomain, let app = runningApp else { return }
        let appURL = app.bundleURL ?? domain.appURL
        app.terminate()
        for _ in 0..<50 where !app.isTerminated {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard app.isTerminated else {
            error = "\(domain.title) didn't quit. It may be waiting for you to save something."
            return
        }
        await reapplyEdits(in: domain.id)
        try? await Task.sleep(for: .seconds(1))
        if NSRunningApplication.runningApplications(withBundleIdentifier: domain.id).isEmpty, let appURL {
            do {
                try await NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                self.error = "Couldn't open \(domain.title) again: \(error.localizedDescription)"
            }
        }
        await reload()
    }

    /// Writes again the changes made here that the domain no longer has.
    func reapplyEdits(in id: String) async {
        guard openDomain?.id == id else { return }
        let edits = Array(edits.values)
        _ = await serially { () -> Bool in
            let current = await self.store.values(in: id)
            let lost = edits.filter { current[$0.key] != $0.value }.sorted { $0.key < $1.key }
            guard !lost.isEmpty else { return false }
            return await self.performWrite(lost, in: id, backingUp: false)
        }
    }
}
