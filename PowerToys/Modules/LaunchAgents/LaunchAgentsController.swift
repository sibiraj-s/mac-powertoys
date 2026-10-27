import AppKit
import Darwin
import Foundation
import Observation

/// Reads launchd jobs and runs launchctl; a protocol so tests don't change real jobs.
protocol LaunchControlling: Sendable {
    func items(in locations: [LaunchLocation]) async -> [LaunchItem]
    func state(of domain: LaunchDomain) async throws -> DomainState
    /// Runs `launchctl` once per entry, in order, stopping at the first failure. As an
    /// administrator, macOS asks for a password first.
    func run(_ commands: [[String]], asAdministrator: Bool) async throws
}

nonisolated struct LiveLaunchControl: LaunchControlling {
    private static let launchctl = "/bin/launchctl"

    @concurrent
    func items(in locations: [LaunchLocation]) async -> [LaunchItem] {
        let files = FileManager.default
        return locations.flatMap { location in
            let urls = (try? files.contentsOfDirectory(at: location.directory, includingPropertiesForKeys: nil)) ?? []
            return urls.filter { $0.pathExtension == "plist" }.compactMap { url -> LaunchItem? in
                guard let data = try? Data(contentsOf: url),
                      var item = LaunchItem.parse(data, url: url, location: location)
                else { return nil }
                if let program = item.program.first, program.hasPrefix("/") {
                    item.isProgramMissing = !files.fileExists(atPath: program)
                }
                return item
            }
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func state(of domain: LaunchDomain) async throws -> DomainState {
        async let services = Command.run(Self.launchctl, ["print", domain.target], timeout: .seconds(10))
        async let disabled = Command.run(Self.launchctl, ["print-disabled", domain.target], timeout: .seconds(10))
        let (servicesOutput, disabledOutput) = try await (services, disabled)
        guard servicesOutput.status == 0 else { throw Self.error(servicesOutput) }
        return DomainState(
            services: DomainState.services(fromPrint: servicesOutput.stdout),
            disabled: DomainState.disabled(fromPrintDisabled: disabledOutput.stdout)
        )
    }

    func run(_ commands: [[String]], asAdministrator: Bool) async throws {
        if asAdministrator {
            let script = commands
                .map { ([Self.launchctl] + $0.map(Command.shellQuoted)).joined(separator: " ") }
                .joined(separator: " && ")
            try await Command.runAsAdministrator(script, prompt: "PowerToys wants to change a launch daemon.")
            return
        }
        for arguments in commands {
            let output = try await Command.run(Self.launchctl, arguments, timeout: .seconds(30))
            guard output.status == 0 else { throw Self.error(output) }
        }
    }

    private static func error(_ output: Command.Output) -> CommandError {
        let message = [output.stderr, output.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return CommandError(errorDescription: message ?? "launchctl failed with code \(output.status).")
    }
}

/// Launch agents and daemons, their state, and changes to them.
@Observable
final class LaunchAgentsController {
    private(set) var items: [LaunchItem] = []
    private(set) var states: [LaunchDomain: DomainState] = [:]
    private(set) var isLoaded = false
    private(set) var error: String?
    /// Jobs with a change in progress.
    private(set) var busy: Set<LaunchItem.ID> = []

    var showsAppleItems: Bool {
        didSet {
            defaults.set(showsAppleItems, forKey: Self.showsAppleItemsKey)
            Task { await refresh(readingPlists: true) }
        }
    }

    static let showsAppleItemsKey = "launchAgents.showsAppleItems"
    static let refreshInterval: Duration = .seconds(3)

    private let defaults: UserDefaults
    @ObservationIgnored private let control: any LaunchControlling
    @ObservationIgnored private let uid: uid_t
    /// The refresh running now, which later requests wait on.
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// Set when a refresh is asked for while one is running, so it runs again after.
    @ObservationIgnored private var needsRefresh = false
    /// Set when the plists should be read again, not just launchd's state.
    @ObservationIgnored private var needsPlists = true
    /// Whether `error` is about reading launchd's state, which a good read clears.
    @ObservationIgnored private var isReadError = false

    init(defaults: UserDefaults = .standard, control: any LaunchControlling = LiveLaunchControl(), uid: uid_t = getuid()) {
        self.defaults = defaults
        self.control = control
        self.uid = uid
        showsAppleItems = defaults.bool(forKey: Self.showsAppleItemsKey)
    }

    var locations: [LaunchLocation] {
        LaunchLocation.allCases.filter { showsAppleItems || !$0.isApple }
    }

    func items(in location: LaunchLocation) -> [LaunchItem] {
        items.filter { $0.location == location }
    }

    func status(of item: LaunchItem) -> LaunchStatus {
        LaunchStatus(item: item, domain: states[item.location.domain(uid: uid)])
    }

    /// Reads launchd's state, and the plists on the first read or with `readingPlists`. A
    /// request made while a refresh is running runs once that one finishes, and returns after.
    func refresh(readingPlists: Bool = false) async {
        if readingPlists { needsPlists = true }
        if let refreshing {
            needsRefresh = true
            await refreshing.value
            return
        }
        let task = Task { await runRefreshes() }
        refreshing = task
        await task.value
    }

    private func runRefreshes() async {
        repeat {
            needsRefresh = false
            if needsPlists {
                needsPlists = false
                let items = await control.items(in: locations)
                if items != self.items { self.items = items }
            }
            do {
                var states: [LaunchDomain: DomainState] = [:]
                for domain in [LaunchDomain.gui(uid), .system] {
                    states[domain] = try await control.state(of: domain)
                }
                if states != self.states { self.states = states }
                if isReadError { error = nil }
            } catch {
                show("Couldn't read launchd's state: \(error.localizedDescription)", isReadError: true)
            }
            isLoaded = true
        } while needsRefresh
        // Cleared in the same step as the last check, so a request can't slip in between.
        refreshing = nil
    }

    /// Refreshes until the calling task is cancelled, for PIDs and exit codes that change.
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func setEnabled(_ item: LaunchItem, _ isEnabled: Bool) async {
        await perform(isEnabled ? .enable : .disable, on: item)
    }

    /// Runs the action and refreshes; false when it couldn't be done.
    @discardableResult
    func perform(_ action: LaunchAction, on item: LaunchItem) async -> Bool {
        guard !item.location.isApple, !busy.contains(item.id) else { return false }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        let domain = item.location.domain(uid: uid)
        // Asked now rather than taken from the last refresh, which something else may have changed since.
        let isLoaded = if let current = try? await control.state(of: domain) {
            current.services[item.label] != nil
        } else {
            status(of: item).isLoaded
        }
        let commands = LaunchAction.commands(for: action, item: item, domain: domain, isLoaded: isLoaded)
        var succeeded = true
        if !commands.isEmpty {
            do {
                try await control.run(commands, asAdministrator: item.location.needsAdministrator)
                if !isReadError { error = nil }
            } catch is CancellationError {
                succeeded = false
            } catch {
                show("Couldn't change \(item.label): \(error.localizedDescription)")
                succeeded = false
            }
        }
        await refresh(readingPlists: true)
        return succeeded
    }

    /// Unloads one of your agents and moves its plist to the Trash, where it can be put back.
    /// It isn't switched off, so it works again if it's put back or its app is reinstalled.
    func moveToTrash(_ item: LaunchItem) async {
        guard item.location.canTrash, !busy.contains(item.id) else { return }
        guard await perform(.unload, on: item) else { return }
        guard !status(of: item).isLoaded else {
            show("Couldn't unload \(item.label), so it was left in place.")
            return
        }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            items.removeAll { $0.id == item.id }
        } catch {
            show("Couldn't move \(item.label) to the Trash: \(error.localizedDescription)")
        }
    }

    /// Opens a log file, or says it hasn't been written yet.
    func openLog(_ path: String, of item: LaunchItem) {
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(filePath: path))
        } else {
            show("\(item.label) hasn't written \(URL(filePath: path).lastPathComponent) yet.")
        }
    }

    private func show(_ message: String, isReadError: Bool = false) {
        error = message
        self.isReadError = isReadError
    }
}
