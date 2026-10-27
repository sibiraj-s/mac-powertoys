import Foundation
import Testing
@testable import PowerToys

struct PasteFormatTests {
    private let image = ClipItem.Image(fileName: "a.png", width: 1, height: 1, byteCount: 1, digest: "d")

    @Test func plainItem() {
        let plain = ClipItem(text: "hello", date: .now)
        #expect(PasteFormat.original.contents(of: plain) == .text("hello"))
        #expect(PasteFormat.markdown.contents(of: plain) == nil)
        #expect(PasteFormat.json.contents(of: plain) == nil)
        #expect(PasteFormat.allCases.filter { $0.applies(to: plain) } == [.original])
    }

    @Test func richItem() {
        let rich = ClipItem(text: "hi", richText: .html("<b>hi</b>"), date: .now)
        #expect(PasteFormat.original.contents(of: rich) == .text("hi", rich: .html("<b>hi</b>")))
        #expect(PasteFormat.plainText.contents(of: rich) == .text("hi"))
        #expect(PasteFormat.allCases.filter { $0.applies(to: rich) } == [.original, .plainText, .markdown])
    }

    @Test func jsonItem() {
        let json = ClipItem(text: #"{"a":1}"#, date: .now)
        #expect(PasteFormat.allCases.filter { $0.applies(to: json) } == [.original, .json])
    }

    @Test func imageItem() {
        let blank = ClipItem(text: "", image: image, date: .now)
        #expect(PasteFormat.original.contents(of: blank) == .image(fileName: "a.png"))
        #expect(PasteFormat.plainText.contents(of: blank) == nil)
        #expect(!PasteFormat.plainText.applies(to: blank))

        let withText = ClipItem(text: "words", image: image, date: .now)
        #expect(PasteFormat.plainText.contents(of: withText) == .text("words"))
        #expect(PasteFormat.json.contents(of: ClipItem(text: "[1]", image: image, date: .now)) == nil)
    }

    @Test func filesItem() {
        let urls = [URL(filePath: "/tmp/a"), URL(filePath: "/tmp/b")]
        let files = ClipItem(text: "/tmp/a\n/tmp/b", fileURLs: urls, date: .now)
        #expect(PasteFormat.original.contents(of: files) == .files(urls))
        #expect(PasteFormat.plainText.contents(of: files) == .text("/tmp/a\n/tmp/b"))
    }

    @Test func formatKeysAreDistinct() {
        let keys = PasteFormat.allCases.map(\.keyCaps)
        #expect(Set(keys).count == keys.count)
    }
}

struct ClipCommandTests {
    @Test func commandsFollowTheKind() {
        let text = ClipItem(text: "hello", date: .now)
        #expect(ClipCommand.available(for: text) == [.paste(.original), .copy, .togglePin, .delete])

        let link = ClipItem(text: "https://apple.com", date: .now)
        #expect(ClipCommand.available(for: link).contains(.open))
        #expect(ClipCommand.open.title(for: link) == "Open link")

        let files = ClipItem(text: "/tmp/a", fileURLs: [URL(filePath: "/tmp/a")], date: .now)
        #expect(ClipCommand.available(for: files) == [.paste(.original), .paste(.plainText), .copy, .open, .reveal, .togglePin, .delete])
        #expect(ClipCommand.paste(.plainText).title(for: files) == "Paste paths")

        let image = ClipItem(text: "", image: .init(fileName: "a.png", width: 1, height: 1, byteCount: 1, digest: "d"), date: .now)
        #expect(ClipCommand.available(for: image) == [.paste(.original), .copy, .open, .saveImage, .togglePin, .delete])
    }

    @Test func everyCommandHasDistinctKeys() {
        let commands: [ClipCommand] = PasteFormat.allCases.map(ClipCommand.paste) + [.copy, .open, .reveal, .saveImage, .togglePin, .delete]
        let keys = commands.map(\.keyCaps)
        #expect(Set(keys).count == keys.count)
    }

    @Test func panelKeysMatchTheCommandKeyCaps() {
        #expect(ClipboardPanel.command(keyCode: 36, flags: []) == .paste(.original))
        #expect(ClipboardPanel.command(keyCode: 36, flags: .shift) == .paste(.plainText))
        #expect(ClipboardPanel.command(keyCode: 8, flags: .command) == .copy)
        #expect(ClipboardPanel.command(keyCode: 31, flags: .command) == .open)
        #expect(ClipboardPanel.command(keyCode: 51, flags: .command) == .delete)
        #expect(ClipboardPanel.command(keyCode: 8, flags: []) == nil)
        #expect(ClipboardPanel.command(keyCode: 8, flags: [.command, .shift]) == nil)
    }
}
