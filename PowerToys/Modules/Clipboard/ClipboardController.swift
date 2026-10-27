import AppKit
import Carbon.HIToolbox
import CryptoKit
import Observation

/// Watches the pasteboard, keeps the history on disk and pastes items back into the frontmost app.
@Observable
final class ClipboardController {
    enum Action: CaseIterable, Identifiable {
        case showHistory, pastePlainText

        var id: Self { self }

        var title: String {
            switch self {
            case .showHistory: "Open clipboard history"
            case .pastePlainText: "Paste clipboard as plain text"
            }
        }

        var shortcut: ShortcutDefinition {
            ShortcutDefinition(id: "clipboard.\(self)", module: .clipboard, title: title, defaultHotKey: defaultHotKey)
        }

        var defaultHotKey: HotKey {
            switch self {
            case .showHistory: HotKey(keyCode: kVK_ANSI_V, modifiers: [.control, .option], key: "V")
            case .pastePlainText: HotKey(keyCode: kVK_ANSI_V, modifiers: [.control, .option, .shift], key: "V")
            }
        }
    }

    /// What was read off the pasteboard, before it becomes a history item.
    enum Clipping: Equatable {
        case text(String, ClipItem.RichText?)
        case image(png: Data)
        case files([URL])
    }

    /// How long unpinned items stay in the history.
    enum ItemLifetime: Int, CaseIterable, Identifiable {
        case forever = 0
        case hour = 3600
        case day = 86_400
        case week = 604_800
        case month = 2_592_000

        var id: Self { self }

        var title: String {
            switch self {
            case .forever: "Never"
            case .hour: "After an hour"
            case .day: "After a day"
            case .week: "After a week"
            case .month: "After a month"
            }
        }
    }

    /// How long something stays on the clipboard itself before it's cleared.
    enum ClearDelay: Int, CaseIterable, Identifiable {
        case never = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case hour = 3600

        var id: Self { self }

        var title: String {
            switch self {
            case .never: "Never"
            case .oneMinute: "1 minute"
            case .fiveMinutes: "5 minutes"
            case .fifteenMinutes: "15 minutes"
            case .hour: "1 hour"
            }
        }
    }

    static let limits = [50, 100, 200, 500]

    /// How many unpinned items to keep.
    var limit: Int {
        didSet {
            defaults.set(limit, forKey: Self.limitKey)
            history.trim(to: limit)
            save()
        }
    }

    /// Unpinned items older than this are removed.
    var itemLifetime: ItemLifetime {
        didSet {
            defaults.set(itemLifetime.rawValue, forKey: Self.itemLifetimeKey)
            removeExpiredItems()
        }
    }

    /// Empties the clipboard this long after the last copy, so secrets don't linger on it.
    /// The history keeps the item.
    var clearDelay: ClearDelay {
        didSet { defaults.set(clearDelay.rawValue, forKey: Self.clearDelayKey) }
    }

    /// Skip what password managers mark as concealed.
    var skipsConcealed: Bool {
        didSet { defaults.set(skipsConcealed, forKey: Self.skipsConcealedKey) }
    }

    /// Keep copied images and screenshots.
    var keepsImages: Bool {
        didSet { defaults.set(keepsImages, forKey: Self.keepsImagesKey) }
    }

    /// Recognize text in copied images so search finds them.
    var recognizesText: Bool {
        didSet { defaults.set(recognizesText, forKey: Self.recognizesTextKey) }
    }

    private(set) var history: ClipboardHistory
    private(set) var isRunning = false

    static let limitKey = "clipboard.limit"
    static let skipsConcealedKey = "clipboard.skipsConcealed"
    static let keepsImagesKey = "clipboard.keepsImages"
    static let recognizesTextKey = "clipboard.recognizesText"
    static let itemLifetimeKey = "clipboard.itemLifetime"
    static let clearDelayKey = "clipboard.clearDelay"

    /// Text longer than this isn't kept; rich text over it is kept as plain text only.
    static let maxLength = 1_000_000
    static let maxImageBytes = 25_000_000

    static var defaultStoreDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "PowerToys")
    }

    private let defaults: UserDefaults
    let shortcuts: Shortcuts
    private let historyURL: URL?
    let imagesDirectory: URL

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = 0
    /// When the clipboard last changed, for `clearDelay`; nil once it's been cleared.
    @ObservationIgnored private var clipboardChangedAt: Date?
    @ObservationIgnored private lazy var panel = ClipboardPanel(controller: self)

    /// With `storeDirectory` nil the history is kept in memory and images in a temporary folder.
    init(defaults: UserDefaults = .standard, storeDirectory: URL? = ClipboardController.defaultStoreDirectory, shortcuts: Shortcuts? = nil) {
        self.defaults = defaults
        self.shortcuts = shortcuts ?? Shortcuts(defaults: defaults)
        historyURL = storeDirectory?.appending(path: "ClipboardHistory.json")
        imagesDirectory = (storeDirectory ?? URL.temporaryDirectory.appending(path: "PowerToys-\(UUID().uuidString)"))
            .appending(path: "ClipboardImages")
        defaults.register(defaults: [
            Self.limitKey: 200,
            Self.skipsConcealedKey: true,
            Self.keepsImagesKey: true,
            Self.recognizesTextKey: true,
        ])
        limit = defaults.integer(forKey: Self.limitKey)
        skipsConcealed = defaults.bool(forKey: Self.skipsConcealedKey)
        keepsImages = defaults.bool(forKey: Self.keepsImagesKey)
        recognizesText = defaults.bool(forKey: Self.recognizesTextKey)
        itemLifetime = ItemLifetime(rawValue: defaults.integer(forKey: Self.itemLifetimeKey)) ?? .forever
        clearDelay = ClearDelay(rawValue: defaults.integer(forKey: Self.clearDelayKey)) ?? .never
        history = historyURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(ClipboardHistory.self, from: $0) }
            ?? ClipboardHistory()
        removeExpiredItems()
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        for action in Action.allCases {
            shortcuts.activate(action.shortcut) { [weak self] in self?.perform(action) }
        }
        // Whatever is on the pasteboard now was copied before; only record what comes next.
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(.general) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for action in Action.allCases {
            shortcuts.deactivate(action.shortcut)
        }
        timer?.invalidate()
        timer = nil
        panel.hide()
    }

    func perform(_ action: Action) {
        switch action {
        case .showHistory: panel.toggle()
        case .pastePlainText: pasteClipboardAsPlainText()
        }
    }

    func showHistory() {
        panel.show()
    }

    // MARK: Recording

    /// What the timer does every half second while running.
    func tick(_ pasteboard: NSPasteboard, now: Date = .now) {
        capture(from: pasteboard, now: now)
        clearClipboardIfDue(pasteboard, now: now)
        removeExpiredItems(now: now)
    }

    /// Records the pasteboard's contents if they changed since the last look.
    func capture(from pasteboard: NSPasteboard, now: Date = .now) {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        // Counts even for what isn't recorded, such as a concealed password.
        clipboardChangedAt = now
        guard let clipping = Self.read(pasteboard, skipsConcealed: skipsConcealed, keepsImages: keepsImages),
              let item = makeItem(clipping, source: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, date: now)
        else { return }
        history.record(item, limit: limit)
        save()
        if let recorded = history.items.first, recorded.image != nil, recorded.text.isEmpty {
            recognizeText(in: recorded)
        }
    }

    /// Markers apps put on pasteboard contents that shouldn't be kept (see nspasteboard.org).
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let alwaysSkippedTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    /// Files win over text (Finder also puts their names as text), and text over images, because
    /// apps such as Excel and Pages add a picture of what you copied alongside the text.
    static func read(_ pasteboard: NSPasteboard, skipsConcealed: Bool, keepsImages: Bool) -> Clipping? {
        let types = Set(pasteboard.types ?? [])
        guard types.isDisjoint(with: alwaysSkippedTypes),
              !(skipsConcealed && types.contains(concealedType))
        else { return nil }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        if let text = pasteboard.string(forType: .string), !text.allSatisfy(\.isWhitespace) {
            guard text.utf16.count <= maxLength else { return nil }
            var richText: ClipItem.RichText?
            if let html = pasteboard.string(forType: .html), html.utf16.count <= maxLength {
                richText = .html(html)
            } else if let rtf = pasteboard.data(forType: .rtf), rtf.count <= maxLength {
                richText = .rtf(rtf)
            }
            return .text(text, richText)
        }
        if keepsImages, let png = pngData(from: pasteboard), png.count <= maxImageBytes {
            return .image(png: png)
        }
        return nil
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    func makeItem(_ clipping: Clipping, source: String?, date: Date = .now) -> ClipItem? {
        switch clipping {
        case .text(let text, let richText):
            return ClipItem(text: text, richText: richText, date: date, sourceBundleID: source)
        case .files(let urls):
            let paths = urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
            return ClipItem(text: paths, fileURLs: urls, date: date, sourceBundleID: source)
        case .image(let png):
            guard let image = storeImage(png) else { return nil }
            return ClipItem(text: "", image: image, date: date, sourceBundleID: source)
        }
    }

    /// Saves the PNG under its digest, so the same image is stored once.
    private func storeImage(_ png: Data) -> ClipItem.Image? {
        guard let rep = NSBitmapImageRep(data: png) else { return nil }
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let image = ClipItem.Image(
            fileName: "\(digest.prefix(32)).png", width: rep.pixelsWide, height: rep.pixelsHigh,
            byteCount: png.count, digest: digest
        )
        let url = imageURL(for: image)
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try png.write(to: url, options: .atomic)
            }
        } catch {
            NSLog("Saving clipboard image failed: \(error)")
            return nil
        }
        return image
    }

    func imageURL(for image: ClipItem.Image) -> URL {
        imagesDirectory.appending(path: image.fileName)
    }

    private func recognizeText(in item: ClipItem) {
        guard recognizesText, let image = item.image else { return }
        let url = imageURL(for: image)
        Task {
            let text = await TextRecognizer.text(in: url)
            guard !text.isEmpty else { return }
            history.setText(item.id, text)
            save()
        }
    }

    /// Empties the clipboard once it has sat unchanged for `clearDelay`.
    private func clearClipboardIfDue(_ pasteboard: NSPasteboard, now: Date) {
        guard clearDelay != .never,
              let changedAt = clipboardChangedAt,
              now.timeIntervalSince(changedAt) >= TimeInterval(clearDelay.rawValue),
              pasteboard.changeCount == lastChangeCount
        else { return }
        pasteboard.clearContents()
        lastChangeCount = pasteboard.changeCount
        clipboardChangedAt = nil
    }

    private func removeExpiredItems(now: Date = .now) {
        guard itemLifetime != .forever,
              history.removeItems(copiedBefore: now.addingTimeInterval(-TimeInterval(itemLifetime.rawValue)))
        else { return }
        save()
    }

    // MARK: Editing

    func setPinned(_ item: ClipItem, _ isPinned: Bool) {
        history.setPinned(item.id, isPinned)
        save()
    }

    func delete(_ item: ClipItem) {
        history.remove(item.id)
        save()
    }

    func clearHistory() {
        history.clear()
        save()
    }

    /// Bytes of stored images.
    var imageBytes: Int {
        history.items.reduce(0) { $0 + ($1.image?.byteCount ?? 0) }
    }

    private func save() {
        if let historyURL {
            do {
                try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
            } catch {
                NSLog("Saving clipboard history failed: \(error)")
            }
        }
        removeUnusedImages()
    }

    private func removeUnusedImages() {
        let used = Set(history.items.compactMap(\.image?.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !used.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Using items

    /// Can paste into other apps; without it, pasting only copies.
    var canPaste: Bool { AXIsProcessTrusted() }

    func paste(_ item: ClipItem, as format: PasteFormat) {
        guard let contents = format.contents(of: item), write(contents, to: .general) else {
            NSSound.beep()
            return
        }
        panel.hide()
        history.touch(item.id)
        save()
        sendPasteKeystroke()
    }

    /// Puts the item back on the clipboard without pasting it.
    func copy(_ item: ClipItem) {
        guard let contents = PasteFormat.original.contents(of: item), write(contents, to: .general) else {
            NSSound.beep()
            return
        }
        panel.hide()
        history.touch(item.id)
        save()
    }

    /// Opens a link in the browser, files in their apps, or an image in Preview.
    func open(_ item: ClipItem) {
        let urls: [URL] = switch item.kind {
        case .link: item.linkURL.map { [$0] } ?? []
        case .files: item.fileURLs ?? []
        case .image: item.image.map { [imageURL(for: $0)] } ?? []
        case .text, .color: []
        }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        panel.hide()
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    func revealInFinder(_ item: ClipItem) {
        guard let urls = item.fileURLs else { return }
        panel.hide()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func saveImageToDownloads(_ item: ClipItem) {
        guard let saved = saveImage(item, to: .downloadsDirectory) else {
            NSSound.beep()
            return
        }
        panel.hide()
        NSWorkspace.shared.activateFileViewerSelecting([saved])
    }

    /// Copies a stored image into `directory` with a readable, unused name.
    @discardableResult
    func saveImage(_ item: ClipItem, to directory: URL) -> URL? {
        guard let image = item.image else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Clipboard Image \(formatter.string(from: item.date))"
        var destination = directory.appending(path: "\(base).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = directory.appending(path: "\(base) \(counter).png")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: imageURL(for: image), to: destination)
            return destination
        } catch {
            NSLog("Saving clipboard image failed: \(error)")
            return nil
        }
    }

    /// "Paste and match style" for whatever is on the clipboard now.
    func pasteClipboardAsPlainText() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }
        write(.text(text), to: .general)
        sendPasteKeystroke()
    }

    @discardableResult
    func write(_ contents: PasteContents, to pasteboard: NSPasteboard) -> Bool {
        switch contents {
        case .text(let text, let richText):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            switch richText {
            case .html(let html): pasteboard.setString(html, forType: .html)
            case .rtf(let data): pasteboard.setData(data, forType: .rtf)
            case nil: break
            }
        case .image(let fileName):
            guard let png = try? Data(contentsOf: imagesDirectory.appending(path: fileName)) else { return false }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            // Older apps only read TIFF.
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        case .files(let urls):
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        }
        // Our own write isn't a new copy, but it does restart the clear timer.
        if pasteboard == .general {
            lastChangeCount = pasteboard.changeCount
            clipboardChangedAt = .now
        }
        return true
    }

    /// Presses ⌘V in the frontmost app once the panel is gone and its window is key again.
    private func sendPasteKeystroke() {
        guard canPaste else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            let source = CGEventSource(stateID: .combinedSessionState)
            // Ignore keys still held from the shortcut, so ⌃⌥⇧ don't join the ⌘V.
            source?.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitSystemDefinedEvents],
                state: .eventSuppressionStateSuppressionInterval
            )
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: isDown)
                event?.flags = .maskCommand
                event?.post(tap: .cgSessionEventTap)
            }
        }
    }
}
