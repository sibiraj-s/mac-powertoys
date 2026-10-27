import Foundation

/// One clipboard entry: text (with optional rich text), an image, or files.
nonisolated struct ClipItem: Identifiable, Codable, Hashable {
    enum RichText: Codable, Hashable {
        case html(String)
        case rtf(Data)
    }

    /// A copied image, stored as PNG in the clipboard image folder.
    struct Image: Codable, Hashable {
        let fileName: String
        let width: Int
        let height: Int
        let byteCount: Int
        /// SHA-256 of the PNG data, so copying the same image again doesn't add it twice.
        let digest: String
    }

    enum Kind: String, CaseIterable {
        case text, link, color, image, files
    }

    var id = UUID()
    /// The text itself; for an image, text recognized in it; for files, their paths, one per line.
    /// This is what search looks at.
    var text: String
    var richText: RichText?
    var image: Image?
    var fileURLs: [URL]?
    var date: Date
    /// The app that was frontmost when this was copied.
    var sourceBundleID: String?
    var isPinned = false

    var kind: Kind {
        if image != nil { return .image }
        if fileURLs != nil { return .files }
        if Self.hexColor(text) != nil { return .color }
        if linkURL != nil { return .link }
        return .text
    }

    /// The web address when the whole text is one.
    var linkURL: URL? {
        guard image == nil, fileURLs == nil else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    /// A single line for lists: whitespace runs collapsed, cut to a sensible length.
    var preview: String {
        text.prefix(400).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What a list row shows.
    var title: String {
        switch kind {
        case .image:
            guard let image else { return "Image" }
            return "Image \(image.width) × \(image.height)"
        case .files:
            let names = fileURLs?.map(\.lastPathComponent) ?? []
            return names.count == 1 ? names[0] : "\(names.count) files: " + names.joined(separator: ", ")
        case .text, .link, .color:
            return preview
        }
    }

    /// A short description of the contents, such as "120 characters · 4 lines" or "1280 × 800 · 1.2 MB".
    var details: String {
        switch kind {
        case .image:
            guard let image else { return "Image" }
            return "\(image.width) × \(image.height) · \(Int64(image.byteCount).formatted(.byteCount(style: .file)))"
        case .files:
            let count = fileURLs?.count ?? 0
            return count == 1 ? "1 file" : "\(count) files"
        case .link:
            return "Link"
        case .color:
            return "Color"
        case .text:
            let characters = text.count
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            let counted = characters == 1 ? "1 character" : "\(characters.formatted()) characters"
            return lines > 1 ? "\(counted) · \(lines.formatted()) lines" : counted
        }
    }

    /// Items with the same key are the same copy.
    var dedupeKey: String {
        if let image { return "image:" + image.digest }
        if let fileURLs { return "files:" + fileURLs.map { $0.path(percentEncoded: false) }.joined(separator: "\n") }
        return "text:" + text
    }

    /// Red, green, blue and alpha from 0 to 1 for "#rgb", "#rrggbb" or "#rrggbbaa".
    static func hexColor(_ text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: #/#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})/#) != nil else { return nil }
        var digits = String(trimmed.dropFirst())
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        if digits.count == 6 {
            digits += "ff"
        }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        return [24, 16, 8, 0].map { Double((value >> $0) & 0xFF) / 255 }
    }
}
