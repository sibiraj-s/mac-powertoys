import SwiftUI

struct ClipboardSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var clipboard = state.clipboard
        let items = clipboard.history.items
        let pinned = items.count { $0.isPinned }

        CardSection("Recent") {
            if items.isEmpty {
                CardRow("Nothing copied yet", hint: emptyHint) {
                    EmptyView()
                }
            }
            ForEach(items.prefix(5)) { item in
                CardRow {
                    HStack(spacing: 10) {
                        ClipIcon(item: item, imageURL: item.image.map(clipboard.imageURL(for:)), size: 24)
                        RowLabel(title: item.title, hint: source(of: item))
                            .lineLimit(1)
                    }
                } trailing: {
                    HStack(spacing: 4) {
                        Button {
                            clipboard.setPinned(item, !item.isPinned)
                        } label: {
                            Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        }
                        .help(item.isPinned ? "Unpin" : "Pin")
                        Button {
                            clipboard.delete(item)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if items.count > 5 {
                CardRow("Open clipboard history", hint: "Search, filter and preview all \(items.count) items.") {
                    Button("Open") { clipboard.showHistory() }
                }
            }
        }

        CardSection("History") {
            CardRow("Keep", hint: "Older items are dropped first.") {
                Picker("Keep", selection: $clipboard.limit) {
                    ForEach(ClipboardController.limits, id: \.self) { limit in
                        Text("\(limit) items").tag(limit)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            CardRow("Remove items", hint: "Clears out old items on its own. Pinned items stay.") {
                Picker("Remove items", selection: $clipboard.itemLifetime) {
                    ForEach(ClipboardController.ItemLifetime.allCases) { lifetime in
                        Text(lifetime.title).tag(lifetime)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            CardRow("Clear history", hint: historySummary(count: items.count, pinned: pinned, imageBytes: clipboard.imageBytes)) {
                Button("Clear") { clipboard.clearHistory() }
                    .disabled(items.count == pinned)
            }
        }

        CardSection("Images") {
            CardRow("Keep images", hint: "Screenshots and copied images. The newest \(ClipboardHistory.maxImages) are kept, plus pinned ones.") {
                RowSwitch(label: "Keep images", isOn: $clipboard.keepsImages)
            }
            CardRow("Make images searchable", hint: "Reads the text in copied images on this Mac, so search finds screenshots.") {
                RowSwitch(label: "Make images searchable", isOn: $clipboard.recognizesText)
            }
            .disabled(!clipboard.keepsImages)
        }

        CardSection("Privacy") {
            CardRow("Skip passwords and concealed items", hint: "Password managers mark what they copy so it isn't kept.") {
                RowSwitch(label: "Skip passwords and concealed items", isOn: $clipboard.skipsConcealed)
            }
            CardRow("Empty the clipboard after", hint: "What ⌘V pastes is emptied this long after you copy it. Your history isn't affected.") {
                Picker("Empty the clipboard after", selection: $clipboard.clearDelay) {
                    ForEach(ClipboardController.ClearDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        CardSection("Shortcuts") {
            ForEach(ClipboardController.Action.allCases) { action in
                ShortcutRow(definition: action.shortcut)
            }
        }

        CardSection("Keys in the panel") {
            ForEach(PasteFormat.allCases) { format in
                CardRow(format == .original ? "Paste" : "Paste as \(format.title)", hint: hint(for: format)) {
                    KeyCaps(keys: format.keyCaps)
                }
            }
            CardRow("Copy, open, show in Finder, save image", hint: "Copy puts an item back on the clipboard without pasting. Open and save work on links, files and images.") {
                KeyCaps(keys: ["⌘C", "⌘O", "⌘R", "⌘S"])
            }
            CardRow("Pin, delete, switch filter", hint: "Pinned items stay when the history is trimmed or cleared.") {
                KeyCaps(keys: ["⌘P", "⌘⌫", "⇥"])
            }
        }
    }

    private var emptyHint: String {
        let opening = state.shortcuts.hotKey(for: ClipboardController.Action.showHistory.shortcut)
            .map { ", then press \($0.keyCaps.joined()) to see them" } ?? ""
        return "Copy text, images or files while Clipboard is on\(opening)."
    }

    private func hint(for format: PasteFormat) -> String {
        guard format == .original, state.permissions.status(.accessibility) != .granted else { return format.hint }
        return "Accessibility is off, so choosing an item only copies it. Press ⌘V to paste."
    }

    private func historySummary(count: Int, pinned: Int, imageBytes: Int) -> String {
        var total = count == 1 ? "1 item" : "\(count) items"
        if pinned > 0 { total += ", \(pinned) pinned" }
        if imageBytes > 0 { total += ", \(Int64(imageBytes).formatted(.byteCount(style: .file))) of images" }
        return "\(total). Stored only on this Mac; pinned items are kept."
    }

    private func source(of item: ClipItem) -> String {
        var parts = [item.details]
        if let app = AppIcons.name(for: item.sourceBundleID) { parts.append(app) }
        parts.append(item.date.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}
