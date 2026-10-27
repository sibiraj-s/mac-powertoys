import SwiftUI


/// The panel's contents: search, filters, the list and the selected item's preview.
struct ClipboardPickerView: View {
    let picker: ClipboardPicker
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var picker = picker
        let results = picker.results

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $picker.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            FilterBar(selection: $picker.filter)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            Divider()

            HStack(spacing: 0) {
                list(results)
                    .frame(width: 320)
                Divider()
                if let item = picker.selected {
                    ClipDetail(item: item, picker: picker)
                } else {
                    Color.clear
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border.opacity(0.6)))
        .onAppear { isSearchFocused = true }
    }

    @ViewBuilder
    private func list(_ results: [ClipItem]) -> some View {
        if results.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { item in
                            ClipRow(item: item, imageURL: imageURL(item), isSelected: item.id == picker.selected?.id)
                                .id(item.id)
                                .onTapGesture(count: 2) { picker.run(.paste(.original)) }
                                .onTapGesture { picker.selectedID = item.id }
                        }
                    }
                    .padding(6)
                    .thinScrollers()
                }
                .onChange(of: picker.selectedID) { _, id in
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private var emptyMessage: String {
        if !picker.query.isEmpty { return "No matches" }
        return switch picker.filter {
        case .all: "Copy something and it shows up here."
        case .pinned: "Pin items with ⌘P to keep them."
        default: "Nothing here yet."
        }
    }

    private func imageURL(_ item: ClipItem) -> URL? {
        item.image.map(picker.controller.imageURL(for:))
    }
}

private struct FilterBar: View {
    @Binding var selection: ClipboardHistory.Filter

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ClipboardHistory.Filter.allCases) { filter in
                Button(filter.title) { selection = filter }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .foregroundStyle(selection == filter ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .background(Capsule().fill(selection == filter ? Color.accentColor : Color.secondary.opacity(0.1)))
            }
            Spacer()
            Text("⇥ to switch")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let imageURL: URL?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ClipIcon(item: item, imageURL: imageURL)
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
            }
            Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }
}

private struct ClipDetail: View {
    let item: ClipItem
    let picker: ClipboardPicker

    var body: some View {
        let commands = ClipCommand.available(for: item)

        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    AppIcon(bundleID: item.sourceBundleID, size: 14)
                    Text(metadata)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(commands.filter(\.isPrimary)) { command in
                        Button { picker.run(command) } label: {
                            HStack(spacing: 4) {
                                Text(command.title(for: item))
                                Text(command.keyCaps.joined()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    let formats = commands.filter(\.isPasteAs)
                    if !formats.isEmpty {
                        Menu("Paste as") {
                            ForEach(formats) { command in
                                Button("\(command.title(for: item))  \(command.keyCaps.joined())") { picker.run(command) }
                            }
                        }
                        .fixedSize()
                    }
                    Spacer(minLength: 0)
                    Button { picker.run(.togglePin) } label: {
                        Image(systemName: item.isPinned ? "pin.slash" : "pin")
                    }
                    .help("\(ClipCommand.togglePin.title(for: item)) (⌘P)")
                    Button { picker.run(.delete) } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete (⌘⌫)")
                }
                .controlSize(.small)
            }
            .padding(12)
        }
    }

    private var metadata: String {
        var parts = [item.details]
        if let app = AppIcons.name(for: item.sourceBundleID) { parts.append(app) }
        parts.append(item.date.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            VStack(alignment: .leading, spacing: 10) {
                if let image = item.image, let preview = Thumbnails.image(at: picker.controller.imageURL(for: image), maxPixels: 900) {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !item.text.isEmpty {
                    Text("Text in image").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(item.text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .thinScrollers()
                    }
                    .frame(maxHeight: 80)
                }
            }
            .padding(12)
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.fileURLs ?? [], id: \.self) { url in
                        FileRow(url: url)
                    }
                }
                .padding(12)
                .thinScrollers()
            }
        case .color:
            let rgba = ClipItem.hexColor(item.text) ?? [0, 0, 0, 1]
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3]))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
                    .frame(height: 120)
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text("rgb(\(rgba.prefix(3).map { String(Int(($0 * 255).rounded())) }.joined(separator: ", ")))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(12)
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                Label(item.linkURL?.host() ?? "Link", systemImage: "link")
                    .font(.system(size: 15, weight: .semibold))
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(12)
        case .text:
            ScrollView {
                Text(String(item.text.prefix(20_000)))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .thinScrollers()
            }
        }
    }
}

private extension ClipCommand {
    /// Shown as buttons; the other paste formats go in the "Paste as" menu.
    var isPrimary: Bool {
        switch self {
        case .paste(let format): format == .original
        case .copy, .open, .reveal, .saveImage: true
        case .togglePin, .delete: false
        }
    }

    var isPasteAs: Bool {
        if case .paste(let format) = self { return format != .original }
        return false
    }
}

private struct FileRow: View {
    let url: URL

    var body: some View {
        let path = url.path(percentEncoded: false)
        let exists = FileManager.default.fileExists(atPath: path)
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(exists ? url.deletingLastPathComponent().path(percentEncoded: false) : "No longer there")
                    .font(.system(size: 10))
                    .foregroundStyle(exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .opacity(exists ? 1 : 0.6)
    }
}
