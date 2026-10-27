import Foundation

/// Clipboard entries, newest first. Pinned items are kept when the history is trimmed or cleared.
nonisolated struct ClipboardHistory: Codable, Equatable {
    enum Filter: CaseIterable, Identifiable {
        case all, pinned, text, links, images, files

        var id: Self { self }

        var title: String {
            switch self {
            case .all: "All"
            case .pinned: "Pinned"
            case .text: "Text"
            case .links: "Links"
            case .images: "Images"
            case .files: "Files"
            }
        }

        func includes(_ item: ClipItem) -> Bool {
            switch self {
            case .all: true
            case .pinned: item.isPinned
            case .text: item.kind == .text || item.kind == .color
            case .links: item.kind == .link
            case .images: item.kind == .image
            case .files: item.kind == .files
            }
        }
    }

    /// Images are large, so fewer of them are kept than other items.
    static let maxImages = 50

    private(set) var items: [ClipItem] = []

    /// Adds an item to the top. Copying the same thing again moves the earlier entry up instead
    /// of duplicating it, and keeps it pinned if it was.
    mutating func record(_ item: ClipItem, limit: Int) {
        var item = item
        if let existing = items.firstIndex(where: { $0.dedupeKey == item.dedupeKey }) {
            item.id = items[existing].id
            item.isPinned = items[existing].isPinned
            if item.text.isEmpty {
                item.text = items[existing].text
            }
            items.remove(at: existing)
        }
        items.insert(item, at: 0)
        trim(to: limit)
    }

    /// Drops the oldest unpinned items beyond `limit`, and unpinned images beyond `maxImages`.
    mutating func trim(to limit: Int) {
        var unpinned = 0
        var images = 0
        items = items.filter { item in
            if item.isPinned { return true }
            unpinned += 1
            if item.image != nil {
                images += 1
                if images > Self.maxImages { return false }
            }
            return unpinned <= limit
        }
    }

    /// Moves an item to the top, as if it had just been copied.
    mutating func touch(_ id: ClipItem.ID, at date: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.date = date
        items.insert(item, at: 0)
    }

    mutating func setPinned(_ id: ClipItem.ID, _ isPinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned = isPinned
    }

    /// Sets an image's recognized text.
    mutating func setText(_ id: ClipItem.ID, _ text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text = text
    }

    mutating func remove(_ id: ClipItem.ID) {
        items.removeAll { $0.id == id }
    }

    /// Removes unpinned items copied before `date`. Returns whether anything went.
    @discardableResult
    mutating func removeItems(copiedBefore date: Date) -> Bool {
        let count = items.count
        items.removeAll { !$0.isPinned && $0.date < date }
        return items.count != count
    }

    /// Removes everything except pinned items.
    mutating func clear() {
        items.removeAll { !$0.isPinned }
    }

    /// Items in `filter` containing every word of `query`, pinned first, then newest first.
    func matching(_ query: String, filter: Filter = .all) -> [ClipItem] {
        let words = query.split(whereSeparator: \.isWhitespace)
        let found = items.filter { item in
            filter.includes(item) && words.allSatisfy { item.text.localizedStandardContains($0) }
        }
        return found.filter(\.isPinned) + found.filter { !$0.isPinned }
    }
}
