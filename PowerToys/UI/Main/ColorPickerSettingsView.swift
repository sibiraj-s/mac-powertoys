import SwiftUI

struct ColorPickerSettingsView: View {
    @Environment(AppState.self) private var state
    /// The recent color shown with all its formats; the latest one when nil.
    @State private var selectedID: PickedColor.ID?

    private let columns = [GridItem(.adaptive(minimum: 28, maximum: 28), spacing: 8)]

    var body: some View {
        @Bindable var picker = state.colorPicker
        let selected = picker.history.first { $0.id == selectedID } ?? picker.latest

        CardSection("Pick") {
            CardRow("Pick a color", hint: "Click anywhere on screen to pick the color under the magnifier. Esc cancels.") {
                Button("Pick Color") { Task { await picker.pick() } }
                    .disabled(picker.isPicking)
            }
            ShortcutRow(definition: ColorPickerController.pickShortcut)
        }

        CardSection("Copy") {
            CardRow("Copy when picked", hint: "Puts the color on the clipboard as soon as you pick it.") {
                RowSwitch(label: "Copy when picked", isOn: $picker.copiesOnPick)
            }
            CardRow("Format", hint: (selected ?? PickedColor(red: 0.2, green: 0.6, blue: 0.86)).formatted(as: picker.format)) {
                Picker("Format", selection: $picker.format) {
                    ForEach(ColorFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        if let selected {
            CardSection(selected.id == picker.latest?.id ? "Latest" : "Selected") {
                CardRow {
                    HStack(spacing: 12) {
                        Swatch(color: selected, size: 36)
                        RowLabel(title: selected.hex, hint: "sRGB")
                    }
                } trailing: {
                    EmptyView()
                }
                ForEach(ColorFormat.allCases) { format in
                    FormatRow(color: selected, format: format)
                }
            }
        }

        CardSection("Recent · \(picker.history.count)") {
            if picker.history.isEmpty {
                CardRow("Nothing picked yet", hint: emptyHint) { EmptyView() }
            } else {
                CardRow {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(picker.history) { color in
                            Button {
                                selectedID = color.id
                            } label: {
                                Swatch(color: color, size: 28, isSelected: color.id == selected?.id)
                            }
                            .buttonStyle(.plain)
                            .help(color.hex)
                            .contextMenu {
                                ForEach(ColorFormat.allCases) { format in
                                    Button("Copy as \(format.title)") { picker.copy(color, as: format) }
                                }
                                Divider()
                                Button("Remove", role: .destructive) { picker.remove(color) }
                            }
                        }
                    }
                } trailing: {
                    EmptyView()
                }
                CardRow("Clear recent colors", hint: "The newest \(ColorPickerController.historyLimit) are kept.") {
                    Button("Clear") {
                        selectedID = nil
                        picker.clearHistory()
                    }
                }
            }
        }
        .onChange(of: picker.latest) { selectedID = nil }
    }

    private var emptyHint: String {
        if let keys = state.shortcuts.hotKey(for: ColorPickerController.pickShortcut)?.keyCaps.joined() {
            return "Press \(keys) or use the menu bar to pick one."
        }
        return "Use Pick Color or the menu bar to pick one."
    }
}

private struct FormatRow: View {
    let color: PickedColor
    let format: ColorFormat

    @Environment(AppState.self) private var state
    @State private var isCopied = false

    var body: some View {
        let text = color.formatted(as: format)
        CardRow {
            HStack(spacing: 10) {
                Text(format.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 56, alignment: .leading)
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } trailing: {
            Button {
                state.colorPicker.copy(color, as: format)
                isCopied = true
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help("Copy \(text)")
            .task(id: isCopied) {
                guard isCopied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                isCopied = false
            }
        }
    }
}

/// A rounded square of the color, outlined so white and black still show on any background.
struct Swatch: View {
    let color: PickedColor
    let size: CGFloat
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(color.swiftUIColor)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size / 4).strokeBorder(Color.primary.opacity(0.15)))
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(color.isLight ? Color.black : Color.white)
                }
            }
            .accessibilityLabel(color.hex)
    }
}

extension PickedColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}
