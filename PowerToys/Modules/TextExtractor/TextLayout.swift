import CoreGraphics
import Foundation

/// How the lines read off the screen are put together into the copied text.
nonisolated enum TextLayout: String, CaseIterable, Identifiable, Sendable {
    /// One line of text per line on screen.
    case lines
    /// Lines joined into paragraphs, which break where there's a gap or the text jumps back up,
    /// such as to the next column.
    case paragraphs
    /// Everything on one line, for search fields and the like.
    case singleLine

    var id: Self { self }

    var title: String {
        switch self {
        case .lines: "Keep line breaks"
        case .paragraphs: "Join into paragraphs"
        case .singleLine: "One line"
        }
    }

    var hint: String {
        switch self {
        case .lines: "Each row of text on screen is a line."
        case .paragraphs: "Lines are joined, with a line break where a paragraph or column ends."
        case .singleLine: "All the text on one line."
        }
    }

    /// A gap between lines this many times the shorter line's height starts a new paragraph.
    static let paragraphGap: CGFloat = 0.75

    func join(_ lines: [RecognizedLine]) -> String {
        let lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        switch self {
        case .lines:
            // Pieces Vision read apart on one row, such as a label and its value, stay one line.
            return lines.indices.reduce("") { text, index in
                guard index > 0 else { return lines[index].text }
                return text + (Self.sameRow(lines[index], lines[index - 1]) ? " " : "\n") + lines[index].text
            }
        case .singleLine:
            return lines.reduce("") { Self.append($1.text, to: $0) }
        case .paragraphs:
            var text = ""
            for (index, line) in lines.enumerated() {
                if index > 0, Self.startsParagraph(line, after: lines[index - 1]) {
                    text += "\n" + line.text
                } else {
                    text = Self.append(line.text, to: text)
                }
            }
            return text
        }
    }

    /// Whether `line` begins a new paragraph rather than continuing `previous`.
    static func startsParagraph(_ line: RecognizedLine, after previous: RecognizedLine) -> Bool {
        let height = min(line.bounds.height, previous.bounds.height)
        // Bounds have their origin at the bottom, so a line below has a smaller y.
        let gap = previous.bounds.minY - line.bounds.maxY
        // On the same row, as when Vision reads a label and its value, or table cells, apart.
        if sameRow(line, previous) { return false }
        // Back up the page, as at the top of the next column.
        if line.bounds.midY > previous.bounds.maxY { return true }
        return gap > height * paragraphGap
    }

    /// Whether the two overlap by more than half the shorter one's height.
    static func sameRow(_ a: RecognizedLine, _ b: RecognizedLine) -> Bool {
        let overlap = min(a.bounds.maxY, b.bounds.maxY) - max(a.bounds.minY, b.bounds.minY)
        return overlap > min(a.bounds.height, b.bounds.height) / 2
    }

    /// `next` after `text` with a space between, or joined back up when `text` ends in a word
    /// broken with a hyphen.
    static func append(_ next: String, to text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        let next = next.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return next }
        if text.hasSuffix("-"), text.dropLast().last?.isLetter == true, next.first?.isLowercase == true {
            return text.dropLast() + next
        }
        return text + " " + next
    }
}

/// A language text can be read in, as the settings list it.
nonisolated struct RecognitionLanguage: Identifiable, Hashable, Sendable {
    /// A full BCP 47 code, such as "zh-Hans-CN", which Vision takes back as is.
    let id: String
    let name: String

    /// Vision's languages by name.
    static func all(_ identifiers: [String] = TextRecognizer.supportedLanguages, locale: Locale = .current) -> [RecognitionLanguage] {
        let languages = identifiers.map(Locale.Language.init(identifier:))
        let codes = languages.compactMap { $0.languageCode?.identifier }
        return zip(identifiers, languages).map { id, language in
            let code = language.languageCode?.identifier ?? id
            // Named with the script, such as "Chinese, Simplified", only where it tells them apart.
            let shared = codes.count { $0 == code } > 1
            let named = shared ? language.script.map { "\(code)-\($0.identifier)" } ?? code : code
            return RecognitionLanguage(id: id, name: locale.localizedString(forIdentifier: named) ?? id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
