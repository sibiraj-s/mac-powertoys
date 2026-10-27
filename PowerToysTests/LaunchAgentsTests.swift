import Foundation
import Testing
@testable import PowerToys

private func plist(_ dictionary: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
}

private func item(_ label: String, location: LaunchLocation = .userAgents, disabled: Bool = false) -> LaunchItem {
    LaunchItem(
        label: label, url: URL(filePath: "/tmp/\(label).plist"), location: location,
        program: ["/usr/bin/true"], schedule: "At login", logPaths: [], isDisabledInPlist: disabled
    )
}

struct LaunchItemTests {
    @Test func readsPlists() throws {
        let data = try plist([
            "Label": "com.example.sync",
            "ProgramArguments": ["/usr/local/bin/sync", "--quiet"],
            "RunAtLoad": true,
            "StandardOutPath": "/tmp/sync.log",
            "StandardErrorPath": "/tmp/sync.log",
            "Disabled": true,
        ])
        let item = try #require(LaunchItem.parse(data, url: URL(filePath: "/x/sync.plist"), location: .userAgents))
        #expect(item.label == "com.example.sync")
        #expect(item.program == ["/usr/local/bin/sync", "--quiet"])
        #expect(item.commandLine == "sync --quiet")
        #expect(item.schedule == "At login")
        #expect(item.logPaths == ["/tmp/sync.log"])
        #expect(item.isDisabledInPlist)
    }

    @Test func programReplacesTheFirstArgument() throws {
        let data = try plist(["Label": "a", "Program": "/bin/real", "ProgramArguments": ["shown", "-x"]])
        let item = try #require(LaunchItem.parse(data, url: URL(filePath: "/x/a.plist"), location: .agents))
        #expect(item.program == ["/bin/real", "-x"])
        let bare = try #require(LaunchItem.parse(try plist(["Program": "/bin/only"]), url: URL(filePath: "/x/fallback.plist"), location: .agents))
        #expect(bare.label == "fallback")
        #expect(bare.program == ["/bin/only"])
    }

    @Test func knowsWhatLaunchdRestarts() throws {
        let always = try #require(LaunchItem.parse(try plist(["Label": "a", "KeepAlive": true]), url: URL(filePath: "/x/a.plist"), location: .agents))
        #expect(always.restartsWhenStopped)
        let sometimes = try #require(LaunchItem.parse(
            try plist(["Label": "b", "KeepAlive": ["SuccessfulExit": false]]), url: URL(filePath: "/x/b.plist"), location: .agents
        ))
        #expect(!sometimes.restartsWhenStopped)
    }

    @Test func notAPlist() {
        #expect(LaunchItem.parse(Data("nope".utf8), url: URL(filePath: "/x/a.plist"), location: .agents) == nil)
    }

    @Test func schedulesInWords() {
        #expect(LaunchItem.schedule(of: ["RunAtLoad": true], isDaemon: false) == "At login")
        #expect(LaunchItem.schedule(of: ["RunAtLoad": true], isDaemon: true) == "At startup")
        #expect(LaunchItem.schedule(of: ["KeepAlive": true, "RunAtLoad": true], isDaemon: false) == "Kept running")
        #expect(LaunchItem.schedule(of: ["KeepAlive": ["SuccessfulExit": false]], isDaemon: false) == "Kept running when needed")
        #expect(LaunchItem.schedule(of: ["KeepAlive": false, "RunAtLoad": true], isDaemon: false) == "At login")
        #expect(LaunchItem.schedule(of: ["StartInterval": 3600], isDaemon: false) == "Every hour")
        #expect(LaunchItem.schedule(of: ["StartInterval": 300], isDaemon: false) == "Every 5 minutes")
        #expect(LaunchItem.schedule(of: ["StartInterval": 90], isDaemon: false) == "Every 90 seconds")
        #expect(LaunchItem.schedule(of: ["StartCalendarInterval": ["Hour": 9, "Minute": 5]], isDaemon: false) == "Daily at 09:05")
        #expect(LaunchItem.schedule(of: ["StartCalendarInterval": ["Weekday": 1, "Hour": 9]], isDaemon: false) == "Mondays at 09:00")
        #expect(LaunchItem.schedule(of: ["StartCalendarInterval": ["Minute": 15]], isDaemon: false) == "Hourly at :15")
        #expect(LaunchItem.schedule(of: ["StartCalendarInterval": ["Day": 1, "Hour": 0]], isDaemon: false) == "Monthly on day 1 at 00:00")
        #expect(LaunchItem.schedule(of: ["StartCalendarInterval": [["Hour": 9], ["Hour": 17]]], isDaemon: false) == "On a schedule")
        #expect(LaunchItem.schedule(of: ["StartCalendarInterval": ["Month": 1, "Day": 1, "Hour": 0]], isDaemon: false) == "Yearly on January 1 at 00:00")
        #expect(LaunchItem.schedule(of: ["StartCalendarInterval": ["Month": 6, "Weekday": 1, "Hour": 9]], isDaemon: false) == "Mondays in June at 09:00")
        #expect(LaunchItem.schedule(of: ["StartCalendarInterval": ["Month": 12, "Hour": 8]], isDaemon: false) == "Daily in December at 08:00")
        #expect(LaunchItem.schedule(of: ["StartCalendarInterval": ["Month": 13, "Hour": 8]], isDaemon: false) == "On a schedule")
        #expect(LaunchItem.schedule(of: ["StartCalendarInterval": ["Weekday": 1, "Day": 1, "Hour": 8]], isDaemon: false) == "On a schedule")
        #expect(LaunchItem.schedule(of: ["WatchPaths": ["/tmp"]], isDaemon: false) == "When files change")
        #expect(LaunchItem.schedule(of: ["MachServices": ["x": true]], isDaemon: false) == "When something asks for it")
        #expect(LaunchItem.schedule(of: [:], isDaemon: false) == "Only when started")
        #expect(LaunchItem.schedule(of: ["RunAtLoad": true, "StartInterval": 60], isDaemon: false) == "At login, Every minute")
    }

    @Test func filters() {
        let sync = item("com.example.sync")
        #expect(sync.matches(""))
        #expect(sync.matches("EXAMPLE"))
        #expect(sync.matches("bin/true"))
        #expect(!sync.matches("google"))
    }

    @Test func locations() {
        #expect(LaunchLocation.userAgents.domain(uid: 501) == .gui(501))
        #expect(LaunchLocation.agents.domain(uid: 501) == .gui(501))
        #expect(LaunchLocation.daemons.domain(uid: 501) == .system)
        #expect(LaunchDomain.gui(501).target == "gui/501")
        #expect(LaunchLocation.allCases.filter(\.needsAdministrator) == [.daemons])
        #expect(LaunchLocation.allCases.filter(\.canTrash) == [.userAgents])
        #expect(LaunchLocation.allCases.filter(\.isApple) == [.appleAgents, .appleDaemons])
    }
}

struct DomainStateTests {
    @Test func readsServices() {
        let output = """
            gui/501 = {
            \ttype = login
            \tservices = {
            \t\t   32317      - \tapplication.dev.sibiraj.powertoys.4904
            \t\t       0      - \tcom.apple.DataDetectorsLocalSources
            \t\t       0     78 \tcom.example.broken
            \t\t       0     -9 \tcom.example.killed
            \t}
            \tendpoints = {
            \t\t"com.apple.x" = { }
            \t}
            }
            """
        let services = DomainState.services(fromPrint: output)
        #expect(services.count == 4)
        #expect(services["application.dev.sibiraj.powertoys.4904"] == .init(pid: 32317, lastExitStatus: nil))
        #expect(services["com.apple.DataDetectorsLocalSources"] == .init(pid: nil, lastExitStatus: nil))
        #expect(services["com.example.broken"] == .init(pid: nil, lastExitStatus: 78))
        #expect(services["com.example.killed"]?.lastExitStatus == -9)
    }

    @Test func readsOverrides() {
        let output = """

            \tdisabled services = {
            \t\t"com.apple.Siri.agent" => disabled
            \t\t"com.microsoft.update.agent" => enabled
            \t\t"com.old.style" => true
            \t\t"com.old.on" => false
            \t}
            """
        #expect(DomainState.disabled(fromPrintDisabled: output) == [
            "com.apple.Siri.agent": true, "com.microsoft.update.agent": false, "com.old.style": true, "com.old.on": false,
        ])
    }

    @Test func readsTheRealDomain() async throws {
        let state = try await LiveLaunchControl().state(of: .gui(getuid()))
        #expect(!state.services.isEmpty)
    }
}

struct LaunchStatusTests {
    @Test func overridesBeatThePlist() {
        let off = item("a", disabled: true)
        #expect(!LaunchStatus(item: off, domain: nil).isEnabled)
        #expect(LaunchStatus(item: off, domain: DomainState(disabled: ["a": false])).isEnabled)
        #expect(!LaunchStatus(item: item("a"), domain: DomainState(disabled: ["a": true])).isEnabled)
    }

    @Test func text() {
        #expect(LaunchStatus(isEnabled: true, isLoaded: true, pid: 42).text == "Running · PID 42")
        #expect(LaunchStatus(isEnabled: true, isLoaded: true).text == "Waiting to run")
        #expect(LaunchStatus(isEnabled: true, isLoaded: false).text == "Not loaded")
        #expect(LaunchStatus(isEnabled: false, isLoaded: false).text == "Off")
        #expect(LaunchStatus(isEnabled: false, isLoaded: true).text == "Off, still loaded")
        #expect(LaunchStatus(isEnabled: true, isLoaded: true, lastExitStatus: 78).text == "Exited with code 78")
        #expect(LaunchStatus(isEnabled: true, isLoaded: true, lastExitStatus: -9).text == "Stopped by signal 9")
        #expect(LaunchStatus(isEnabled: true, isLoaded: true, lastExitStatus: 78).hasFailed)
        #expect(!LaunchStatus(isEnabled: true, isLoaded: true, pid: 3, lastExitStatus: 78).hasFailed)
    }
}

struct LaunchActionTests {
    private let sync = item("com.example.sync")
    private let domain = LaunchDomain.gui(501)

    @Test func switchingOnLoadsAndOffUnloads() {
        #expect(LaunchAction.commands(for: .enable, item: sync, domain: domain, isLoaded: false) == [
            ["enable", "gui/501/com.example.sync"], ["bootstrap", "gui/501", "/tmp/com.example.sync.plist"],
        ])
        #expect(LaunchAction.commands(for: .enable, item: sync, domain: domain, isLoaded: true) == [["enable", "gui/501/com.example.sync"]])
        #expect(LaunchAction.commands(for: .disable, item: sync, domain: domain, isLoaded: true) == [
            ["bootout", "gui/501/com.example.sync"], ["disable", "gui/501/com.example.sync"],
        ])
        #expect(LaunchAction.commands(for: .disable, item: sync, domain: domain, isLoaded: false) == [["disable", "gui/501/com.example.sync"]])
    }

    @Test func startRestartStop() {
        #expect(LaunchAction.commands(for: .start, item: sync, domain: .system, isLoaded: false) == [
            ["bootstrap", "system", "/tmp/com.example.sync.plist"], ["kickstart", "system/com.example.sync"],
        ])
        #expect(LaunchAction.commands(for: .start, item: sync, domain: .system, isLoaded: true) == [["kickstart", "system/com.example.sync"]])
        #expect(LaunchAction.commands(for: .restart, item: sync, domain: domain, isLoaded: true) == [["kickstart", "-k", "gui/501/com.example.sync"]])
        #expect(LaunchAction.commands(for: .stop, item: sync, domain: domain, isLoaded: true) == [["kill", "SIGTERM", "gui/501/com.example.sync"]])
    }

    @Test func unloadingLeavesItSwitchedOn() {
        #expect(LaunchAction.commands(for: .unload, item: sync, domain: domain, isLoaded: true) == [["bootout", "gui/501/com.example.sync"]])
        #expect(LaunchAction.commands(for: .unload, item: sync, domain: domain, isLoaded: false).isEmpty)
    }
}

final class FakeLaunchControl: LaunchControlling, @unchecked Sendable {
    var items: [LaunchItem] = []
    var states: [LaunchDomain: DomainState] = [:]
    var fails = false
    var stateFails = false
    /// How long reading a domain's state takes, to overlap refreshes.
    var stateDelay: Duration?
    private(set) var runs: [(commands: [[String]], asAdministrator: Bool)] = []
    private(set) var requestedLocations: [[LaunchLocation]] = []

    func items(in locations: [LaunchLocation]) async -> [LaunchItem] {
        requestedLocations.append(locations)
        return items.filter { locations.contains($0.location) }
    }

    func state(of domain: LaunchDomain) async throws -> DomainState {
        if let stateDelay { try await Task.sleep(for: stateDelay) }
        if stateFails { throw CommandError(errorDescription: "launchctl crashed") }
        return states[domain] ?? DomainState()
    }

    func run(_ commands: [[String]], asAdministrator: Bool) async throws {
        if fails { throw CommandError(errorDescription: "Operation not permitted") }
        runs.append((commands, asAdministrator))
        // Acts like launchctl on the labels involved.
        for command in commands {
            guard let target = command.last?.split(separator: "/").last.map(String.init) else { continue }
            let domain: LaunchDomain = command.contains { $0.hasPrefix("system") } ? .system : .gui(501)
            var state = states[domain] ?? DomainState()
            switch command.first {
            case "enable": state.disabled[target] = false
            case "disable": state.disabled[target] = true
            case "bootout": state.services[target] = nil
            case "bootstrap":
                let label = URL(filePath: command[2]).deletingPathExtension().lastPathComponent
                state.services[label] = .init()
            default: break
            }
            states[domain] = state
        }
    }
}

struct LaunchAgentsControllerTests {
    private func makeController(_ control: FakeLaunchControl, defaults: UserDefaults) -> LaunchAgentsController {
        LaunchAgentsController(defaults: defaults, control: control, uid: 501)
    }

    @Test func listsByLocationAndHidesApplesUnlessAsked() async {
        let store = TestDefaults()
        let control = FakeLaunchControl()
        control.items = [item("mine"), item("daemon", location: .daemons), item("apple", location: .appleAgents)]
        let controller = makeController(control, defaults: store.defaults)
        await controller.refresh()
        #expect(controller.isLoaded)
        #expect(controller.items.map(\.label) == ["mine", "daemon"])
        #expect(controller.items(in: .daemons).map(\.label) == ["daemon"])
        #expect(!controller.locations.contains(.appleAgents))

        controller.showsAppleItems = true
        await controller.refresh()
        #expect(controller.items.map(\.label).contains("apple"))
    }

    @Test func switchesAgentsWithoutAPassword() async {
        let store = TestDefaults()
        let control = FakeLaunchControl()
        let mine = item("mine")
        control.items = [mine]
        control.states[.gui(501)] = DomainState(services: ["mine": .init(pid: 9)])
        let controller = makeController(control, defaults: store.defaults)
        await controller.refresh()
        #expect(controller.status(of: mine).pid == 9)

        await controller.setEnabled(mine, false)
        #expect(control.runs.last?.commands == [["bootout", "gui/501/mine"], ["disable", "gui/501/mine"]])
        #expect(control.runs.last?.asAdministrator == false)
        #expect(!controller.status(of: mine).isEnabled)
        #expect(!controller.status(of: mine).isLoaded)

        await controller.setEnabled(mine, true)
        #expect(controller.status(of: mine).isEnabled)
        #expect(controller.status(of: mine).isLoaded)
        #expect(controller.busy.isEmpty)
    }

    @Test func daemonsAskForAPassword() async {
        let store = TestDefaults()
        let control = FakeLaunchControl()
        let daemon = item("daemon", location: .daemons)
        control.items = [daemon]
        let controller = makeController(control, defaults: store.defaults)
        await controller.refresh()
        await controller.perform(.start, on: daemon)
        #expect(control.runs.last?.asAdministrator == true)
        #expect(control.runs.last?.commands.first == ["bootstrap", "system", "/tmp/daemon.plist"])
    }

    @Test func applesJobsCantBeChanged() async {
        let store = TestDefaults()
        let control = FakeLaunchControl()
        let apple = item("apple", location: .appleDaemons)
        let controller = makeController(control, defaults: store.defaults)
        await controller.perform(.stop, on: apple)
        await controller.setEnabled(apple, false)
        #expect(control.runs.isEmpty)
    }

    @Test func failuresAreShown() async {
        let store = TestDefaults()
        let control = FakeLaunchControl()
        control.fails = true
        let mine = item("mine")
        control.items = [mine]
        let controller = makeController(control, defaults: store.defaults)
        await controller.perform(.restart, on: mine)
        #expect(controller.error?.contains("Operation not permitted") == true)
        #expect(controller.busy.isEmpty)
    }

    @Test func movesYourAgentsToTheTrash() async throws {
        let store = TestDefaults()
        let control = FakeLaunchControl()
        let directory = FileManager.default.temporaryDirectory.appending(path: "launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "leftover.plist")
        try plist(["Label": "leftover"]).write(to: url)
        let leftover = LaunchItem(
            label: "leftover", url: url, location: .userAgents, program: ["/gone"],
            schedule: "At login", logPaths: [], isDisabledInPlist: false, isProgramMissing: true
        )
        control.items = [leftover]
        control.states[.gui(501)] = DomainState(services: ["leftover": .init()])
        let controller = makeController(control, defaults: store.defaults)
        await controller.refresh()

        await controller.moveToTrash(leftover)
        // Unloaded first.
        #expect(control.runs.first?.commands == [["bootout", "gui/501/leftover"]])
        // Not switched off, so a reinstall works.
        #expect(control.states[.gui(501)]?.disabled["leftover"] == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(controller.items.isEmpty)

        // Not for jobs outside your folder.
        let daemon = item("daemon", location: .daemons)
        await controller.moveToTrash(daemon)
        #expect(control.runs.count == 1)
    }

    @Test func readsPlistsOnlyWhenNeeded() async {
        let store = TestDefaults()
        let control = FakeLaunchControl()
        let mine = item("mine")
        control.items = [mine]
        let controller = makeController(control, defaults: store.defaults)
        await controller.refresh()
        await controller.refresh()
        #expect(control.requestedLocations.count == 1)

        controller.showsAppleItems = true
        await controller.refresh(readingPlists: true)
        #expect(control.requestedLocations.count == 2)

        await controller.perform(.restart, on: mine)
        #expect(control.requestedLocations.count == 3)
    }

    @Test func aRefreshDuringAnotherStillRuns() async {
        let store = TestDefaults()
        let control = FakeLaunchControl()
        let mine = item("mine")
        control.items = [mine]
        control.stateDelay = .milliseconds(100)
        let controller = makeController(control, defaults: store.defaults)
        let first = Task { await controller.refresh() }
        try? await Task.sleep(for: .milliseconds(20))
        control.states[.gui(501)] = DomainState(services: ["mine": .init(pid: 7)])
        await controller.refresh()
        #expect(controller.status(of: mine).pid == 7)
        await first.value
    }

    @Test func actsOnLaunchdsStateNow() async {
        let store = TestDefaults()
        let control = FakeLaunchControl()
        let mine = item("mine")
        control.items = [mine]
        let controller = makeController(control, defaults: store.defaults)
        await controller.refresh()
        #expect(!controller.status(of: mine).isLoaded)
        // Loaded by something else since.
        control.states[.gui(501)] = DomainState(services: ["mine": .init()])
        await controller.setEnabled(mine, true)
        #expect(control.runs.last?.commands == [["enable", "gui/501/mine"]])
    }

    @Test func readErrorsClearOnceLaunchdAnswers() async {
        let store = TestDefaults()
        let control = FakeLaunchControl()
        control.stateFails = true
        let controller = makeController(control, defaults: store.defaults)
        await controller.refresh()
        #expect(controller.error?.contains("launchctl crashed") == true)
        control.stateFails = false
        await controller.refresh()
        #expect(controller.error == nil)

        // Other errors stay until something else replaces them.
        let mine = item("mine")
        control.fails = true
        await controller.perform(.restart, on: mine)
        await controller.refresh()
        #expect(controller.error?.contains("Operation not permitted") == true)
    }

    @Test func saysWhenALogIsMissing() {
        let store = TestDefaults()
        let controller = makeController(FakeLaunchControl(), defaults: store.defaults)
        controller.openLog("/nonexistent/\(UUID().uuidString).log", of: item("mine"))
        #expect(controller.error?.contains("hasn't written") == true)
    }
}
