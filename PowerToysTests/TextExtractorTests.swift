import AppKit
import CoreImage.CIFilterBuiltins
import Testing
@testable import PowerToys

/// A line at `top` (0 at the bottom of the image, 1 at the top), `height` tall.
private func line(_ text: String, top: CGFloat, height: CGFloat = 0.05, x: CGFloat = 0.1) -> RecognizedLine {
    RecognizedLine(text: text, bounds: CGRect(x: x, y: top - height, width: 0.8, height: height))
}

struct TextLayoutTests {
    /// Two paragraphs: two lines close together, a gap, then one more.
    let page = [
        line("The quick brown", top: 0.9),
        line("fox jumps.", top: 0.84),
        line("Next paragraph", top: 0.7),
    ]

    @Test func keepsLineBreaks() {
        #expect(TextLayout.lines.join(page) == "The quick brown\nfox jumps.\nNext paragraph")
    }

    @Test func joinsIntoParagraphsAtGaps() {
        #expect(TextLayout.paragraphs.join(page) == "The quick brown fox jumps.\nNext paragraph")
    }

    @Test func putsEverythingOnOneLine() {
        #expect(TextLayout.singleLine.join(page) == "The quick brown fox jumps. Next paragraph")
    }

    @Test func nextColumnStartsAParagraph() {
        let columns = [
            line("Left column", top: 0.9, x: 0.05),
            line("ends here", top: 0.84, x: 0.05),
            line("Right column", top: 0.9, x: 0.55),
        ]
        #expect(TextLayout.paragraphs.join(columns) == "Left column ends here\nRight column")
    }

    /// Vision often reads a row in pieces, such as a label and its value.
    let form = [
        line("Name:", top: 0.9, x: 0.05),
        line("John", top: 0.9, x: 0.5),
        line("Email:", top: 0.84, x: 0.05),
        line("john@example.com", top: 0.841, x: 0.5),
    ]

    @Test func piecesOfARowStayOnOneLine() {
        #expect(TextLayout.lines.join(form) == "Name: John\nEmail: john@example.com")
    }

    @Test func piecesOfARowDontStartParagraphs() {
        #expect(TextLayout.paragraphs.join(form) == "Name: John Email: john@example.com")
    }

    @Test func rejoinsWordsBrokenWithAHyphen() {
        let lines = [line("an extra-", top: 0.9), line("ordinary day", top: 0.84)]
        #expect(TextLayout.paragraphs.join(lines) == "an extraordinary day")
    }

    @Test func keepsHyphensThatAreNotBreaks() {
        #expect(TextLayout.append("Pages 10 -", to: "") == "Pages 10 -")
        #expect(TextLayout.append("Next", to: "well-") == "well- Next")
        #expect(TextLayout.append("12", to: "A-") == "A- 12")
    }

    @Test func skipsBlankLines() {
        let lines = [line("One", top: 0.9), line("  ", top: 0.84), line("Two", top: 0.78)]
        #expect(TextLayout.lines.join(lines) == "One\nTwo")
    }

    @Test(arguments: TextLayout.allCases)
    func nothingIsEmpty(layout: TextLayout) {
        #expect(layout.join([]).isEmpty)
    }
}

struct RecognitionLanguageTests {
    @Test func namesLanguagesAndAddsScriptsWhereTheyShareOne() {
        let languages = RecognitionLanguage.all(["zh-Hant-TW", "en-Latn-US", "zh-Hans-CN"], locale: Locale(identifier: "en_US"))
        #expect(languages.map(\.name) == ["Chinese, Simplified", "Chinese, Traditional", "English"])
        #expect(languages.map(\.id) == ["zh-Hans-CN", "zh-Hant-TW", "en-Latn-US"])
    }

    @Test func visionLanguagesIncludeEnglish() {
        #expect(RecognitionLanguage.all().contains { $0.id.hasPrefix("en") })
    }
}

/// Images drawn for Vision to read.
private enum TestImage {
    static func write(_ draw: @escaping (NSRect) -> Void, size: NSSize = NSSize(width: 640, height: 200)) throws -> URL {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            draw(rect)
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = URL.temporaryDirectory.appending(path: "PowerToysTests-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    static func text(_ lines: [String]) throws -> URL {
        try write { _ in
            for (index, text) in lines.enumerated() {
                (text as NSString).draw(
                    at: NSPoint(x: 20, y: 130 - index * 70),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black]
                )
            }
        }
    }

    static func qrCode(_ payload: String) throws -> URL {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        let output = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let cgImage = try #require(CIContext().createCGImage(output, from: output.extent))
        return try write({ _ in
            NSImage(cgImage: cgImage, size: .zero).draw(in: NSRect(x: 40, y: 40, width: 220, height: 220))
        }, size: NSSize(width: 300, height: 300))
    }
}

struct TextRecognizerLineTests {
    @Test func readsLinesTopToBottomWithTheirPlace() async throws {
        let url = try TestImage.text(["First line", "Second line"])
        defer { try? FileManager.default.removeItem(at: url) }

        let lines = await TextRecognizer.lines(in: url)
        #expect(lines.map(\.text) == ["First line", "Second line"])
        #expect(try #require(lines.first).bounds.minY > lines[1].bounds.minY)
    }

    @Test func readsInAChosenLanguage() async throws {
        let url = try TestImage.text(["Hello there"])
        defer { try? FileManager.default.removeItem(at: url) }

        let english = try #require(TextRecognizer.supportedLanguages.first { $0.hasPrefix("en") })
        #expect(await TextRecognizer.lines(in: url, languages: [english]).map(\.text) == ["Hello there"])
    }

    @Test func readsQRCodes() async throws {
        let url = try TestImage.qrCode("https://example.com/powertoys")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await TextRecognizer.codes(in: url) == ["https://example.com/powertoys"])
    }

    @Test func textHasNoCodes() async throws {
        let url = try TestImage.text(["Just words"])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await TextRecognizer.codes(in: url).isEmpty)
    }
}

private final class FakeCapture: ScreenRegionCapturing {
    var hasAccess = true
    var captures = 0
    /// Each capture writes an empty file here, so the controller's cleanup can be seen; nil cancels.
    var url: URL? = URL.temporaryDirectory.appending(path: "PowerToysTests-\(UUID().uuidString).png")
    var delay: Duration?

    func capture() async -> URL? {
        captures += 1
        if let delay { try? await Task.sleep(for: delay) }
        guard let url else { return nil }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }
}

private final class FakeReader: ImageTextReading {
    var found = ImageText()
    var calls: [(languages: [String], correctsLanguage: Bool, readsCodes: Bool)] = []

    func read(_ url: URL, languages: [String], correctsLanguage: Bool, readsCodes: Bool) async -> ImageText {
        calls.append((languages, correctsLanguage, readsCodes))
        return found
    }
}

@MainActor
struct TextExtractorControllerTests {
    let store = TestDefaults()
    fileprivate let capture = FakeCapture()
    fileprivate let reader = FakeReader()
    let pasteboard = NSPasteboard.withUniqueName()
    let alerts = Counter()
    let accessRequests = Counter()
    let accessExplanations = Counter()

    final class Counter { var count = 0 }

    func makeController() -> TextExtractorController {
        let alerts = alerts
        let accessRequests = accessRequests
        let accessExplanations = accessExplanations
        return TextExtractorController(
            defaults: store.defaults, capturer: capture, reader: reader, pasteboard: pasteboard,
            alert: { alerts.count += 1 }, requestAccess: { accessRequests.count += 1 },
            explainAccess: { accessExplanations.count += 1 },
            supportedLanguages: { ["ja-Jpan-JP", "de-Latn-DE"] }
        )
    }

    @Test func copiesTextAndKeepsIt() async throws {
        reader.found = ImageText(lines: [line("Hello", top: 0.9), line("world", top: 0.84)])
        let controller = makeController()

        let extracted = try #require(await controller.extract())
        #expect(extracted.text == "Hello\nworld")
        #expect(pasteboard.string(forType: .string) == "Hello\nworld")
        #expect(controller.history.map(\.text) == ["Hello\nworld"])
        #expect(controller.lastOutcome == .copied)
        #expect(!FileManager.default.fileExists(atPath: try #require(capture.url).path))
    }

    @Test func usesTheChosenLayout() async throws {
        reader.found = ImageText(lines: [line("Hello", top: 0.9), line("world", top: 0.84)])
        let controller = makeController()
        controller.layout = .singleLine

        #expect(await controller.extract()?.text == "Hello world")
    }

    @Test func cancellingCopiesNothing() async {
        capture.url = nil
        pasteboard.copy("before")
        let controller = makeController()

        #expect(await controller.extract() == nil)
        #expect(pasteboard.string(forType: .string) == "before")
        #expect(controller.history.isEmpty)
        #expect(reader.calls.isEmpty)
        #expect(alerts.count == 0)
    }

    @Test func nothingFoundAlertsAndCopiesNothing() async {
        pasteboard.copy("before")
        let controller = makeController()

        #expect(await controller.extract() == nil)
        #expect(alerts.count == 1)
        #expect(controller.lastOutcome == .nothingFound)
        #expect(pasteboard.string(forType: .string) == "before")
    }

    @Test func asksForAccessInsteadOfCapturing() async {
        capture.hasAccess = false
        let controller = makeController()

        #expect(await controller.extract() == nil)
        #expect(accessRequests.count == 1)
        #expect(capture.captures == 0)
        #expect(controller.lastOutcome == .needsAccess)
    }

    @Test func asksOnceThenExplainsInsteadOfAskingAgain() async {
        capture.hasAccess = false
        let controller = makeController()

        await controller.extract()
        await controller.extract()
        await controller.extract()
        #expect(accessRequests.count == 1)
        #expect(accessExplanations.count == 2)
        #expect(capture.captures == 0)
    }

    @Test func cancellingClearsTheLastOutcome() async {
        let controller = makeController()
        await controller.extract()
        #expect(controller.lastOutcome == .nothingFound)

        capture.url = nil
        await controller.extract()
        #expect(controller.lastOutcome == nil)
    }

    @Test func languageNoLongerSupportedIsDetectedInstead() async {
        let controller = makeController()
        controller.language = "xx-Latn-XX"
        await controller.extract()
        #expect(reader.calls.last?.languages == [])
    }

    @Test func passesReadingSettings() async {
        let controller = makeController()
        controller.language = "ja-Jpan-JP"
        controller.correctsLanguage = false
        controller.readsCodes = false
        await controller.extract()

        let call = reader.calls.first
        #expect(call?.languages == ["ja-Jpan-JP"])
        #expect(call?.correctsLanguage == false)
        #expect(call?.readsCodes == false)

        controller.language = nil
        await controller.extract()
        #expect(reader.calls.last?.languages == [])
    }

    @Test func onlyOneSelectionAtATime() async {
        capture.delay = .milliseconds(100)
        reader.found = ImageText(lines: [line("Once", top: 0.9)])
        let controller = makeController()

        async let first = controller.extract()
        await Task.yield()
        #expect(controller.isExtracting)
        #expect(await controller.extract() == nil)
        #expect(await first?.text == "Once")
        #expect(capture.captures == 1)
    }

    @Test func settingsAndHistoryPersist() async {
        reader.found = ImageText(lines: [line("Kept", top: 0.9)])
        let controller = makeController()
        controller.layout = .paragraphs
        controller.language = "de-Latn-DE"
        controller.correctsLanguage = false
        controller.readsCodes = false
        await controller.extract()

        let reopened = makeController()
        #expect(reopened.layout == .paragraphs)
        #expect(reopened.language == "de-Latn-DE")
        #expect(!reopened.correctsLanguage)
        #expect(!reopened.readsCodes)
        #expect(reopened.history.map(\.text) == ["Kept"])
    }

    @Test func startsWithCorrectionAndCodesOn() {
        let controller = makeController()
        #expect(controller.layout == .lines)
        #expect(controller.language == nil)
        #expect(controller.correctsLanguage)
        #expect(controller.readsCodes)
    }

    @Test func historyMovesRepeatsToTopAndIsCapped() {
        let controller = makeController()
        for index in 0..<(TextExtractorController.historyLimit + 5) {
            controller.add(ExtractedText(text: "Item \(index)"))
        }
        controller.add(ExtractedText(text: "Item 10"))

        #expect(controller.history.count == TextExtractorController.historyLimit)
        #expect(controller.history.first?.text == "Item 10")
        #expect(controller.history.filter { $0.text == "Item 10" }.count == 1)
    }

    @Test func removesAndClears() {
        let controller = makeController()
        let first = ExtractedText(text: "One")
        controller.add(first)
        controller.add(ExtractedText(text: "Two"))

        controller.remove(first)
        #expect(controller.history.map(\.text) == ["Two"])
        controller.clearHistory()
        #expect(controller.history.isEmpty)
        #expect(makeController().history.isEmpty)
    }

    @Test func shortcutStartsUnset() {
        #expect(TextExtractorController.extractShortcut.defaultHotKey == nil)
        #expect(ShortcutCatalog.all.contains(TextExtractorController.extractShortcut))
    }
}

struct ExtractedTextAssemblyTests {
    @Test func codesFollowTheText() {
        let found = ImageText(lines: [line("Scan me", top: 0.9)], codes: ["https://a.example"])
        #expect(TextExtractorController.text(from: found, layout: .lines) == "Scan me\nhttps://a.example")
        #expect(TextExtractorController.text(from: found, layout: .singleLine) == "Scan me https://a.example")
    }

    @Test func codeAloneIsTheText() {
        let found = ImageText(codes: ["WIFI:S:Home;;", "12345"])
        #expect(TextExtractorController.text(from: found, layout: .paragraphs) == "WIFI:S:Home;;\n12345")
    }

    @Test func codeFoundInsideOtherTextIsStillAdded() {
        let found = ImageText(lines: [line("Order 12345 shipped", top: 0.9)], codes: ["1234"])
        #expect(TextExtractorController.text(from: found, layout: .lines) == "Order 12345 shipped\n1234")
    }

    @Test func menuTitlesAreOneShortLine() {
        #expect(ExtractedText(text: "Line one\nLine two").menuTitle == "Line one Line two")
        #expect(ExtractedText(text: String(repeating: "a", count: 50)).menuTitle == String(repeating: "a", count: 40) + "…")
    }

    @Test func codePrintedUnderneathIsNotRepeated() {
        let found = ImageText(lines: [line("4006381333931", top: 0.2)], codes: ["4006381333931"])
        #expect(TextExtractorController.text(from: found, layout: .lines) == "4006381333931")
    }
}
