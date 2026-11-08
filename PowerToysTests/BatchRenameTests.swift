import Foundation
import Testing

@testable import PowerToys

/// Answers for Finder's selection and folder without scripting Finder.
struct FakeFinder: FinderAccess {
    var selected: [URL] = []
    var folder = URL(filePath: "/tmp/", directoryHint: .isDirectory)
    var failure: CommandError?

    func selection() async throws -> [URL] {
        if let failure { throw failure }
        return selected
    }

    func currentFolder() async throws -> URL {
        if let failure { throw failure }
        return folder
    }
}

/// An empty folder for one test, removed afterwards.
final class TemporaryFolder {
    let url = URL.temporaryDirectory.appending(path: "PowerToysTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Makes empty files and returns their URLs.
    @discardableResult
    func make(_ names: String...) -> [URL] {
        names.map { name in
            let file = url.appending(path: name)
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data(name.utf8))
            return file
        }
    }

    var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []).sorted()
    }
}

struct RenameRuleTests {
    private func rename(_ name: String, _ rule: RenameRule, index: Int = 0, date: Date? = nil) throws -> String {
        rule.newName(for: name, index: index, date: date, regex: try rule.regex())
    }

    @Test func findsTextIgnoringCaseUnlessAsked() throws {
        var rule = RenameRule(find: "img", replace: "Photo")
        #expect(try rename("IMG_001.jpg", rule) == "Photo_001.jpg")
        rule.matchesCase = true
        #expect(try rename("IMG_001.jpg", rule) == "IMG_001.jpg")
    }

    @Test func leavesTheExtensionAloneUnlessIncluded() throws {
        var rule = RenameRule(find: "jpg", replace: "png")
        #expect(try rename("jpg-notes.jpg", rule) == "png-notes.jpg")
        rule.includesExtension = true
        #expect(try rename("jpg-notes.jpg", rule) == "png-notes.png")
    }

    @Test func regexGroupsAndNumbering() throws {
        let rule = RenameRule(find: #"IMG_(\d+)"#, replace: "Trip {n} ($1)", usesRegex: true, counterStart: 7, counterDigits: 3)
        #expect(try rename("IMG_4412.HEIC", rule, index: 2) == "Trip 009 (4412).HEIC")
    }

    @Test func tokenValuesArentReadAsRegexGroups() throws {
        // A "$1" in the old name stays literal when {name} goes into a regex replacement.
        let rule = RenameRule(find: "^", replace: "{name}-", usesRegex: true)
        #expect(try rename("price $1.txt", rule) == "price $1-price $1.txt")
    }

    @Test func emptyFindReplacesTheWholeName() throws {
        let rule = RenameRule(replace: "{date} {n} {name}")
        let date = try #require(BatchRenameController.parseExifDate("2024:07:14 18:30:05"))
        #expect(try rename("beach.jpg", rule, index: 0, date: date) == "2024-07-14 1 beach.jpg")
        // Nothing to find or replace keeps the name.
        #expect(try rename("beach.jpg", RenameRule()) == "beach.jpg")
    }

    @Test func changesCase() throws {
        #expect(try rename("My Photo.JPG", RenameRule(textCase: .lowercase)) == "my photo.JPG")
        #expect(try rename("my photo.jpg", RenameRule(textCase: .uppercase)) == "MY PHOTO.jpg")
        #expect(try rename("my photo.jpg", RenameRule(textCase: .titleCase)) == "My Photo.jpg")
    }

    @Test func splitsExtensions() {
        #expect(RenameRule.split("a.tar.gz") == ("a.tar", "gz"))
        #expect(RenameRule.split(".zshrc") == (".zshrc", ""))
        #expect(RenameRule.split(".env.local") == (".env", "local"))
        #expect(RenameRule.split("README") == ("README", ""))
        #expect(RenameRule.split("trailing.") == ("trailing.", ""))
    }

    @Test func badPatternsAreReported() {
        let rule = RenameRule(find: "(unclosed", usesRegex: true)
        #expect(throws: CommandError.self) { try rule.regex() }
    }

    @Test func readsExifDates() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(BatchRenameController.parseExifDate("2024:02:29 23:59:00", timeZone: utc))
        #expect(RenameRule.format(date, timeZone: utc) == "2024-02-29")
        #expect(BatchRenameController.parseExifDate("2024:02:30 10:00:00") == nil)
        #expect(BatchRenameController.parseExifDate("not a date") == nil)
    }
}

struct RenamePlanTests {
    private let folder = URL(filePath: "/photos/", directoryHint: .isDirectory)

    private func plan(_ names: [String], _ rule: RenameRule, onDisk: Set<String> = []) throws -> [RenamePreview] {
        let urls = names.map { folder.appending(path: $0) }
        return try RenamePreview.plan(urls, rule: rule, date: { _ in nil }, exists: { onDisk.contains($0.lastPathComponent) })
    }

    @Test func flagsTwoFilesGettingOneName() throws {
        let previews = try plan(["a1.txt", "a2.txt", "keep.txt"], RenameRule(find: #"\d"#, replace: "", usesRegex: true))
        #expect(previews.map(\.problem) == [.duplicate, .duplicate, nil])
    }

    @Test func flagsANameAlreadyTakenOnDisk() throws {
        let previews = try plan(["a.txt"], RenameRule(find: "a", replace: "b"), onDisk: ["b.txt"])
        #expect(previews[0].problem == .exists)
    }

    @Test func filesInTheListCanSwapNamesOrChangeCase() throws {
        // a→b and b→a: both names are free once the files move.
        let swap = try plan(["a.txt", "b.txt"], RenameRule(find: "^(a|b)$", replace: "{n}", usesRegex: true))
        #expect(swap.allSatisfy { $0.problem == nil })
        let caseOnly = try plan(["photo.jpg"], RenameRule(textCase: .uppercase), onDisk: ["PHOTO.jpg", "photo.jpg"])
        #expect(caseOnly[0].problem == nil)
        #expect(caseOnly[0].isChanged)
    }

    @Test func flagsNamesThatCantBeUsed() throws {
        #expect(try plan(["a.txt"], RenameRule(find: "a", replace: ""))[0].problem == .empty)
        #expect(try plan(["a.txt"], RenameRule(find: "a", replace: "x/y"))[0].problem == .invalidCharacter)
        #expect(try plan(["a.txt"], RenameRule(find: "a", replace: String(repeating: "x", count: 300)))[0].problem == .tooLong)
    }

    @Test func foldersCanSwapNamesOrChangeCase() throws {
        // Folders from Finder end in "/", which their destinations don't.
        let urls = ["1", "2"].map { folder.appending(path: $0, directoryHint: .isDirectory) }
        let onDisk = { (url: URL) in ["1", "2"].contains(url.lastPathComponent) }
        // 1→2 takes the name 2 is leaving.
        let shift = try RenamePreview.plan(
            urls, rule: RenameRule(find: #"^\d$"#, replace: "{n}", usesRegex: true, counterStart: 2), date: { _ in nil },
            exists: onDisk)
        #expect(shift.map(\.newName) == ["2", "3"])
        #expect(shift.allSatisfy { $0.problem == nil })
        let caseOnly = try RenamePreview.plan(
            [folder.appending(path: "album", directoryHint: .isDirectory)], rule: RenameRule(textCase: .uppercase),
            date: { _ in nil }, exists: { _ in true })
        #expect(caseOnly[0].problem == nil)
    }

    @Test func flagsItemsInsideARenamedFolder() throws {
        let album = folder.appending(path: "album", directoryHint: .isDirectory)
        let urls = [album, album.appending(path: "a.jpg"), folder.appending(path: "other.jpg")]
        let previews = try RenamePreview.plan(
            urls, rule: RenameRule(textCase: .uppercase), date: { _ in nil }, exists: { _ in false })
        #expect(previews.map(\.problem) == [nil, .insideRenamedFolder, nil])
    }

    @Test func unchangedNamesArentFlagged() throws {
        let previews = try plan(["a.txt", "b.txt"], RenameRule(find: "zzz", replace: "y"), onDisk: ["a.txt", "b.txt"])
        #expect(previews.allSatisfy { !$0.isChanged && $0.problem == nil })
    }
}

struct FileRenamerTests {
    @Test func swapsNames() throws {
        let folder = TemporaryFolder()
        let files = folder.make("a.txt", "b.txt")
        try FileRenamer.rename([.init(from: files[0], to: files[1]), .init(from: files[1], to: files[0])])
        let a = try String(contentsOf: files[0], encoding: .utf8)
        #expect(a == "b.txt")
        #expect(folder.names == ["a.txt", "b.txt"])
    }

    @Test func changesOnlyTheCase() throws {
        let folder = TemporaryFolder()
        let files = folder.make("photo.jpg")
        try FileRenamer.rename([.init(from: files[0], to: folder.url.appending(path: "PHOTO.jpg"))])
        #expect(folder.names == ["PHOTO.jpg"])
    }

    @Test func undoesEverythingWhenOneFails() throws {
        let folder = TemporaryFolder()
        let files = folder.make("a.txt", "b.txt", "taken.txt")
        let moves: [FileRenamer.Move] = [
            .init(from: files[0], to: folder.url.appending(path: "new.txt")),
            // Appeared since the preview; moveItem won't replace it.
            .init(from: files[1], to: files[2]),
        ]
        #expect(throws: (any Error).self) { try FileRenamer.rename(moves) }
        #expect(folder.names == ["a.txt", "b.txt", "taken.txt"])
        #expect(try String(contentsOf: files[2], encoding: .utf8) == "taken.txt")
    }
}

struct BatchRenameControllerTests {
    private let store = TestDefaults()

    @Test func addsFilesOnceSortedByName() {
        let folder = TemporaryFolder()
        let files = folder.make("b10.txt", "b2.txt", "a.txt")
        let controller = BatchRenameController(defaults: store.defaults, finder: FakeFinder())
        controller.add(files)
        controller.add([files[0], folder.url.appending(path: "missing.txt")])
        #expect(controller.items.map(\.lastPathComponent) == ["a.txt", "b2.txt", "b10.txt"])
    }

    @Test func renamesAndUndoes() throws {
        let folder = TemporaryFolder()
        let files = folder.make("IMG_1.jpg", "IMG_2.jpg")
        let controller = BatchRenameController(defaults: store.defaults, finder: FakeFinder())
        controller.add(files)
        controller.rule = RenameRule(find: "IMG_", replace: "Trip ")
        controller.apply()
        #expect(folder.names == ["Trip 1.jpg", "Trip 2.jpg"])
        #expect(controller.items.map(\.lastPathComponent) == ["Trip 1.jpg", "Trip 2.jpg"])
        #expect(controller.message == "Renamed 2 files.")
        #expect(!controller.isError)

        controller.undo()
        #expect(folder.names == ["IMG_1.jpg", "IMG_2.jpg"])
        #expect(controller.items.map(\.lastPathComponent) == ["IMG_1.jpg", "IMG_2.jpg"])
        #expect(controller.lastRename.isEmpty)
    }

    @Test func renamesNothingWhileANameIsMarked() {
        let folder = TemporaryFolder()
        let files = folder.make("a1.txt", "a2.txt")
        let controller = BatchRenameController(defaults: store.defaults, finder: FakeFinder())
        controller.add(files)
        controller.rule = RenameRule(find: #"\d"#, replace: "", usesRegex: true)
        controller.apply()
        #expect(folder.names == ["a1.txt", "a2.txt"])
        #expect(controller.isError)
    }

    @Test func renamesFolders() throws {
        let folder = TemporaryFolder()
        let album = folder.url.appending(path: "album", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: false)
        let controller = BatchRenameController(defaults: store.defaults, finder: FakeFinder())
        controller.add([album])
        controller.rule = RenameRule(textCase: .titleCase)
        controller.apply()
        #expect(folder.names == ["Album"])
        #expect(!controller.isError)
    }

    @Test func checksTheDiskAgainBeforeRenaming() {
        let folder = TemporaryFolder()
        let files = folder.make("a.txt")
        let controller = BatchRenameController(defaults: store.defaults, finder: FakeFinder())
        controller.add(files)
        controller.rule = RenameRule(find: "a", replace: "b")
        // Made after the list was last shown.
        folder.make("b.txt")
        controller.apply()
        #expect(controller.isError)
        #expect(folder.names == ["a.txt", "b.txt"])
    }

    @Test func addsFinderSelectionOrSaysWhy() async {
        let folder = TemporaryFolder()
        let files = folder.make("x.txt")
        let controller = BatchRenameController(defaults: store.defaults, finder: FakeFinder(selected: files))
        await controller.addFinderSelection()
        #expect(controller.items == files.map(\.standardizedFileURL))

        let empty = BatchRenameController(defaults: store.defaults, finder: FakeFinder())
        await empty.addFinderSelection()
        #expect(empty.message == "Nothing is selected in Finder.")

        let denied = BatchRenameController(
            defaults: store.defaults, finder: FakeFinder(failure: CommandError(errorDescription: "Not allowed")))
        await denied.addFinderSelection()
        #expect(denied.message == "Not allowed")
    }

    @Test func remembersTheRule() {
        let first = BatchRenameController(defaults: store.defaults, finder: FakeFinder())
        first.rule = RenameRule(find: "a", replace: "b", usesRegex: true, counterDigits: 3)
        let second = BatchRenameController(defaults: store.defaults, finder: FakeFinder())
        #expect(second.rule == first.rule)
    }

    @Test func reportsBadPatterns() {
        let controller = BatchRenameController(defaults: store.defaults, finder: FakeFinder())
        controller.rule = RenameRule(find: "[", usesRegex: true)
        guard case .failure = controller.preview else {
            Issue.record("A bad pattern should fail the preview")
            return
        }
    }
}
