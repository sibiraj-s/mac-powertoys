import AppKit
import SwiftUI

struct BatchRenameSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var isTargeted = false

    /// Rows past this many aren't drawn; renaming still covers every file.
    private static let shownLimit = 200

    var body: some View {
        @Bindable var renamer = state.batchRename
        let preview = renamer.preview
        let previews = (try? preview.get()) ?? []
        let changed = previews.filter(\.isChanged)
        let problems = previews.filter { $0.problem != nil }.count

        CardSection("Rename") {
            CardRow("Find", hint: "Leave empty to replace the whole name.") {
                TextField("Find", text: $renamer.rule.find)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: renamer.rule.usesRegex ? .monospaced : .default))
                    .frame(width: 280)
                    .labelsHidden()
            }
            CardRow("Replace with", hint: replaceHint) {
                TextField("Replace with", text: $renamer.rule.replace)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 280)
                    .labelsHidden()
            }
            CardRow("Regular expression", hint: "Patterns such as IMG_(\\d+), with $1 for groups in the replacement.") {
                RowSwitch(label: "Regular expression", isOn: $renamer.rule.usesRegex)
            }
            CardRow("Match case") {
                RowSwitch(label: "Match case", isOn: $renamer.rule.matchesCase)
            }
            CardRow("Include the extension", hint: "Otherwise only the part before the last dot changes.") {
                RowSwitch(label: "Include the extension", isOn: $renamer.rule.includesExtension)
            }
            CardRow("Case") {
                Picker("Case", selection: $renamer.rule.textCase) {
                    ForEach(RenameRule.TextCase.allCases) { textCase in
                        Text(textCase.title).tag(textCase)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            CardRow("Numbering", hint: "{n} counts from this number, padded with zeros to this many digits.") {
                HStack(spacing: 8) {
                    TextField("Start", value: $renamer.rule.counterStart, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .labelsHidden()
                    Picker("Digits", selection: $renamer.rule.counterDigits) {
                        ForEach(1...5, id: \.self) { digits in
                            Text(String(repeating: "0", count: digits - 1) + "1").tag(digits)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionTitle(renamer.items.isEmpty ? "Files" : "Files · \(renamer.items.count)")
                Spacer()
                Button("Add Files…") { chooseFiles() }
                Button("Finder Selection") { Task { await renamer.addFinderSelection() } }
                    .help("Adds what's selected in Finder.")
                if !renamer.items.isEmpty {
                    Button("Clear") { renamer.clear() }
                }
            }
            .controlSize(.small)

            if case .failure(let error) = preview {
                MessageBanner(message: error.errorDescription ?? "", isError: true, dismiss: nil)
            }
            if let message = renamer.message {
                MessageBanner(message: message, isError: renamer.isError, dismiss: { renamer.clearMessage() })
            }

            CardSection {
                if renamer.items.isEmpty {
                    CardRow(
                        "Drop files or folders here",
                        hint: "Or add them with Add Files…, or select them in Finder and use Finder Selection."
                    ) {
                        Image(systemName: "tray.and.arrow.down").foregroundStyle(Palette.secondaryText)
                    }
                } else {
                    ForEach(previews.prefix(Self.shownLimit)) { preview in
                        RenameRow(preview: preview)
                    }
                    if previews.count > Self.shownLimit {
                        CardRow("\(previews.count - Self.shownLimit) more not shown", hint: "They're renamed too.") { EmptyView() }
                    }
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                renamer.add(urls)
                return !urls.isEmpty
            } isTargeted: {
                isTargeted = $0
            }

            HStack(spacing: 10) {
                if problems > 0 {
                    Label("\(problems) name\(problems == 1 ? "" : "s") can't be used", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !renamer.lastRename.isEmpty {
                    Button("Undo Rename") { renamer.undo() }
                        .help("Gives the last renamed files their old names back.")
                }
                Button("Rename \(changed.count) File\(changed.count == 1 ? "" : "s")") { renamer.apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(changed.isEmpty || problems > 0)
            }
            .padding(.top, 4)
        }
    }

    private var replaceHint: String {
        "{name} is the old name, {n} a number, {date} the date a photo was taken, or the file was made."
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        state.batchRename.add(panel.urls)
    }
}

/// Old name and new name, with why the new one can't be used.
private struct RenameRow: View {
    let preview: RenamePreview

    @Environment(AppState.self) private var state

    var body: some View {
        CardRow {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(preview.oldName)
                        .foregroundStyle(preview.isChanged ? Palette.secondaryText : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if preview.isChanged {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.secondaryText)
                        Text(preview.newName)
                            .foregroundStyle(preview.problem == nil ? Color.primary : Color.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 12))
                if let problem = preview.problem {
                    Text(problem.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .help(preview.url.path(percentEncoded: false))
        } trailing: {
            Button {
                state.batchRename.remove(preview.url)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Palette.secondaryText)
            }
            .buttonStyle(.borderless)
            .help("Leave this file out")
        }
    }
}
