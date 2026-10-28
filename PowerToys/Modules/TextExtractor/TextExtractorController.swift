import AppKit
import CoreGraphics
import Observation

/// Lets the user select part of the screen and saves it as an image; a protocol so tests don't show it.
protocol ScreenRegionCapturing {
    var hasAccess: Bool { get }
    /// An image of the region selected, or nil when selecting was cancelled with Esc.
    func capture() async -> URL?
}

/// The system's own selection, as ⇧⌘4 shows: drag over a region, or press Space and click a window.
struct LiveRegionCapture: ScreenRegionCapturing {
    var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    func capture() async -> URL? {
        let url = URL.temporaryDirectory.appending(path: "PowerToys-text-\(UUID().uuidString).png")
        // -i selects interactively, -x without the shutter sound, -o without window shadows.
        _ = try? await Command.run("/usr/sbin/screencapture", ["-i", "-x", "-o", "-t", "png", url.path])
        // Nothing is written when selecting is cancelled.
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Reads an image; a protocol so tests can give text without Vision.
protocol ImageTextReading {
    func read(_ url: URL, languages: [String], correctsLanguage: Bool, readsCodes: Bool) async -> ImageText
}

struct LiveImageTextReader: ImageTextReading {
    func read(_ url: URL, languages: [String], correctsLanguage: Bool, readsCodes: Bool) async -> ImageText {
        async let lines = TextRecognizer.lines(in: url, languages: languages, correctsLanguage: correctsLanguage)
        async let codes = readsCodes ? TextRecognizer.codes(in: url) : []
        return await ImageText(lines: lines, codes: codes)
    }
}

/// Text read off the screen and copied.
nonisolated struct ExtractedText: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    let text: String
    var date = Date.now

    /// The start of the text on one line, for menus.
    var menuTitle: String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 40 ? flat.prefix(40) + "…" : flat
    }
}

/// Reads the text in a region of the screen, copies it and keeps the recent ones.
@Observable
final class TextExtractorController {
    /// How the last extraction ended, for the settings to explain.
    enum Outcome: Equatable {
        case copied
        case nothingFound
        case needsAccess
    }

    private(set) var history: [ExtractedText]
    private(set) var isExtracting = false
    private(set) var lastOutcome: Outcome?

    var layout: TextLayout {
        didSet { defaults.set(layout.rawValue, forKey: Self.layoutKey) }
    }

    /// A BCP 47 code from `RecognitionLanguage.all`, or nil to detect the language.
    var language: String? {
        didSet { defaults.set(language, forKey: Self.languageKey) }
    }

    /// Lets Vision fix words it isn't sure of; off reads codes, serial numbers and the like as they are.
    var correctsLanguage: Bool {
        didSet { defaults.set(correctsLanguage, forKey: Self.correctsLanguageKey) }
    }

    /// Also reads QR codes and barcodes, copying what they hold after any text.
    var readsCodes: Bool {
        didSet { defaults.set(readsCodes, forKey: Self.readsCodesKey) }
    }

    /// Unset until assigned, as every shortcut in the app starts out.
    static let extractShortcut = ShortcutDefinition(id: "textExtractor.extract", module: .textExtractor, title: "Extract text", defaultHotKey: nil)

    static let historyLimit = 20
    static let historyKey = "textExtractor.history"
    static let layoutKey = "textExtractor.layout"
    static let languageKey = "textExtractor.language"
    static let correctsLanguageKey = "textExtractor.correctsLanguage"
    static let readsCodesKey = "textExtractor.readsCodes"

    private let defaults: UserDefaults
    @ObservationIgnored private let capturer: any ScreenRegionCapturing
    @ObservationIgnored private let reader: any ImageTextReading
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let alert: () -> Void
    @ObservationIgnored private let requestAccess: () -> Void
    @ObservationIgnored private let explainAccess: () -> Void
    @ObservationIgnored private let supportedLanguages: () -> [String]
    /// Access granted in System Settings only counts once the app is opened again, so after
    /// asking once, presses explain that instead of asking again.
    @ObservationIgnored private var hasRequestedAccess = false

    init(
        defaults: UserDefaults = .standard,
        capturer: any ScreenRegionCapturing = LiveRegionCapture(),
        reader: any ImageTextReading = LiveImageTextReader(),
        pasteboard: NSPasteboard = .general,
        alert: @escaping () -> Void = { NSSound.beep() },
        requestAccess: @escaping () -> Void = {},
        explainAccess: @escaping () -> Void = {},
        supportedLanguages: @escaping () -> [String] = { TextRecognizer.supportedLanguages }
    ) {
        self.defaults = defaults
        self.capturer = capturer
        self.reader = reader
        self.pasteboard = pasteboard
        self.alert = alert
        self.requestAccess = requestAccess
        self.explainAccess = explainAccess
        self.supportedLanguages = supportedLanguages
        defaults.register(defaults: [Self.correctsLanguageKey: true, Self.readsCodesKey: true])
        layout = defaults.string(forKey: Self.layoutKey).flatMap(TextLayout.init(rawValue:)) ?? .lines
        language = defaults.string(forKey: Self.languageKey)
        correctsLanguage = defaults.bool(forKey: Self.correctsLanguageKey)
        readsCodes = defaults.bool(forKey: Self.readsCodesKey)
        history = defaults.data(forKey: Self.historyKey)
            .flatMap { try? JSONDecoder().decode([ExtractedText].self, from: $0) }
            ?? []
    }

    var latest: ExtractedText? { history.first }

    /// Shows the selection; the text in the region is copied and goes to the top of the history.
    /// Returns nil when cancelled, when nothing was found (with an alert sound), or without
    /// Screen Recording access, which is asked for.
    @discardableResult
    func extract() async -> ExtractedText? {
        guard !isExtracting else { return nil }
        guard capturer.hasAccess else {
            if hasRequestedAccess {
                explainAccess()
            } else {
                hasRequestedAccess = true
                requestAccess()
            }
            lastOutcome = .needsAccess
            return nil
        }
        isExtracting = true
        defer { isExtracting = false }
        guard let url = await capturer.capture() else {
            lastOutcome = nil
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let found = await reader.read(url, languages: readingLanguages, correctsLanguage: correctsLanguage, readsCodes: readsCodes)
        let text = Self.text(from: found, layout: layout)
        guard !text.isEmpty else {
            lastOutcome = .nothingFound
            alert()
            return nil
        }
        let extracted = ExtractedText(text: text)
        add(extracted)
        copy(extracted)
        lastOutcome = .copied
        return extracted
    }

    /// The chosen language, or none to detect it, as when a macOS update drops the one chosen.
    private var readingLanguages: [String] {
        guard let language, supportedLanguages().contains(language) else { return [] }
        return [language]
    }

    /// The text laid out, then each code's payload on a line of its own.
    nonisolated static func text(from found: ImageText, layout: TextLayout) -> String {
        let text = layout.join(found.lines)
        // A code's own digits or URL are often printed under it as a line of their own; once is enough.
        let printed = Set(found.lines.map { $0.text.trimmingCharacters(in: .whitespaces) })
        let codes = found.codes.filter { !printed.contains($0) }
        let separator = layout == .singleLine ? " " : "\n"
        return ([text] + codes).filter { !$0.isEmpty }.joined(separator: separator)
    }

    func add(_ extracted: ExtractedText) {
        history.removeAll { $0.text == extracted.text }
        history.insert(extracted, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        save()
    }

    func copy(_ extracted: ExtractedText) {
        pasteboard.copy(extracted.text)
    }

    func remove(_ extracted: ExtractedText) {
        history.removeAll { $0.id == extracted.id }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(history), forKey: Self.historyKey)
    }
}
