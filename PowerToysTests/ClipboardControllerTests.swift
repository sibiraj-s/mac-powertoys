import AppKit
import Testing
@testable import PowerToys

@MainActor
struct ClipboardControllerTests {
    private let store = TestDefaults()
    private let pasteboard = NSPasteboard.withUniqueName()
    private let directory = URL.temporaryDirectory.appending(path: "PowerToysTests-\(UUID().uuidString)")

    private func controller(persisted: Bool = false) -> ClipboardController {
        ClipboardController(defaults: store.defaults, storeDirectory: persisted ? directory : nil)
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func png(width: Int = 4, height: Int = 3, red: Double = 1) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.setColor(NSColor(deviceRed: red, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func defaults() {
        let clipboard = controller()
        #expect(clipboard.limit == 200)
        #expect(clipboard.skipsConcealed)
        #expect(clipboard.keepsImages)
        #expect(clipboard.recognizesText)
        #expect(!clipboard.isRunning)
        #expect(clipboard.history.items.isEmpty)
    }

    @Test func readsTextAndRichText() {
        copy("hi")
        pasteboard.setString("<b>hi</b>", forType: .html)
        let clipping = ClipboardController.read(pasteboard, skipsConcealed: true, keepsImages: true)
        #expect(clipping == .text("hi", .html("<b>hi</b>")))
    }

    @Test func textWinsOverAPictureOfIt() {
        copy("A1\tB1")
        pasteboard.setData(png(), forType: .png)
        #expect(ClipboardController.read(pasteboard, skipsConcealed: true, keepsImages: true) == .text("A1\tB1", nil))
    }

    @Test func readsImagesUnlessTurnedOff() throws {
        let data = png()
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        #expect(ClipboardController.read(pasteboard, skipsConcealed: true, keepsImages: true) == .image(png: data))
        #expect(ClipboardController.read(pasteboard, skipsConcealed: true, keepsImages: false) == nil)

        // TIFF-only images are converted to PNG.
        let tiff = try #require(NSBitmapImageRep(data: data)?.tiffRepresentation)
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        guard case .image(let converted) = ClipboardController.read(pasteboard, skipsConcealed: true, keepsImages: true) else {
            Issue.record("TIFF wasn't read")
            return
        }
        #expect(NSBitmapImageRep(data: converted)?.pixelsWide == 4)
    }

    @Test func readsFilesOverTheirNames() {
        let urls = [URL(filePath: "/tmp/one.txt"), URL(filePath: "/tmp/two.txt")]
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        pasteboard.setString("one.txt\ntwo.txt", forType: .string)
        #expect(ClipboardController.read(pasteboard, skipsConcealed: true, keepsImages: true) == .files(urls))
    }

    @Test func skipsMarkedAndEmptyContents() {
        func read(_ text: String, marked type: NSPasteboard.PasteboardType?, skipsConcealed: Bool = true) -> ClipboardController.Clipping? {
            copy(text)
            if let type { pasteboard.setData(Data(), forType: type) }
            return ClipboardController.read(pasteboard, skipsConcealed: skipsConcealed, keepsImages: true)
        }
        #expect(read("secret", marked: ClipboardController.concealedType) == nil)
        #expect(read("secret", marked: ClipboardController.concealedType, skipsConcealed: false) != nil)
        #expect(read("temp", marked: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"), skipsConcealed: false) == nil)
        #expect(read(" \n\t", marked: nil) == nil)
    }

    @Test func storesImagesOnceAndRemovesThemWithTheirItem() throws {
        let clipboard = controller()
        let data = png()
        let first = try #require(clipboard.makeItem(.image(png: data), source: nil))
        let second = try #require(clipboard.makeItem(.image(png: data), source: nil))
        #expect(first.image == second.image)
        #expect(first.image?.width == 4 && first.image?.height == 3)
        let file = clipboard.imageURL(for: try #require(first.image))
        #expect(try Data(contentsOf: file) == data)

        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        clipboard.capture(from: pasteboard)
        #expect(clipboard.history.items.first?.kind == .image)

        clipboard.delete(try #require(clipboard.history.items.first))
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func captureRecordsEachChangeOnce() {
        let clipboard = controller()
        copy("first")
        clipboard.capture(from: pasteboard)
        clipboard.capture(from: pasteboard)
        copy("second")
        clipboard.capture(from: pasteboard)
        #expect(clipboard.history.items.map(\.text) == ["second", "first"])
    }

    @Test func writePutsEachKindBack() throws {
        let clipboard = controller()
        clipboard.write(.text("hi", rich: .html("<b>hi</b>")), to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "hi")
        #expect(pasteboard.string(forType: .html) == "<b>hi</b>")

        clipboard.write(.text("plain"), to: pasteboard)
        #expect(pasteboard.string(forType: .html) == nil)

        let item = try #require(clipboard.makeItem(.image(png: png()), source: nil))
        #expect(clipboard.write(.image(fileName: try #require(item.image).fileName), to: pasteboard))
        #expect(pasteboard.data(forType: .png) != nil)
        #expect(pasteboard.data(forType: .tiff) != nil)
        #expect(!clipboard.write(.image(fileName: "missing.png"), to: pasteboard))

        let urls = [URL(filePath: "/tmp/x.txt")]
        clipboard.write(.files(urls), to: pasteboard)
        #expect(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] == urls)
    }

    @Test func savesImagesWithUniqueNames() throws {
        let clipboard = controller()
        let item = try #require(clipboard.makeItem(.image(png: png()), source: nil, date: Date(timeIntervalSinceReferenceDate: 0)))
        let folder = directory.appending(path: "Saved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try #require(clipboard.saveImage(item, to: folder))
        let second = try #require(clipboard.saveImage(item, to: folder))
        #expect(first.lastPathComponent.hasPrefix("Clipboard Image 20"))
        #expect(second.lastPathComponent.hasSuffix(" 2.png"))
        #expect(clipboard.saveImage(ClipItem(text: "x", date: .now), to: folder) == nil)
    }

    @Test func historyImagesAndSettingsPersist() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipboard = controller(persisted: true)
        copy("saved")
        clipboard.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setData(png(), forType: .png)
        clipboard.capture(from: pasteboard)
        clipboard.setPinned(clipboard.history.items[1], true)
        clipboard.limit = 50
        clipboard.keepsImages = false

        let reloaded = controller(persisted: true)
        #expect(reloaded.history.items.map(\.kind) == [.image, .text])
        #expect(reloaded.history.items[1].isPinned)
        #expect(reloaded.limit == 50)
        #expect(!reloaded.keepsImages)
        let image = try #require(reloaded.history.items[0].image)
        #expect(FileManager.default.fileExists(atPath: reloaded.imageURL(for: image).path(percentEncoded: false)))
    }

    @Test func autoClearIsOffByDefaultAndPersists() {
        let clipboard = controller()
        #expect(clipboard.itemLifetime == .forever)
        #expect(clipboard.clearDelay == .never)
        clipboard.itemLifetime = .day
        clipboard.clearDelay = .fiveMinutes

        let reloaded = controller()
        #expect(reloaded.itemLifetime == .day)
        #expect(reloaded.clearDelay == .fiveMinutes)
    }

    @Test func oldItemsExpire() {
        let clipboard = controller()
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        copy("old")
        clipboard.tick(pasteboard, now: start)
        copy("pinned")
        clipboard.tick(pasteboard, now: start)
        clipboard.setPinned(clipboard.history.items[0], true)
        copy("recent")
        clipboard.tick(pasteboard, now: start.addingTimeInterval(3000))

        clipboard.tick(pasteboard, now: start.addingTimeInterval(3700))
        #expect(clipboard.history.items.count == 3)   // kept forever by default

        clipboard.itemLifetime = .hour   // applies right away, against the real clock
        #expect(clipboard.history.items.map(\.text) == ["pinned"])
    }

    @Test func expiryRunsOnTick() {
        let clipboard = controller()
        clipboard.itemLifetime = .hour
        let start = Date.now
        copy("soon gone")
        clipboard.tick(pasteboard, now: start)
        clipboard.tick(pasteboard, now: start.addingTimeInterval(3599))
        #expect(clipboard.history.items.count == 1)
        clipboard.tick(pasteboard, now: start.addingTimeInterval(3601))
        #expect(clipboard.history.items.isEmpty)
    }

    @Test func clipboardClearsAfterTheDelay() {
        let clipboard = controller()
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        copy("secret")
        clipboard.tick(pasteboard, now: start)
        clipboard.tick(pasteboard, now: start.addingTimeInterval(600))
        #expect(pasteboard.string(forType: .string) == "secret")   // off by default

        clipboard.clearDelay = .oneMinute
        copy("secret")
        clipboard.tick(pasteboard, now: start)
        clipboard.tick(pasteboard, now: start.addingTimeInterval(59))
        #expect(pasteboard.string(forType: .string) == "secret")
        clipboard.tick(pasteboard, now: start.addingTimeInterval(61))
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(clipboard.history.items.first?.text == "secret")   // the history keeps it

        // Clearing isn't a copy, and nothing more happens until the next one.
        clipboard.tick(pasteboard, now: start.addingTimeInterval(200))
        #expect(clipboard.history.items.count == 1)
    }

    @Test func aNewCopyRestartsTheClearTimer() {
        let clipboard = controller()
        clipboard.clearDelay = .oneMinute
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        copy("first")
        clipboard.tick(pasteboard, now: start)
        copy("second")
        clipboard.tick(pasteboard, now: start.addingTimeInterval(50))
        clipboard.tick(pasteboard, now: start.addingTimeInterval(70))
        #expect(pasteboard.string(forType: .string) == "second")
        clipboard.tick(pasteboard, now: start.addingTimeInterval(111))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func concealedCopiesAreClearedToo() {
        let clipboard = controller()
        clipboard.clearDelay = .oneMinute
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        copy("hunter2")
        pasteboard.setData(Data(), forType: ClipboardController.concealedType)
        clipboard.tick(pasteboard, now: start)
        clipboard.tick(pasteboard, now: start.addingTimeInterval(61))
        #expect(clipboard.history.items.isEmpty)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func loweringTheLimitTrims() {
        let clipboard = controller()
        for index in 0..<60 {
            copy("item \(index)")
            clipboard.capture(from: pasteboard)
        }
        clipboard.limit = 50
        #expect(clipboard.history.items.count == 50)
        #expect(clipboard.history.items.first?.text == "item 59")
    }

    @Test func pickerSelectsFiltersAndRunsCommands() {
        let clipboard = controller()
        for text in ["a", "b", "https://c.com"] {
            copy(text)
            clipboard.capture(from: pasteboard)
        }
        let picker = ClipboardPicker(controller: clipboard)
        #expect(picker.selected?.text == "https://c.com")
        picker.move(by: 1)
        picker.move(by: 5)
        #expect(picker.selected?.text == "a")
        picker.move(by: -1)
        #expect(picker.selected?.text == "b")

        picker.cycleFilter(by: 1)
        #expect(picker.filter == .pinned)
        #expect(picker.selected == nil)
        picker.cycleFilter(by: -2)
        #expect(picker.filter == .files)
        picker.filter = .links
        #expect(picker.selected?.text == "https://c.com")
        picker.filter = .all

        picker.query = "b"
        #expect(picker.run(.togglePin))
        #expect(clipboard.history.items.first { $0.text == "b" }?.isPinned == true)
        #expect(!picker.run(.open))   // plain text can't be opened
        #expect(!picker.run(.saveImage))

        picker.query = ""
        picker.selectedID = clipboard.history.items.first { $0.text == "a" }?.id
        #expect(picker.run(.delete))
        #expect(clipboard.history.items.map(\.text) == ["https://c.com", "b"])
        // "a" was last in the list (pinned "b" sorts first), so the selection moves up to its neighbor.
        #expect(picker.selected?.text == "https://c.com")
    }
}
