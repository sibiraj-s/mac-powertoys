import Foundation
import ImageIO
import Observation

/// The files to rename, the rule for their new names, and the last rename, kept for undo.
@Observable
final class BatchRenameController {
    private(set) var items: [URL] = [] {
        didSet { refreshPreview() }
    }
    var rule: RenameRule {
        didSet {
            save()
            refreshPreview()
        }
    }
    /// The new names, or a message about the rule, such as a pattern that doesn't compile. Kept
    /// rather than worked out on every redraw, which checks the disk for each file.
    private(set) var preview: Result<[RenamePreview], CommandError> = .success([])
    /// The last rename, which can be undone while its files are still where it left them.
    private(set) var lastRename: [FileRenamer.Move] = []
    private(set) var message: String?
    private(set) var isError = false

    static let ruleKey = "batchRename.rule"

    private let defaults: UserDefaults
    @ObservationIgnored private let finder: any FinderAccess
    @ObservationIgnored private let fileManager: FileManager
    /// Dates by file, read once, since reading photos' dates for every keystroke is wasteful.
    @ObservationIgnored private var dates: [URL: Date?] = [:]

    init(defaults: UserDefaults = .standard, finder: any FinderAccess = LiveFinder(), fileManager: FileManager = .default) {
        self.defaults = defaults
        self.finder = finder
        self.fileManager = fileManager
        rule = defaults.data(forKey: Self.ruleKey).flatMap { try? JSONDecoder().decode(RenameRule.self, from: $0) } ?? RenameRule()
        refreshPreview()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(rule), forKey: Self.ruleKey)
    }

    // MARK: Files

    /// Adds files not already in the list, sorted by name as Finder does, after those there.
    func add(_ urls: [URL]) {
        let known = Set(items.map(\.standardizedFileURL))
        let new = Set(urls.map(\.standardizedFileURL)).subtracting(known)
            .filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        items += new
        clearMessage()
    }

    func addFinderSelection() async {
        do {
            let selection = try await finder.selection()
            if selection.isEmpty {
                show("Nothing is selected in Finder.", isError: true)
            } else {
                add(selection)
            }
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
    }

    func clear() {
        items.removeAll()
        clearMessage()
    }

    // MARK: Renaming

    private func refreshPreview() {
        preview = makePreview()
    }

    private func makePreview() -> Result<[RenamePreview], CommandError> {
        do {
            return .success(
                try RenamePreview.plan(
                    items, rule: rule, date: date(of:),
                    exists: { [fileManager] in fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }))
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(CommandError(errorDescription: error.localizedDescription))
        }
    }

    /// Renames every file whose name changes, or none if any can't be.
    func apply() {
        // Checked again, since files may have appeared or gone since the list last changed.
        refreshPreview()
        guard case .success(let previews) = preview else { return }
        guard !previews.contains(where: { $0.problem != nil }) else {
            show("Fix the names marked in the list first.", isError: true)
            return
        }
        let moves = previews.filter(\.isChanged).map { FileRenamer.Move(from: $0.url, to: $0.destination) }
        guard !moves.isEmpty else { return }
        do {
            try FileRenamer.rename(moves, fileManager: fileManager)
        } catch {
            show("Nothing was renamed: \(error.localizedDescription)", isError: true)
            return
        }
        lastRename = moves
        replace(moves)
        show("Renamed \(moves.count) file\(moves.count == 1 ? "" : "s").", isError: false)
    }

    /// Puts the last rename's files back under their old names.
    func undo() {
        let moves = lastRename.map { FileRenamer.Move(from: $0.to, to: $0.from) }
        guard !moves.isEmpty else { return }
        do {
            try FileRenamer.rename(moves, fileManager: fileManager)
        } catch {
            show("Couldn't undo: \(error.localizedDescription)", isError: true)
            return
        }
        lastRename = []
        replace(moves)
        show("Restored \(moves.count) name\(moves.count == 1 ? "" : "s").", isError: false)
    }

    /// Follows renamed files in the list, so the next rule applies to them as they are now.
    private func replace(_ moves: [FileRenamer.Move]) {
        let renamed = Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { first, _ in first })
        dates = dates.reduce(into: [:]) { result, entry in result[renamed[entry.key] ?? entry.key] = entry.value }
        // After the dates, so the new preview finds them under the new names.
        items = items.map { renamed[$0] ?? $0 }
    }

    func clearMessage() {
        message = nil
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        self.isError = isError
    }

    // MARK: Dates

    private func date(of url: URL) -> Date? {
        if let known = dates[url] { return known }
        let date = Self.photoDate(of: url) ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
        dates[url] = date
        return date
    }

    /// When a photo was taken, from its EXIF data, which records the camera's local time.
    nonisolated static func photoDate(of url: URL, timeZone: TimeZone = .current) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return parseExifDate(text, timeZone: timeZone)
    }

    /// "2024:07:14 18:30:05", the form EXIF dates take.
    nonisolated static func parseExifDate(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let numbers = text.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard numbers.count == 6 else { return nil }
        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: timeZone,
            year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4], second: numbers[5])
        return components.isValidDate ? components.date : nil
    }
}
