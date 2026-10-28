import SwiftUI

struct TextExtractorSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var languages: [RecognitionLanguage] = []

    var body: some View {
        @Bindable var extractor = state.textExtractor

        CardSection("Extract") {
            if state.permissions.status(.screenRecording) != .granted {
                CardRow("Screen Recording is off", hint: "Needed to read the screen. After allowing it, quit and open \(AppInfo.name) again.") {
                    HStack(spacing: 6) {
                        Button("Open Settings") { state.permissions.openSettings(for: .screenRecording) }
                        Button("Quit & Reopen") { Relaunch.now() }
                    }
                }
            }
            CardRow("Extract text", hint: "Drag over the text to read, or press Space and click a window. Esc cancels.") {
                Button("Extract Text") { Task { await extractor.extract() } }
                    .disabled(extractor.isExtracting)
            }
            ShortcutRow(definition: TextExtractorController.extractShortcut)
        }

        CardSection("Reading") {
            CardRow("Layout", hint: extractor.layout.hint) {
                Picker("Layout", selection: $extractor.layout) {
                    ForEach(TextLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            CardRow("Language", hint: "Choosing one helps with text that isn't in English, such as Chinese or Japanese.") {
                Picker("Language", selection: $extractor.language) {
                    Text("Automatic").tag(String?.none)
                    Divider()
                    ForEach(languages) { language in
                        Text(language.name).tag(Optional(language.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            CardRow("Correct words", hint: "Fixes words read uncertainly. Turn off for code, serial numbers and other text that isn't words.") {
                RowSwitch(label: "Correct words", isOn: $extractor.correctsLanguage)
            }
            CardRow("Read QR codes and barcodes", hint: "What they hold is copied after any text, such as a QR code's link.") {
                RowSwitch(label: "Read QR codes and barcodes", isOn: $extractor.readsCodes)
            }
        }

        CardSection("Recent · \(extractor.history.count)") {
            if extractor.history.isEmpty {
                CardRow("Nothing extracted yet", hint: emptyHint) { EmptyView() }
            } else {
                ForEach(extractor.history) { item in
                    ExtractedRow(item: item)
                }
                CardRow("Clear recent text", hint: "The newest \(TextExtractorController.historyLimit) are kept.") {
                    Button("Clear") { extractor.clearHistory() }
                }
            }
        }
        .task { languages = RecognitionLanguage.all() }
    }

    private var emptyHint: String {
        if state.textExtractor.lastOutcome == .nothingFound {
            return "No text was found in the last region selected."
        }
        if let keys = state.shortcuts.hotKey(for: TextExtractorController.extractShortcut)?.keyCaps.joined() {
            return "Press \(keys) or use the menu bar to read some."
        }
        return "Use Extract Text or the menu bar to read some."
    }
}

private struct ExtractedRow: View {
    let item: ExtractedText

    @Environment(AppState.self) private var state
    @State private var isCopied = false

    var body: some View {
        CardRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(item.date, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
            }
        } trailing: {
            Button {
                state.textExtractor.copy(item)
                isCopied = true
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .task(id: isCopied) {
                guard isCopied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                isCopied = false
            }
        }
        .contextMenu {
            Button("Copy") { state.textExtractor.copy(item) }
            Divider()
            Button("Remove", role: .destructive) { state.textExtractor.remove(item) }
        }
    }
}
