import AppKit
import Testing
@testable import PowerToys

private func clip(_ text: String, pinned: Bool = false, minutesAgo: Double = 0) -> ClipItem {
    ClipItem(text: text, date: Date(timeIntervalSinceReferenceDate: 1_000_000 - minutesAgo * 60), isPinned: pinned)
}

struct ClipboardHistoryTests {
    @Test func newestFirst() {
        var history = ClipboardHistory()
        history.record(clip("one"), limit: 10)
        history.record(clip("two"), limit: 10)
        #expect(history.items.map(\.text) == ["two", "one"])
    }

    @Test func copyingAgainMovesUpInsteadOfDuplicating() {
        var history = ClipboardHistory()
        history.record(clip("one"), limit: 10)
        let id = history.items[0].id
        history.setPinned(id, true)
        history.record(clip("two"), limit: 10)
        history.record(clip("one"), limit: 10)

        #expect(history.items.map(\.text) == ["one", "two"])
        #expect(history.items[0].id == id)
        #expect(history.items[0].isPinned)
    }

    @Test func limitDropsOldestUnpinned() {
        var history = ClipboardHistory()
        history.record(clip("keep me"), limit: 2)
        history.setPinned(history.items[0].id, true)
        for text in ["a", "b", "c"] {
            history.record(clip(text), limit: 2)
        }
        #expect(history.items.map(\.text) == ["c", "b", "keep me"])

        history.trim(to: 1)
        #expect(history.items.map(\.text) == ["c", "keep me"])
    }

    @Test func clearKeepsPinned() {
        var history = ClipboardHistory()
        history.record(clip("pinned"), limit: 10)
        history.setPinned(history.items[0].id, true)
        history.record(clip("loose"), limit: 10)
        history.clear()
        #expect(history.items.map(\.text) == ["pinned"])
    }

    @Test func removesOldUnpinnedItems() {
        var history = ClipboardHistory()
        history.record(clip("old pinned", minutesAgo: 120), limit: 10)
        history.setPinned(history.items[0].id, true)
        history.record(clip("old", minutesAgo: 90), limit: 10)
        history.record(clip("new", minutesAgo: 5), limit: 10)

        let cutoff = Date(timeIntervalSinceReferenceDate: 1_000_000 - 60 * 60)
        let removed = history.removeItems(copiedBefore: cutoff)
        #expect(removed)
        #expect(history.items.map(\.text) == ["new", "old pinned"])
        let removedAgain = history.removeItems(copiedBefore: cutoff)
        #expect(!removedAgain)
    }

    @Test func touchMovesToTopWithNewDate() {
        var history = ClipboardHistory()
        history.record(clip("old", minutesAgo: 10), limit: 10)
        history.record(clip("new"), limit: 10)
        let later = Date(timeIntervalSinceReferenceDate: 2_000_000)
        history.touch(history.items[1].id, at: later)
        #expect(history.items.map(\.text) == ["old", "new"])
        #expect(history.items[0].date == later)
    }

    @Test func removeDeletesOnlyThatItem() {
        var history = ClipboardHistory()
        history.record(clip("a"), limit: 10)
        history.record(clip("b"), limit: 10)
        history.remove(history.items[0].id)
        #expect(history.items.map(\.text) == ["a"])
    }

    @Test func searchMatchesAllWordsAndPutsPinnedFirst() {
        var history = ClipboardHistory()
        history.record(clip("git push origin main"), limit: 10)
        history.record(clip("Pinned GIT note"), limit: 10)
        history.setPinned(history.items[0].id, true)
        history.record(clip("git status"), limit: 10)
        history.record(clip("unrelated"), limit: 10)

        #expect(history.matching("git").map(\.text) == ["Pinned GIT note", "git status", "git push origin main"])
        #expect(history.matching("origin git").map(\.text) == ["git push origin main"])
        #expect(history.matching("  ").count == 4)
        #expect(history.matching("nothing").isEmpty)
    }

    @Test func previewIsOneLine() {
        #expect(clip("  first\n\n\tsecond   third ").preview == "first second third")
    }

    @Test func survivesEncoding() throws {
        var history = ClipboardHistory()
        var item = clip("rich")
        item.richText = .html("<b>rich</b>")
        item.sourceBundleID = "com.apple.Safari"
        history.record(item, limit: 10)
        history.record(clip("plain"), limit: 10)

        let decoded = try JSONDecoder().decode(ClipboardHistory.self, from: JSONEncoder().encode(history))
        #expect(decoded == history)
    }
}

struct ClipItemTests {
    private func item(_ text: String) -> ClipItem { ClipItem(text: text, date: .now) }
    private let image = ClipItem.Image(fileName: "a.png", width: 1280, height: 800, byteCount: 1_500_000, digest: "abc")

    @Test func kindsFromText() {
        #expect(item("hello world").kind == .text)
        #expect(item(" https://example.com/a?b=1 \n").kind == .link)
        #expect(item("https://example.com and more").kind == .text)
        #expect(item("ftp://example.com").kind == .text)
        #expect(item("#ff8800").kind == .color)
        #expect(item("#F80").kind == .color)
        #expect(item("#ff880080").kind == .color)
        #expect(item("ff8800").kind == .text)
        #expect(item("#ff88").kind == .text)
    }

    @Test func kindsFromContent() {
        #expect(ClipItem(text: "", image: image, date: .now).kind == .image)
        #expect(ClipItem(text: "/tmp/a", fileURLs: [URL(filePath: "/tmp/a")], date: .now).kind == .files)
    }

    @Test func hexColors() {
        #expect(ClipItem.hexColor("#ff0000") == [1, 0, 0, 1])
        #expect(ClipItem.hexColor("#0F0") == [0, 1, 0, 1])
        #expect(ClipItem.hexColor("#00000000") == [0, 0, 0, 0])
        #expect(ClipItem.hexColor("red") == nil)
    }

    @Test func titlesAndDetails() {
        let picture = ClipItem(text: "", image: image, date: .now)
        #expect(picture.title == "Image 1280 × 800")
        #expect(picture.details.hasPrefix("1280 × 800 · "))

        let files = ClipItem(text: "", fileURLs: [URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/b.png")], date: .now)
        #expect(files.title == "2 files: a.txt, b.png")
        #expect(files.details == "2 files")

        #expect(item("one\ntwo\nthree").details == "13 characters · 3 lines")
        #expect(item("x").details == "1 character")
    }

    @Test func sameImageIsOneEntryAndKeepsItsText() {
        var history = ClipboardHistory()
        history.record(ClipItem(text: "", image: image, date: .now), limit: 10)
        history.setText(history.items[0].id, "recognized")
        history.record(item("other"), limit: 10)
        history.record(ClipItem(text: "", image: image, date: .now), limit: 10)

        #expect(history.items.count == 2)
        #expect(history.items[0].text == "recognized")
    }

    @Test func imagesHaveTheirOwnLimit() {
        var history = ClipboardHistory()
        for index in 0..<(ClipboardHistory.maxImages + 5) {
            let picture = ClipItem.Image(fileName: "\(index).png", width: 1, height: 1, byteCount: 1, digest: "\(index)")
            history.record(ClipItem(text: "", image: picture, date: .now), limit: 500)
        }
        history.record(item("text"), limit: 500)
        #expect(history.items.count(where: { $0.image != nil }) == ClipboardHistory.maxImages)
        #expect(history.items.first?.text == "text")
    }

    @Test func filters() {
        var history = ClipboardHistory()
        history.record(item("plain"), limit: 10)
        history.record(item("#abcdef"), limit: 10)
        history.record(item("https://apple.com"), limit: 10)
        history.record(ClipItem(text: "screenshot words", image: image, date: .now), limit: 10)
        history.record(ClipItem(text: "/tmp/f", fileURLs: [URL(filePath: "/tmp/f")], date: .now), limit: 10)
        history.setPinned(history.items[4].id, true)

        func texts(_ filter: ClipboardHistory.Filter, _ query: String = "") -> [String] {
            history.matching(query, filter: filter).map(\.text)
        }
        #expect(texts(.all).count == 5)
        #expect(texts(.pinned) == ["plain"])
        #expect(texts(.text) == ["plain", "#abcdef"])
        #expect(texts(.links) == ["https://apple.com"])
        #expect(texts(.images) == ["screenshot words"])
        #expect(texts(.files) == ["/tmp/f"])
        #expect(texts(.all, "words") == ["screenshot words"])
    }
}
