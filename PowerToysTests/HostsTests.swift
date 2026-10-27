import Foundation
import Testing
@testable import PowerToys

private let stock = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost

    """

struct HostEntryTests {
    @Test func readsEntriesAndCommentedOutEntries() throws {
        let entry = try #require(HostEntry(line: "10.0.0.5   api.test www.api.test  # staging box"))
        #expect(entry.address == "10.0.0.5")
        #expect(entry.hostnames == ["api.test", "www.api.test"])
        #expect(entry.comment == "staging box")
        #expect(entry.isEnabled)

        let off = try #require(HostEntry(line: "#127.0.0.1 myapp.test"))
        #expect(!off.isEnabled)
        #expect(off.hostnames == ["myapp.test"])
        #expect(HostEntry(line: "## ::1 v6.test")?.isEnabled == false)
        #expect(HostEntry(line: "fe80::1%lo0 localhost")?.isSystem == true)
    }

    @Test func proseAndJunkArentEntries() {
        #expect(HostEntry(line: "# localhost is used to configure the loopback interface") == nil)
        #expect(HostEntry(line: "# 127.0.0.1 is where it's at!") == nil)
        #expect(HostEntry(line: "# 10.0.0.1 is the router") == nil)
        // Single-word names count when PowerToys wrote the line.
        #expect(HostEntry(line: "# 10.0.0.1\tnas")?.hostnames == ["nas"])
        #expect(HostEntry(line: "10.0.0.1 nas")?.isEnabled == true)
        #expect(HostEntry(line: "##") == nil)
        #expect(HostEntry(line: "") == nil)
        #expect(HostEntry(line: "999.1.1.1 nope.test") == nil)
        #expect(HostEntry(line: "127.0.0.1") == nil)
    }

    @Test func writesChangedEntriesNeatly() {
        var entry = HostEntry(line: "127.0.0.1    a.test   # note")!
        #expect(entry.line == "127.0.0.1    a.test   # note")
        entry.source = nil
        #expect(entry.line == "127.0.0.1\ta.test # note")
        entry.isEnabled = false
        #expect(entry.line == "# 127.0.0.1\ta.test # note")
    }

    @Test func validation() {
        #expect(HostEntry.isValidAddress("192.168.1.10"))
        #expect(HostEntry.isValidAddress("::1"))
        #expect(HostEntry.isValidAddress("fe80::1%lo0"))
        #expect(!HostEntry.isValidAddress("localhost"))
        #expect(!HostEntry.isValidAddress("1.2.3"))

        #expect(HostEntry.isValidHostname("my-app_1.test"))
        #expect(!HostEntry.isValidHostname("-bad.test"))
        #expect(!HostEntry.isValidHostname("a..b"))
        #expect(!HostEntry.isValidHostname("*.test"))
        #expect(!HostEntry.isValidHostname("café.test"))

        #expect(HostEntry.hostnames(from: " a.test, b.test  c.test ") == ["a.test", "b.test", "c.test"])
        #expect(HostEntry.problem(address: "127.0.0.1", hostnames: ["a.test"]) == nil)
        #expect(HostEntry.problem(address: "", hostnames: ["a.test"]) != nil)
        #expect(HostEntry.problem(address: "nope", hostnames: ["a.test"]) != nil)
        #expect(HostEntry.problem(address: "127.0.0.1", hostnames: []) != nil)
        #expect(HostEntry.problem(address: "127.0.0.1", hostnames: ["bad name!"]) != nil)
        #expect(HostEntry.problem(address: "127.0.0.1", hostnames: ["localhost"]) != nil)
    }
}

struct HostsFileTests {
    @Test func untouchedFilesSaveExactlyAsRead() {
        let text = stock + "10.0.0.1   x.test    # keep my spacing\n#10.0.0.2 y.test\n"
        #expect(HostsFile(text: text).text == text)
    }

    @Test func builtInEntriesAreKeptApart() {
        let file = HostsFile(text: stock)
        #expect(file.systemEntries.count == 3)
        #expect(file.sections.map(\.name) == [nil])
        #expect(file.sections[0].entries.isEmpty)
    }

    @Test func addsUngroupedEntriesAfterTheLastOne() {
        var file = HostsFile(text: stock)
        file.add(HostEntry(address: "127.0.0.1", hostnames: ["a.test"]))
        file.add(HostEntry(address: "127.0.0.1", hostnames: ["b.test"]))
        #expect(file.text == stock.replacing("::1             localhost\n", with: "::1             localhost\n127.0.0.1\ta.test\n127.0.0.1\tb.test\n"))
        #expect(file.sections[0].entries.map(\.hostnames) == [["a.test"], ["b.test"]])
    }

    @Test func groups() {
        var file = HostsFile(text: stock)
        file.addGroup("Staging")
        file.add(HostEntry(address: "10.0.0.5", hostnames: ["api.test"]), to: "Staging")
        file.add(HostEntry(address: "10.0.0.6", hostnames: ["web.test"]), to: "Staging")
        file.add(HostEntry(address: "127.0.0.1", hostnames: ["local.test"]))

        #expect(file.text.hasSuffix("""
            ::1             localhost
            127.0.0.1\tlocal.test

            # >>> PowerToys: Staging
            10.0.0.5\tapi.test
            10.0.0.6\tweb.test
            # <<< PowerToys

            """))
        #expect(file.groups == ["Staging"])
        #expect(file.sections.map(\.name) == [nil, "Staging"])
        #expect(file.sections[1].entries.count == 2)

        // Reads back the same.
        let reread = HostsFile(text: file.text)
        #expect(reread.groups == ["Staging"])
        #expect(reread.sections[1].entries.map(\.hostnames) == [["api.test"], ["web.test"]])

        file.setEnabled(group: "Staging", false)
        #expect(file.sections[1].entries.allSatisfy { !$0.isEnabled })
        #expect(file.text.contains("# 10.0.0.5\tapi.test"))
        #expect(file.sections[0].entries[0].isEnabled)

        file.renameGroup("Staging", to: "Stage")
        #expect(file.groups == ["Stage"])

        file.removeGroup("Stage")
        #expect(file.groups.isEmpty)
        #expect(file.text == stock + "127.0.0.1\tlocal.test\n")
    }

    @Test func movesEntriesBetweenGroups() throws {
        var file = HostsFile(text: stock)
        file.addGroup("A")
        file.addGroup("B")
        let entry = HostEntry(address: "127.0.0.1", hostnames: ["m.test"])
        file.add(entry, to: "A")
        #expect(file.group(of: entry.id) == "A")
        file.move(entry.id, to: "B")
        #expect(file.group(of: entry.id) == "B")
        file.move(entry.id, to: nil)
        #expect(file.group(of: entry.id) == nil)
        #expect(file.sections.map(\.entries.count) == [1, 0, 0])
    }

    @Test func editsAndRemoves() throws {
        var file = HostsFile(text: stock + "10.0.0.1 x.test\n")
        var entry = try #require(file.sections[0].entries.first)
        file.setEnabled(entry.id, false)
        #expect(file.entry(entry.id)?.isEnabled == false)

        entry.hostnames = ["y.test"]
        file.update(entry)
        #expect(file.text.hasSuffix("10.0.0.1\ty.test\n"))

        file.remove(entry.id)
        #expect(file.text == stock)
    }

    @Test func noOpEditsLeaveTheFileEqual() throws {
        var file = HostsFile(text: stock + "10.0.0.1 x.test\n")
        let before = file
        let entry = try #require(file.sections[0].entries.first)
        file.setEnabled(entry.id, true)
        file.move(entry.id, to: nil)
        #expect(file == before)
    }

    @Test func findsEntriesAnEarlierLineOverrides() throws {
        let file = HostsFile(text: """
            127.0.0.1 a.test b.test
            10.0.0.1 b.test c.test
            ::1 a.test
            # 10.0.0.2 c.test
            10.0.0.3 c.test

            """)
        let entries = file.entries
        #expect(file.shadowedHostnames(of: entries[0]).isEmpty)
        #expect(file.shadowedHostnames(of: entries[1]) == ["b.test"])
        // IPv6 lookups are separate.
        #expect(file.shadowedHostnames(of: entries[2]).isEmpty)
        // Switched off: no effect either way.
        #expect(file.shadowedHostnames(of: entries[3]).isEmpty)
        #expect(file.shadowedHostnames(of: entries[4]) == ["c.test"])
    }

    @Test func groupNames() {
        #expect(HostsFile.problem(groupName: "Staging", existing: []) == nil)
        #expect(HostsFile.problem(groupName: "  ", existing: []) != nil)
        #expect(HostsFile.problem(groupName: "staging", existing: ["Staging"]) != nil)
        #expect(HostsFile.problem(groupName: "a\nb", existing: []) != nil)
    }

    @Test func linesSharedWithLocalhostAreBuiltIn() {
        let file = HostsFile(text: stock + "127.0.0.1 localhost myapp.test\n")
        #expect(file.systemEntries.count == 4)
        #expect(file.sections[0].entries.isEmpty)
    }

    @Test func groupsWithoutAnEndStopAtTheNextGroup() {
        let text = stock + """

            # >>> PowerToys: A
            10.0.0.1 a.test
            # >>> PowerToys: B
            10.0.0.2 b.test
            # <<< PowerToys

            """
        var file = HostsFile(text: text)
        #expect(file.sections.map(\.entries.count) == [0, 1, 1])

        let entry = HostEntry(address: "10.0.0.3", hostnames: ["new.test"])
        file.add(entry, to: "A")
        #expect(file.group(of: entry.id) == "A")
        #expect(HostsFile(text: file.text).sections.map(\.entries.count) == [0, 2, 1])

        file.removeGroup("A")
        #expect(file.groups == ["B"])
        #expect(file.sections.map(\.entries.count) == [0, 1])
    }

    @Test func aSecondGroupWithTheSameNameIsLeftAlone() {
        var file = HostsFile(text: stock + """
            # >>> PowerToys: Staging
            10.0.0.1 a.test
            # <<< PowerToys
            # >>> PowerToys: staging
            10.0.0.2 b.test
            # <<< PowerToys

            """)
        #expect(file.groups == ["Staging"])
        #expect(Set(file.sections.map(\.id)).count == file.sections.count)
        #expect(file.sections.map(\.entries.count) == [1, 1])
        file.removeGroup("Staging")
        #expect(file.entries.contains { $0.hostnames == ["b.test"] })
    }

    @Test func reloadingKeepsIDsOfUnchangedLines() {
        let before = HostsFile(text: stock + "10.0.0.1 a.test\n10.0.0.2 b.test\n10.0.0.1 a.test\n")
        let after = HostsFile(text: stock + "10.0.0.1 a.test\n10.0.0.9 b.test\n10.0.0.1 a.test\n", reusingIDsFrom: before)
        let old = before.sections[0].entries.map(\.id)
        let new = after.sections[0].entries.map(\.id)
        #expect(new[0] == old[0])
        #expect(new[1] != old[1])
        #expect(new[2] == old[2])
    }

    @Test func aGroupWithoutAnEndRunsToTheEnd() {
        let file = HostsFile(text: stock + "# >>> PowerToys: Open\n10.0.0.1 x.test\n")
        #expect(file.sections.map(\.name) == [nil, "Open"])
        #expect(file.sections[1].entries.count == 1)
    }
}

/// Keeps the hosts file in memory.
final class FakeHostsStore: HostsStore, @unchecked Sendable {
    var text: String
    var writes: [String] = []
    var flushes = 0
    var cancels = false
    var fails = false

    init(text: String = stock) {
        self.text = text
    }

    func read() throws -> String { text }

    /// Changes the file while the password prompt is up, so the write finds it changed.
    var changesDuringPrompt: String?

    func write(_ text: String, replacing expected: String) async throws {
        if cancels { throw CancellationError() }
        if fails { throw CommandError(errorDescription: "Nope") }
        if let changed = changesDuringPrompt {
            self.text = changed
            changesDuringPrompt = nil
        }
        guard self.text == expected else { throw HostsChangedError() }
        writes.append(text)
        self.text = text
    }

    func flushDNS() async throws {
        flushes += 1
    }
}

struct HostsControllerTests {
    private func makeController(_ store: FakeHostsStore, backup: URL? = nil) -> HostsController {
        let controller = HostsController(store: store, backupURL: backup)
        controller.reload()
        return controller
    }

    @Test func savesChanges() async {
        let store = FakeHostsStore()
        let controller = makeController(store)
        let saved = await controller.change { $0.add(HostEntry(address: "127.0.0.1", hostnames: ["a.test"])) }
        #expect(saved)
        #expect(store.writes.count == 1)
        #expect(store.text.contains("127.0.0.1\ta.test"))
        #expect(controller.file.sections[0].entries.count == 1)

        // Nothing changed, nothing written.
        #expect(await controller.change { _ in })
        #expect(store.writes.count == 1)
    }

    @Test func cancellingThePasswordPromptChangesNothing() async {
        let store = FakeHostsStore()
        store.cancels = true
        let controller = makeController(store)
        let saved = await controller.change { $0.addGroup("X") }
        #expect(!saved)
        #expect(controller.file.groups.isEmpty)
        #expect(controller.error == nil)
    }

    @Test func failuresAreShown() async {
        let store = FakeHostsStore()
        store.fails = true
        let controller = makeController(store)
        #expect(!(await controller.change { $0.addGroup("X") }))
        #expect(controller.file.groups.isEmpty)
        #expect(controller.error?.contains("Nope") == true)
    }

    @Test func doesntOverwriteChangesMadeElsewhere() async {
        let store = FakeHostsStore()
        let controller = makeController(store)
        store.text = stock + "10.0.0.9 other.test\n"
        let saved = await controller.change { $0.addGroup("X") }
        #expect(!saved)
        #expect(store.writes.isEmpty)
        #expect(controller.error != nil)
        // Reloaded, so trying again works.
        #expect(controller.file.sections[0].entries.count == 1)
        #expect(await controller.change { $0.addGroup("X") })
    }

    @Test func doesntOverwriteChangesMadeDuringThePasswordPrompt() async {
        let store = FakeHostsStore()
        let controller = makeController(store)
        store.changesDuringPrompt = stock + "10.0.0.9 vpn.test\n"
        #expect(!(await controller.change { $0.addGroup("X") }))
        #expect(store.text == stock + "10.0.0.9 vpn.test\n")
        #expect(controller.error != nil)
        #expect(!controller.isSaving)
        #expect(controller.file.sections[0].entries.count == 1)
    }

    @Test func entriesChangedElsewhereAreNoticed() throws {
        let store = FakeHostsStore(text: stock + "10.0.0.1 x.test\n10.0.0.2 y.test\n")
        let controller = makeController(store)
        let ids = controller.file.sections[0].entries.map(\.id)
        store.text = stock + "10.0.0.1 x.test\n10.0.0.3 y.test\n"
        controller.reload()
        #expect(controller.contains(ids[0]))
        #expect(!controller.contains(ids[1]))
    }

    @Test func reloadKeepsEntriesWhenNothingChanged() throws {
        let store = FakeHostsStore(text: stock + "10.0.0.1 x.test\n")
        let controller = makeController(store)
        let id = try #require(controller.file.sections[0].entries.first?.id)
        controller.reload()
        #expect(controller.file.sections[0].entries.first?.id == id)
    }

    @Test func keepsTheOriginalAndRestoresIt() async throws {
        let backup = FileManager.default.temporaryDirectory.appending(path: "hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backup) }
        let store = FakeHostsStore()
        let controller = makeController(store, backup: backup)
        #expect(!controller.hasBackup)

        await controller.change { $0.addGroup("One") }
        await controller.change { $0.addGroup("Two") }
        #expect(controller.hasBackup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == stock)

        #expect(await controller.restoreOriginal())
        #expect(store.text == stock)
        #expect(controller.file.groups.isEmpty)
    }

    @Test func flushesDNS() async {
        let store = FakeHostsStore()
        let controller = makeController(store)
        await controller.flushDNS()
        #expect(store.flushes == 1)
    }
}
