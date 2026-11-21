import AppKit

/// What gets put on the pasteboard when an item is pasted or copied.
enum PasteContents: Equatable {
    case text(String, rich: ClipItem.RichText? = nil)
    /// A stored image, by file name in the clipboard image folder.
    case image(fileName: String)
    case files([URL])
}

enum PasteFormat: CaseIterable, Identifiable {
    case original, plainText, markdown, json

    var id: Self { self }

    var title: String {
        switch self {
        case .original: "Paste"
        case .plainText: "Plain text"
        case .markdown: "Markdown"
        case .json: "JSON"
        }
    }

    var hint: String {
        switch self {
        case .original: "Keeps the formatting it was copied with."
        case .plainText: "Drops fonts, colors and links so it matches where it lands."
        case .markdown: "Turns rich text from browsers and documents into Markdown."
        case .json: "Formats JSON, or turns CSV and TSV tables into JSON."
        }
    }

    /// The keys that pick this format in the clipboard history panel.
    var keyCaps: [String] {
        switch self {
        case .original: ["↩"]
        case .plainText: ["⇧", "↩"]
        case .markdown: ["⌘", "M"]
        case .json: ["⌘", "J"]
        }
    }

    /// Whether this format is worth offering for the item. Cheap enough to call while drawing.
    func applies(to item: ClipItem) -> Bool {
        switch self {
        case .original:
            true
        case .plainText:
            // Plain text that's already plain is the same as pasting it.
            item.richText != nil || item.fileURLs != nil || (item.image != nil && !item.text.isEmpty)
        case .markdown:
            item.richText != nil
        case .json:
            item.kind == .text && item.text.utf16.count <= 50_000 && PasteTransform.json(from: item.text) != nil
        }
    }

    /// The item converted to this format, or nil when it doesn't apply (Markdown needs rich text,
    /// JSON needs JSON or a table). Plain text of an image is the text recognized in it, and of
    /// files their paths.
    func contents(of item: ClipItem) -> PasteContents? {
        switch (self, item.kind) {
        case (.original, .image):
            item.image.map { .image(fileName: $0.fileName) }
        case (.original, .files):
            item.fileURLs.map { .files($0) }
        case (.original, _):
            .text(item.text, rich: item.richText)
        case (.plainText, _):
            item.text.isEmpty ? nil : .text(item.text)
        case (.markdown, _):
            item.richText?.attributedString.map { .text(PasteTransform.markdown(from: $0)) }
        case (.json, .text):
            PasteTransform.json(from: item.text).map { .text($0) }
        case (.json, _):
            nil
        }
    }
}

/// Something you can do with the selected item in the clipboard panel.
enum ClipCommand: Hashable, Identifiable {
    case paste(PasteFormat)
    /// Typed out key by key, for fields that block pasting.
    case type
    case copy, open, reveal, saveImage, togglePin, delete

    var id: Self { self }

    /// What applies to `item`, in the order the panel shows them.
    static func available(for item: ClipItem) -> [ClipCommand] {
        var commands = PasteFormat.allCases.filter { $0.applies(to: item) }.map(ClipCommand.paste)
        if item.typedText != nil { commands.append(.type) }
        commands.append(.copy)
        switch item.kind {
        case .link: commands.append(.open)
        case .files: commands += [.open, .reveal]
        case .image: commands += [.open, .saveImage]
        case .text, .color: break
        }
        return commands + [.togglePin, .delete]
    }

    func title(for item: ClipItem) -> String {
        switch self {
        case .paste(.plainText) where item.kind == .image: "Paste text"
        case .paste(.plainText) where item.kind == .files: "Paste paths"
        case .paste(let format): format == .original ? "Paste" : "Paste as \(format.title)"
        case .type: "Type"
        case .copy: "Copy"
        case .open: item.kind == .link ? "Open link" : "Open"
        case .reveal: "Show in Finder"
        case .saveImage: "Save to Downloads"
        case .togglePin: item.isPinned ? "Unpin" : "Pin"
        case .delete: "Delete"
        }
    }

    var keyCaps: [String] {
        switch self {
        case .paste(let format): format.keyCaps
        case .type: ["⌘", "T"]
        case .copy: ["⌘", "C"]
        case .open: ["⌘", "O"]
        case .reveal: ["⌘", "R"]
        case .saveImage: ["⌘", "S"]
        case .togglePin: ["⌘", "P"]
        case .delete: ["⌘", "⌫"]
        }
    }
}

extension ClipItem {
    /// Longer text would take minutes to type, a key at a time.
    static let maxTypedLength = 10_000

    /// The text typed out for this item; nil when there's nothing worth typing: images, files,
    /// blank text, or text too long to type.
    var typedText: String? {
        switch kind {
        case .text, .link, .color:
            // The UTF-16 count is cheap, and this runs while the panel draws.
            guard text.utf16.count <= Self.maxTypedLength, text.contains(where: \.isTypable) else { return nil }
            return text
        case .image, .files:
            return nil
        }
    }
}

extension Character {
    /// Shows up when typed: not a space, line break or control character.
    fileprivate var isTypable: Bool {
        !isWhitespace && !unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
    }
}
