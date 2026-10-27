import Observation

/// Search, filter and selection for one showing of the panel.
@Observable
final class ClipboardPicker {
    var query = "" {
        didSet { selectedID = results.first?.id }
    }
    var filter: ClipboardHistory.Filter = .all {
        didSet { selectedID = results.first?.id }
    }
    var selectedID: ClipItem.ID?

    let controller: ClipboardController

    init(controller: ClipboardController) {
        self.controller = controller
        selectedID = results.first?.id
    }

    var results: [ClipItem] { controller.history.matching(query, filter: filter) }

    var selected: ClipItem? {
        let results = results
        return results.first { $0.id == selectedID } ?? results.first
    }

    func move(by step: Int) {
        let results = results
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? 0
        selectedID = results[min(max(current + step, 0), results.count - 1)].id
    }

    func cycleFilter(by step: Int) {
        let filters = ClipboardHistory.Filter.allCases
        let current = filters.firstIndex(of: filter) ?? 0
        filter = filters[(current + step + filters.count) % filters.count]
    }

    /// Runs `command` on the selected item; false when it doesn't apply.
    @discardableResult
    func run(_ command: ClipCommand) -> Bool {
        guard let item = selected, ClipCommand.available(for: item).contains(command) else { return false }
        switch command {
        case .paste(let format): controller.paste(item, as: format)
        case .copy: controller.copy(item)
        case .open: controller.open(item)
        case .reveal: controller.revealInFinder(item)
        case .saveImage: controller.saveImageToDownloads(item)
        case .togglePin: controller.setPinned(item, !item.isPinned)
        case .delete:
            move(by: 1)
            if selectedID == item.id { move(by: -1) }
            controller.delete(item)
        }
        return true
    }
}
