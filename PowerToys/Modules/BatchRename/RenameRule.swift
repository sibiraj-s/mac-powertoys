import Foundation

/// How each file's new name is made from its old one.
nonisolated struct RenameRule: Codable, Equatable, Sendable {
    /// Text or pattern to find. Empty means the whole name is replaced.
    var find = ""
    /// What replaces it, with tokens: {name} the old name, {n} the file's number, {date} the date
    /// the photo was taken or the file was made. Regex replacements can use $1 for groups.
    var replace = ""
    var usesRegex = false
    var matchesCase = false
    /// Rename the extension too, rather than only the part before it.
    var includesExtension = false
    var textCase: TextCase = .unchanged
    var counterStart = 1
    /// Numbers are padded with zeros to this many digits.
    var counterDigits = 1

    enum TextCase: String, Codable, CaseIterable, Identifiable, Sendable {
        case unchanged, lowercase, uppercase, titleCase

        var id: Self { self }

        var title: String {
            switch self {
            case .unchanged: "Unchanged"
            case .lowercase: "lowercase"
            case .uppercase: "UPPERCASE"
            case .titleCase: "Title Case"
            }
        }

        func apply(to text: String) -> String {
            switch self {
            case .unchanged: text
            case .lowercase: text.lowercased()
            case .uppercase: text.uppercased()
            case .titleCase: text.localizedCapitalized
            }
        }
    }

    static let tokens = ["{name}", "{n}", "{date}"]

    var usesDate: Bool { replace.contains("{date}") }

    /// Changes nothing, so every name stays as it is.
    var isEmpty: Bool { find.isEmpty && replace.isEmpty && textCase == .unchanged }

    /// The compiled pattern, or a message about why it doesn't compile.
    func regex() throws -> NSRegularExpression? {
        guard usesRegex, !find.isEmpty else { return nil }
        do {
            return try NSRegularExpression(pattern: find, options: matchesCase ? [] : .caseInsensitive)
        } catch {
            throw CommandError(errorDescription: "The pattern isn't a valid regular expression.")
        }
    }

    /// The new name for the file called `name`, the `index`th in the list from 0. Pass `regex()`.
    func newName(for name: String, index: Int, date: Date?, regex: NSRegularExpression?) -> String {
        let (base, ext) = includesExtension ? (name, "") : Self.split(name)
        var result: String
        if find.isEmpty {
            result = replace.isEmpty ? base : expand(replace, base: base, index: index, date: date, forTemplate: false)
        } else if let regex {
            let template = expand(replace, base: base, index: index, date: date, forTemplate: true)
            result = regex.stringByReplacingMatches(
                in: base, range: NSRange(base.startIndex..., in: base), withTemplate: template)
        } else {
            let replacement = expand(replace, base: base, index: index, date: date, forTemplate: false)
            result = base.replacingOccurrences(of: find, with: replacement, options: matchesCase ? [] : .caseInsensitive)
        }
        result = textCase.apply(to: result)
        return ext.isEmpty ? result : "\(result).\(ext)"
    }

    /// Fills in the tokens. Their values are escaped in a regex template so a `$` or `\` in a
    /// file name isn't read as a group reference, while the user's own `$1` still is.
    private func expand(_ text: String, base: String, index: Int, date: Date?, forTemplate: Bool) -> String {
        let escape = { (value: String) in forTemplate ? NSRegularExpression.escapedTemplate(for: value) : value }
        let number = String(counterStart + index)
        let padded = String(repeating: "0", count: max(0, counterDigits - number.count)) + number
        return
            text
            .replacing("{name}", with: escape(base))
            .replacing("{n}", with: padded)
            .replacing("{date}", with: date.map { Self.format($0) } ?? "")
    }

    /// "2026-11-08", in local time, as photos record when they were taken.
    static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let day = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// "photo.final" and "jpg" for "photo.final.jpg". Names starting with a dot, such as
    /// ".zshrc", have no extension unless another dot follows.
    static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}

/// One file's rename, as it will happen.
nonisolated struct RenamePreview: Identifiable, Equatable, Sendable {
    let url: URL
    let newName: String
    var problem: Problem?

    var id: URL { url }
    var oldName: String { url.lastPathComponent }
    var isChanged: Bool { newName != oldName }
    var destination: URL { url.deletingLastPathComponent().appending(path: newName) }

    enum Problem: Equatable, Sendable {
        case empty, invalidCharacter, tooLong, duplicate, exists, insideRenamedFolder

        var message: String {
            switch self {
            case .empty: "The name would be empty."
            case .invalidCharacter: "Names can't contain / or :."
            case .tooLong: "The name is too long."
            case .duplicate: "Another file here would get the same name."
            case .exists: "A file with this name is already here."
            case .insideRenamedFolder: "Its folder is being renamed too. Rename them one at a time."
            }
        }
    }

    /// The renames for `urls` in order, each checked against the others and the disk. Names are
    /// compared ignoring case, as Mac disks do.
    static func plan(
        _ urls: [URL], rule: RenameRule, date: (URL) -> Date?, exists: (URL) -> Bool
    ) throws -> [RenamePreview] {
        let regex = try rule.regex()
        var previews = urls.enumerated().map { index, url in
            let name = url.lastPathComponent
            let new = rule.newName(for: name, index: index, date: rule.usesDate ? date(url) : nil, regex: regex)
            return RenamePreview(url: url, newName: new)
        }
        let sources = Set(urls.map(key))
        // Folders are moved before what's inside them, which would then not be found.
        let renamedFolders = Set(previews.filter(\.isChanged).map { key($0.url) })
        func isInsideRenamedFolder(_ url: URL) -> Bool {
            guard !renamedFolders.isEmpty else { return false }
            var parent = url.standardizedFileURL.deletingLastPathComponent()
            while parent.path(percentEncoded: false) != "/" {
                if renamedFolders.contains(key(parent)) { return true }
                parent = parent.deletingLastPathComponent()
            }
            return false
        }
        let targets = Dictionary(grouping: previews.map { key($0.destination) }, by: { $0 }).mapValues(\.count)
        for index in previews.indices where previews[index].isChanged || isInsideRenamedFolder(previews[index].url) {
            let preview = previews[index]
            if isInsideRenamedFolder(preview.url) {
                previews[index].problem = .insideRenamedFolder
                continue
            }
            let name = preview.newName
            // The part before the kept extension: removing all of "a" from "a.txt" leaves none.
            let ext = rule.includesExtension ? "" : RenameRule.split(preview.oldName).ext
            let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
            if base.trimmingCharacters(in: .whitespaces).isEmpty || name == "." || name == ".." {
                previews[index].problem = .empty
            } else if name.contains("/") || name.contains(":") {
                previews[index].problem = .invalidCharacter
            } else if name.utf8.count > 255 {
                previews[index].problem = .tooLong
            } else if targets[key(preview.destination), default: 0] > 1 {
                previews[index].problem = .duplicate
            } else if !sources.contains(key(preview.destination)), exists(preview.destination) {
                // A file in the list is moved out of the way first, so its name is free.
                previews[index].problem = .exists
            }
        }
        return previews
    }

    /// A folder's URL may end in "/" and its destination doesn't, so the slash is dropped.
    static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// Renames files in two steps, through temporary names, so files can swap names and names can
/// change only in case. If any rename fails, those done are undone.
nonisolated enum FileRenamer {
    struct Move: Equatable, Sendable {
        let from: URL
        let to: URL
    }

    static func rename(_ moves: [Move], fileManager: FileManager = .default) throws {
        var staged: [(temporary: URL, move: Move)] = []
        var finished = 0
        do {
            for move in moves {
                let temporary = move.from.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).renaming")
                try fileManager.moveItem(at: move.from, to: temporary)
                staged.append((temporary, move))
            }
            for (temporary, move) in staged {
                // moveItem won't replace a file, so one that appeared since the preview stays.
                try fileManager.moveItem(at: temporary, to: move.to)
                finished += 1
            }
        } catch {
            for (index, entry) in staged.enumerated().reversed() {
                if index < finished { try? fileManager.moveItem(at: entry.move.to, to: entry.temporary) }
                try? fileManager.moveItem(at: entry.temporary, to: entry.move.from)
            }
            throw error
        }
    }
}
