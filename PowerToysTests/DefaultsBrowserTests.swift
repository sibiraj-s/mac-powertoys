import AppKit
import Foundation
import Testing
@testable import PowerToys

struct DefaultsValueTests {
    @Test func readsPlistTypes() throws {
        let plist: [String: Any] = [
            "bool": true, "int": 42, "real": 1.5, "string": "hi",
            "date": Date(timeIntervalSince1970: 0), "data": Data([1, 2]),
            "array": [1, "two"], "dict": ["nested": false],
        ]
        let values = try #require(DefaultsValue(plist: plist))
        #expect(values == .dictionary([
            "bool": .bool(true), "int": .integer(42), "real": .real(1.5), "string": .string("hi"),
            "date": .date(Date(timeIntervalSince1970: 0)), "data": .data(Data([1, 2])),
            "array": .array([.integer(1), .string("two")]), "dict": .dictionary(["nested": .bool(false)]),
        ]))
    }

    @Test func tellsBooleansFromNumbers() {
        #expect(DefaultsValue(plist: NSNumber(value: true)) == .bool(true))
        #expect(DefaultsValue(plist: NSNumber(value: 1)) == .integer(1))
        #expect(DefaultsValue(plist: NSNumber(value: 1.0)) == .real(1))
        #expect(DefaultsValue(plist: kCFBooleanFalse as Any) == .bool(false))
    }

    @Test func roundTripsThroughAPlistFile() throws {
        let values: [String: DefaultsValue] = [
            "flag": .bool(false), "count": .integer(-3), "scale": .real(0.25), "name": .string("a\nb"),
            "when": .date(Date(timeIntervalSince1970: 1_800_000_000)), "blob": .data(Data([0xFF])),
            "list": .array([.dictionary(["x": .integer(1)])]),
        ]
        #expect(try DefaultsValue.values(fromPlist: DefaultsValue.plistData(values)) == values)
        #expect(throws: (any Error).self) { try DefaultsValue.values(fromPlist: Data("nope".utf8)) }
    }

    @Test func summarizes() {
        #expect(DefaultsValue.bool(true).summary == "true")
        #expect(DefaultsValue.integer(7).summary == "7")
        #expect(DefaultsValue.real(0.5).summary == "0.5")
        #expect(DefaultsValue.data(Data([1])).summary == "1 byte")
        #expect(DefaultsValue.array([.integer(1), .integer(2)]).summary == "2 items")
        #expect(DefaultsValue.dictionary(["a": .integer(1)]).summary == "1 key")
    }

    @Test func parsesTypedText() {
        #expect(DefaultsValue.parse(" 12 ", as: .integer) == .integer(12))
        #expect(DefaultsValue.parse("1.5", as: .integer) == nil)
        #expect(DefaultsValue.parse("1.5", as: .real) == .real(1.5))
        #expect(DefaultsValue.parse("inf", as: .real) == nil)
        #expect(DefaultsValue.parse("YES", as: .bool) == .bool(true))
        #expect(DefaultsValue.parse("0", as: .bool) == .bool(false))
        #expect(DefaultsValue.parse("maybe", as: .bool) == nil)
        #expect(DefaultsValue.parse(" spaced ", as: .string) == .string(" spaced "))
        #expect(DefaultsValue.parse("x", as: .array) == nil)
    }

    @Test func listsChildrenInOrder() {
        let dictionary = DefaultsValue.dictionary(["b10": .integer(1), "b2": .integer(2), "a": .integer(3)])
        #expect(dictionary.children.map(\.label) == ["a", "b2", "b10"])
        #expect(DefaultsValue.array([.bool(true), .bool(false)]).children.map(\.label) == ["0", "1"])
        #expect(DefaultsValue.integer(1).children.isEmpty)
    }

    @Test func searchesInsideValues() {
        let value = DefaultsValue.dictionary(["Name": .string("Terminal"), "list": .array([.integer(3000)])])
        #expect(value.contains("termin"))
        #expect(value.contains("name"))
        #expect(value.contains("3000"))
        #expect(!value.contains("zsh"))
        #expect(!DefaultsValue.data(Data([1])).contains("1"))
    }

    @Test func writesCommands() {
        #expect(DefaultsValue.writeCommand(domain: "com.apple.dock", key: "autohide", value: .bool(true))
            == "defaults write com.apple.dock autohide -bool true")
        #expect(DefaultsValue.writeCommand(domain: "com.apple.dock", key: "tilesize", value: .integer(48))
            == "defaults write com.apple.dock tilesize -int 48")
        #expect(DefaultsValue.writeCommand(domain: "com.apple.dock", key: "autohide-delay", value: .real(0))
            == "defaults write com.apple.dock autohide-delay -float 0.0")
        #expect(DefaultsValue.writeCommand(domain: "NSGlobalDomain", key: "My Key", value: .string("it's"))
            == #"defaults write NSGlobalDomain 'My Key' -string 'it'\''s'"#)
        #expect(DefaultsValue.writeCommand(domain: "x", key: "d", value: .data(Data([0x0A, 0xFF])))
            == "defaults write x d -data 0aff")
        #expect(DefaultsValue.writeCommand(domain: "x", key: "a", value: .array([.integer(1), .string("b")]))
            == "defaults write x a '<array><integer>1</integer><string>b</string></array>'")
        #expect(DefaultsValue.readCommand(domain: "x") == "defaults read x")
        #expect(DefaultsValue.readCommand(domain: "x", key: "a b") == "defaults read x 'a b'")
        #expect(DefaultsValue.deleteCommand(domain: "x", key: "a") == "defaults delete x a")
    }

    @Test func keepsNewlinesInsideXMLText() {
        #expect(DefaultsValue.array([.string("a\n\tb")]).xmlFragment == "<array><string>a\n\tb</string></array>")
    }
}

/// Against the real preferences system, in a throwaway domain.
@Suite(.serialized)
struct LiveDefaultsStoreTests {
    /// A path, which CFPreferences and `defaults` both take as a domain, so nothing is left in
    /// ~/Library/Preferences: cfprefsd writes an emptied domain's file back after it's deleted.
    private let domain = FileManager.default.temporaryDirectory.appending(path: "PowerToysTests-\(UUID().uuidString)").path
    private let store = LiveDefaultsStore()

    private func cleanUp() async throws {
        _ = try await Command.run("/usr/bin/defaults", ["delete", domain])
        try? FileManager.default.removeItem(atPath: domain + ".plist")
    }

    @Test func writesReadsAndDeletes() async throws {
        let values: [String: DefaultsValue] = [
            "flag": .bool(true), "count": .integer(3), "name": .string("x"),
            "list": .array([.dictionary(["k": .real(1.5)])]),
        ]
        try await store.write(values.map { DefaultsChange(key: $0.key, value: $0.value) }, in: domain)
        #expect(await store.values(in: domain) == values)
        #expect(Set(await store.keys(in: [domain])[domain] ?? []) == Set(values.keys))

        try await store.write([DefaultsChange(key: "flag", value: nil)], in: domain)
        #expect(await store.values(in: domain)["flag"] == nil)
        try await cleanUp()
    }

    /// The copied commands do what they say when pasted into a shell.
    @Test func copiedCommandsWork() async throws {
        let values: [String: DefaultsValue] = [
            "flag": .bool(false), "count": .integer(-2), "scale": .real(1.5), "quote": .string("it's \"here\""),
            "blob": .data(Data([0x0A, 0xFF])), "when": .date(Date(timeIntervalSince1970: 1_800_000_000)),
            "list": .array([.string("a"), .dictionary(["n": .integer(1), "on": .bool(true)])]),
            "dict": .dictionary(["nested": .array([.real(0.5)])]),
        ]
        for (key, value) in values {
            let output = try await Command.run("/bin/sh", ["-c", DefaultsValue.writeCommand(domain: domain, key: key, value: value)])
            #expect(output.status == 0, "\(key): \(output.stderr)")
        }
        #expect(await store.values(in: domain) == values)

        let output = try await Command.run("/bin/sh", ["-c", DefaultsValue.deleteCommand(domain: domain, key: "flag")])
        #expect(output.status == 0)
        #expect(await store.values(in: domain)["flag"] == nil)
        try await cleanUp()
    }

    @Test func findsTheGlobalDomain() async {
        let domains = await store.domains()
        #expect(domains.first?.id == DefaultsDomain.global)
        #expect(domains.contains { $0.id == "com.apple.finder" && $0.appName == "Finder" })
        #expect(!domains.contains { $0.id.hasPrefix(".") })
    }
}

@MainActor
struct DefaultsBrowserControllerTests {
    private let store = FakeDefaultsStore()
    private let backups = FileManager.default.temporaryDirectory.appending(path: "PowerToysTests-\(UUID().uuidString)")

    private func controller() -> DefaultsBrowserController {
        DefaultsBrowserController(store: store, backupDirectory: backups)
    }

    private var finder: DefaultsDomain { DefaultsDomain(id: "com.apple.finder", appName: "Finder") }
    private var editor: DefaultsDomain { DefaultsDomain(id: "com.example.editor", appName: "Editor") }

    init() {
        store.domains = [
            editor, finder, DefaultsDomain(id: DefaultsDomain.global),
        ]
        store.values = [
            "com.apple.finder": ["AppleShowAllFiles": .bool(false), "FXPreferredViewStyle": .string("Nlsv")],
            "com.example.editor": ["fontSize": .integer(12)],
            DefaultsDomain.global: ["AppleInterfaceStyle": .string("Dark")],
        ]
    }

    @Test func sortsTheGlobalDomainFirst() {
        let sorted = DefaultsDomain.sorted([editor, finder, DefaultsDomain(id: DefaultsDomain.global)])
        #expect(sorted.map(\.title) == ["Global", "Editor", "Finder"])
    }

    @Test func tellsAppleDomainsApart() {
        #expect(finder.isApple)
        #expect(DefaultsDomain(id: DefaultsDomain.global).isApple)
        #expect(!editor.isApple)
        #expect(DefaultsDomain(id: "com.example.tool").title == "com.example.tool")
    }

    @Test func loadsDomainsAndTheirKeys() async {
        let browser = controller()
        #expect(!browser.isLoaded)
        await browser.loadDomains()
        #expect(browser.isLoaded)
        #expect(browser.domains.count == 3)
        #expect(browser.keyIndex["com.apple.finder"]?.sorted() == ["AppleShowAllFiles", "FXPreferredViewStyle"])
    }

    @Test func filtersDomainsByNameIdentifierOrKey() async {
        let browser = controller()
        await browser.loadDomains()
        #expect(browser.domains(matching: "").count == 3)
        #expect(browser.domains(matching: "edit").map(\.id) == ["com.example.editor"])
        #expect(browser.domains(matching: "apple.finder").map(\.id) == ["com.apple.finder"])
        #expect(browser.domains(matching: "showall").map(\.id) == ["com.apple.finder"])
        #expect(browser.matchingKeys(in: finder, "showall") == ["AppleShowAllFiles"])
        #expect(browser.domains(matching: "nothing").isEmpty)
    }

    @Test func namesTheGlobalDomainAnyWay() async {
        let browser = controller()
        await browser.loadDomains()
        #expect(browser.domain(named: "-g").isGlobal)
        #expect(browser.domain(named: " NSGlobalDomain ").isGlobal)
        #expect(browser.domain(named: "com.apple.finder").appName == "Finder")
    }

    @Test func opensAndClosesADomain() async {
        let browser = controller()
        await browser.open(finder, filter: "show")
        #expect(browser.openDomain == finder)
        #expect(browser.keyFilter == "show")
        #expect(browser.values["AppleShowAllFiles"] == .bool(false))
        browser.close()
        #expect(browser.openDomain == nil)
        #expect(browser.values.isEmpty)
        #expect(browser.keyFilter.isEmpty)
    }

    @Test func changesAKeyAfterSavingTheOriginal() async throws {
        let browser = controller()
        await browser.open(finder)
        #expect(!browser.hasBackup(finder))
        await browser.set(.bool(true), for: "AppleShowAllFiles")
        #expect(browser.values["AppleShowAllFiles"] == .bool(true))
        #expect(store.writes.last?.changes == [DefaultsChange(key: "AppleShowAllFiles", value: .bool(true))])
        #expect(browser.hasBackup(finder))

        let url = try #require(browser.backupURL(for: finder))
        let saved = try DefaultsValue.values(fromPlist: Data(contentsOf: url))
        #expect(saved["AppleShowAllFiles"] == .bool(false))
    }

    @Test func keepsTheCopyFromBeforeTheFirstChange() async throws {
        let browser = controller()
        await browser.open(finder)
        await browser.set(.bool(true), for: "AppleShowAllFiles")
        await browser.set(.string("icnv"), for: "FXPreferredViewStyle")
        let url = try #require(browser.backupURL(for: finder))
        let saved = try DefaultsValue.values(fromPlist: Data(contentsOf: url))
        #expect(saved == ["AppleShowAllFiles": .bool(false), "FXPreferredViewStyle": .string("Nlsv")])
        // Found again after a relaunch.
        #expect(controller().hasBackup(finder))
    }

    @Test func restoresTheOriginal() async {
        let browser = controller()
        await browser.open(finder)
        await browser.set(.bool(true), for: "AppleShowAllFiles")
        await browser.delete("FXPreferredViewStyle")
        await browser.add("NewKey", text: "5", as: .integer)
        #expect(browser.values == ["AppleShowAllFiles": .bool(true), "NewKey": .integer(5)])

        await browser.restoreBackup()
        #expect(browser.values == ["AppleShowAllFiles": .bool(false), "FXPreferredViewStyle": .string("Nlsv")])
        #expect(browser.hasBackup(finder))
    }

    @Test func deletesAKey() async {
        let browser = controller()
        await browser.open(editor)
        await browser.delete("fontSize")
        #expect(browser.values.isEmpty)
        #expect(store.writes.last?.changes == [DefaultsChange(key: "fontSize", value: nil)])
    }

    @Test func addsOnlyNewKeysWithValidValues() async {
        let browser = controller()
        await browser.open(editor)
        #expect(await browser.add(" tabWidth ", text: "4", as: .integer))
        #expect(browser.values["tabWidth"] == .integer(4))

        #expect(!(await browser.add("fontSize", text: "14", as: .integer)))
        #expect(browser.values["fontSize"] == .integer(12))
        #expect(browser.error != nil)

        #expect(!(await browser.add("ratio", text: "wide", as: .real)))
        #expect(browser.values["ratio"] == nil)
        #expect(!(await browser.add("  ", text: "1", as: .integer)))
    }

    @Test func showsWhyAChangeFailed() async {
        let browser = controller()
        await browser.open(editor)
        store.fails = true
        await browser.set(.integer(20), for: "fontSize")
        #expect(browser.error?.contains("Couldn't change Editor") == true)
        #expect(browser.values["fontSize"] == .integer(12))

        store.fails = false
        await browser.set(.integer(20), for: "fontSize")
        #expect(browser.error == nil)
    }

    @Test func picksUpChangesMadeElsewhere() async {
        let browser = controller()
        await browser.open(editor)
        store.values["com.example.editor"]?["fontSize"] = .integer(16)
        await browser.reload()
        #expect(browser.values["fontSize"] == .integer(16))
    }

    @Test func worksWithoutBackups() async {
        let browser = DefaultsBrowserController(store: store, backupDirectory: nil)
        await browser.open(editor)
        await browser.set(.integer(13), for: "fontSize")
        #expect(browser.values["fontSize"] == .integer(13))
        #expect(!browser.hasBackup(editor))
        #expect(browser.backupURL(for: editor) == nil)
    }
}

final class FakeDefaultsStore: DefaultsStoring, @unchecked Sendable {
    var domains: [DefaultsDomain] = []
    var values: [String: [String: DefaultsValue]] = [:]
    var fails = false
    /// How long each read and write takes, to overlap changes.
    var delay: Duration?
    private(set) var writes: [(domain: String, changes: [DefaultsChange])] = []
    /// The most reads and writes that were running at once.
    private(set) var mostAtOnce = 0
    private var running = 0

    private func pause() async {
        guard let delay else { return }
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        try? await Task.sleep(for: delay)
        running -= 1
    }

    func domains() async -> [DefaultsDomain] { domains }

    func keys(in domains: [String]) async -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: domains.map { ($0, Array(values[$0, default: [:]].keys)) })
    }

    func values(in domain: String) async -> [String: DefaultsValue] {
        await pause()
        return values[domain, default: [:]]
    }

    func write(_ changes: [DefaultsChange], in domain: String) async throws {
        await pause()
        if fails { throw CommandError(errorDescription: "Not allowed.") }
        writes.append((domain, changes))
        for change in changes {
            values[domain, default: [:]][change.key] = change.value
        }
    }
}

struct DefaultsTweakCatalogTests {
    @Test func everyTweakIsDistinct() {
        #expect(Set(DefaultsTweak.all.map(\.id)).count == DefaultsTweak.all.count)
        #expect(Set(DefaultsTweak.all.map(\.title)).count == DefaultsTweak.all.count)
    }

    @Test func everyGroupHasTweaks() {
        for group in DefaultsTweak.Group.allCases {
            #expect(!DefaultsTweak.tweaks(in: group).isEmpty, "\(group)")
        }
    }

    @Test func everyChoiceHasOneDefault() {
        for tweak in DefaultsTweak.all {
            guard case .choice(let choices) = tweak.control else { continue }
            #expect(choices.count(where: { $0.value == nil }) == 1, "\(tweak.key)")
            #expect(Set(choices.map(\.value)).count == choices.count, "\(tweak.key)")
        }
    }

    @Test func onlyTheDockAndFinderAreRestarted() {
        for tweak in DefaultsTweak.all where tweak.restart.processName != nil {
            #expect(tweak.domain == tweak.restart.rawValue, "\(tweak.key)")
        }
    }

    @Test func readsTheStoredValue() throws {
        let delay = try #require(DefaultsTweak.all.first { $0.key == "autohide-delay" })
        #expect(delay.isOn(.real(0)))
        #expect(!delay.isOn(nil))
        #expect(!delay.isOn(.real(0.5)))

        let format = try #require(DefaultsTweak.all.first { $0.key == "type" })
        #expect(format.choice(for: nil)?.title == "PNG")
        #expect(format.choice(for: .string("jpg"))?.title == "JPEG")
        #expect(format.choice(for: .string("gif")) == nil)
        #expect(!format.isOn(.string("jpg")))
    }
}

@MainActor
struct DefaultsTweakControllerTests {
    private let store = FakeDefaultsStore()
    private let backups = FileManager.default.temporaryDirectory.appending(path: "PowerToysTests-\(UUID().uuidString)")
    private let quit = QuitRecorder()

    private func controller() -> DefaultsBrowserController {
        DefaultsBrowserController(store: store, backupDirectory: backups, quitProcesses: { [quit] in quit.ids.append($0) })
    }

    private func tweak(_ key: String) throws -> DefaultsTweak {
        try #require(DefaultsTweak.all.first { $0.key == key })
    }

    @Test func loadsEveryTweaksDomain() async {
        store.values = ["com.apple.dock": ["showhidden": .bool(true)]]
        let browser = controller()
        await browser.loadTweaks()
        #expect(Set(browser.tweakValues.keys) == Set(DefaultsTweak.all.map(\.domain)))
        #expect(browser.storedValue(of: try! tweak("showhidden")) == .bool(true))
    }

    @Test func switchingOnWritesAndOffGoesBackToTheDefault() async throws {
        let browser = controller()
        await browser.loadTweaks()
        let delay = try tweak("autohide-delay")
        await browser.apply(delay, .real(0))
        #expect(store.values["com.apple.dock"]?["autohide-delay"] == .real(0))
        #expect(browser.storedValue(of: delay) == .real(0))

        await browser.apply(delay, nil)
        #expect(store.values["com.apple.dock"]?["autohide-delay"] == nil)
        #expect(browser.storedValue(of: delay) == nil)
    }

    @Test func savesTheDomainBeforeTheFirstChange() async throws {
        store.values = ["com.apple.dock": ["tilesize": .integer(48)]]
        let browser = controller()
        await browser.loadTweaks()
        await browser.apply(try tweak("static-only"), .bool(true))
        let dock = DefaultsDomain(id: "com.apple.dock")
        #expect(browser.hasBackup(dock))
        let saved = try DefaultsValue.values(fromPlist: Data(contentsOf: try #require(browser.backupURL(for: dock))))
        #expect(saved == ["tilesize": .integer(48)])
    }

    @Test func asksForARestartOnlyWhereOneIsNeeded() async throws {
        let browser = controller()
        await browser.loadTweaks()
        await browser.apply(try tweak("disable-shadow"), .bool(true))
        #expect(browser.pendingRestarts.isEmpty)

        await browser.apply(try tweak("showhidden"), .bool(true))
        await browser.apply(try tweak("QuitMenuItem"), .bool(true))
        #expect(browser.pendingRestarts == [.dock, .finder])

        browser.restart(.dock)
        #expect(quit.ids == ["com.apple.dock"])
        #expect(browser.pendingRestarts == [.finder])
        browser.restart(.apps)
        #expect(quit.ids == ["com.apple.dock"])
    }

    @Test func unchangedValuesAreNotWritten() async throws {
        let browser = controller()
        await browser.loadTweaks()
        await browser.apply(try tweak("type"), nil)
        #expect(store.writes.isEmpty)
        #expect(browser.pendingRestarts.isEmpty)
    }

    @Test func aFailedChangeIsShown() async throws {
        let browser = controller()
        await browser.loadTweaks()
        store.fails = true
        await browser.apply(try tweak("showhidden"), .bool(true))
        #expect(browser.error != nil)
        #expect(browser.pendingRestarts.isEmpty)
        #expect(browser.storedValue(of: try tweak("showhidden")) == nil)
    }

    @Test func restoringADomainUpdatesItsTweaks() async throws {
        let browser = controller()
        await browser.loadTweaks()
        let hidden = try tweak("showhidden")
        await browser.apply(hidden, .bool(true))
        browser.restart(.dock)

        await browser.open(DefaultsDomain(id: "com.apple.dock"))
        await browser.restoreBackup()
        #expect(browser.storedValue(of: hidden) == nil)
        #expect(browser.pendingRestarts == [.dock])
    }
}

final class QuitRecorder: @unchecked Sendable {
    var ids: [String] = []
}

@MainActor
struct DefaultsReviewFixTests {
    private let store = FakeDefaultsStore()
    private let backups = FileManager.default.temporaryDirectory.appending(path: "PowerToysTests-\(UUID().uuidString)")
    private let domain = DefaultsDomain(id: "com.example.app", appName: "App")

    private func controller() -> DefaultsBrowserController {
        DefaultsBrowserController(store: store, backupDirectory: backups, quitProcesses: { _ in })
    }

    @Test func quickChangesKeepTheOriginalAndBothShow() async throws {
        store.values = [domain.id: ["a": .bool(false), "b": .bool(false)]]
        let browser = controller()
        await browser.open(domain)
        store.delay = .milliseconds(20)
        async let first: Void = browser.set(.bool(true), for: "a")
        async let second: Void = browser.set(.bool(true), for: "b")
        _ = await (first, second)
        #expect(store.mostAtOnce == 1)

        let saved = try DefaultsValue.values(fromPlist: Data(contentsOf: try #require(browser.backupURL(for: domain))))
        #expect(saved == ["a": .bool(false), "b": .bool(false)])
        #expect(browser.values == ["a": .bool(true), "b": .bool(true)])
    }

    @Test func restoreLeavesUntouchedDatesAlone() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.734)
        store.values = [domain.id: ["checked": .date(date), "flag": .bool(false)]]
        let browser = controller()
        await browser.open(domain)
        await browser.set(.bool(true), for: "flag")
        await browser.restoreBackup()
        #expect(store.writes.last?.changes == [DefaultsChange(key: "flag", value: .bool(false))])
        #expect(browser.values["checked"] == .date(date))
    }

    @Test func putsBackChangesAnAppSavedOver() async {
        store.values = [domain.id: ["size": .integer(1), "other": .integer(1)]]
        let browser = controller()
        await browser.open(domain)
        await browser.set(.integer(2), for: "size")
        await browser.delete("other")
        // The app quits, saving what it had in memory.
        store.values[domain.id] = ["size": .integer(1), "other": .integer(1), "new": .bool(true)]

        await browser.reapplyEdits(in: domain.id)
        #expect(store.values[domain.id] == ["size": .integer(2), "new": .bool(true)])
        #expect(store.writes.last?.changes == [DefaultsChange(key: "other", value: nil), DefaultsChange(key: "size", value: .integer(2))])
    }

    @Test func doesNothingWhenNoChangeWasLost() async {
        store.values = [domain.id: ["size": .integer(1)]]
        let browser = controller()
        await browser.open(domain)
        await browser.set(.integer(2), for: "size")
        let writes = store.writes.count
        await browser.reapplyEdits(in: domain.id)
        #expect(store.writes.count == writes)
    }

    @Test func changesShowInTheListAndKeySearch() async {
        store.domains = [domain]
        store.values = [domain.id: ["size": .integer(1)]]
        let browser = controller()
        await browser.loadDomains()
        #expect(browser.domains(matching: "fresh").isEmpty)

        await browser.open(domain)
        await browser.add("freshKey", text: "1", as: .integer)
        #expect(browser.domains(matching: "fresh").map(\.id) == [domain.id])
        #expect(browser.matchingKeys(in: domain, "FRESH") == ["freshKey"])

        let typed = browser.domain(named: "com.example.new")
        await browser.open(typed)
        await browser.add("x", text: "1", as: .integer)
        #expect(browser.domains.contains { $0.id == "com.example.new" })
    }

    @Test func unsignedIntegersKeepTheirValue() throws {
        let max = UInt64.max
        #expect(DefaultsValue(plist: NSNumber(value: max)) == .unsigned(max))
        #expect(DefaultsValue(plist: NSNumber(value: Int.max)) == .integer(Int.max))
        #expect(DefaultsValue.unsigned(max).summary == "18446744073709551615")
        #expect(DefaultsValue.unsigned(max).kind == .integer)
        #expect(DefaultsValue.parse("18446744073709551615", as: .integer) == .unsigned(max))
        #expect(DefaultsValue.writeCommand(domain: "x", key: "k", value: .unsigned(max))
            == "defaults write x k '<integer>18446744073709551615</integer>'")
        #expect(try DefaultsValue.values(fromPlist: DefaultsValue.plistData(["k": .unsigned(max)])) == ["k": .unsigned(max)])
    }

    @Test func backupsKeepDatesExactly() throws {
        let values: [String: DefaultsValue] = ["when": .date(Date(timeIntervalSince1970: 1_800_000_000.734))]
        #expect(try DefaultsValue.values(fromPlist: DefaultsValue.plistData(values)) == values)
    }

    @Test func copiesConcealedText() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.copy("secret", concealed: true)
        #expect(pasteboard.string(forType: .string) == "secret")
        #expect(pasteboard.types?.contains(ClipboardController.concealedType) == true)
        pasteboard.copy("plain")
        #expect(pasteboard.types?.contains(ClipboardController.concealedType) == false)
    }
}
