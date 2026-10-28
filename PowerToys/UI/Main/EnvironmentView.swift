import AppKit
import SwiftUI

/// PATH and the variables a new shell, or an app, starts with.
struct EnvironmentView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var revealed: Set<String> = []

    var body: some View {
        @Bindable var environment = state.environment
        let source = environment.selected

        VStack(alignment: .leading, spacing: Page<EmptyView>.sectionSpacing) {
            CardSection {
                CardRow("Environment of", hint: hint(for: source)) {
                    HStack(spacing: 8) {
                        if environment.isLoading {
                            ProgressView().controlSize(.small)
                        }
                        Picker("Environment of", selection: $environment.selected) {
                            ForEach(environment.sources) { Text(title(for: $0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            Task { await environment.load(source, force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Read again")
                        .disabled(environment.isLoading)
                    }
                }
                if let error = environment.error {
                    CardRow {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    } trailing: {
                        EmptyView()
                    }
                }
            }

            if let snapshot = environment.snapshot {
                pathSection(snapshot.path)
                variablesSection(snapshot.variables)
            }
        }
        .task(id: source) { await environment.load(source) }
    }

    private func pathSection(_ path: [PathEntry]) -> some View {
        let problems = path.count { $0.problem != nil }
        let title = problems == 0 ? "PATH" : "PATH · \(problems) to look at"

        return CardSection(title) {
            ForEach(path) { entry in
                CardRow {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(entry.id)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.secondaryText)
                            .frame(minWidth: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.path.isEmpty ? "(empty)" : entry.path)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                            if let note = entry.problem ?? entry.source.map({ "From \($0)" }) {
                                Text(note)
                                    .font(.system(size: 11))
                                    .foregroundStyle(entry.problem == nil ? Palette.secondaryText : Color.orange)
                            }
                        }
                    }
                    .opacity(entry.isDuplicate ? 0.6 : 1)
                } trailing: {
                    if entry.exists {
                        Button {
                            NSWorkspace.shared.open(URL(filePath: entry.path, directoryHint: .isDirectory))
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Open in Finder")
                    }
                }
            }
            if path.isEmpty {
                CardRow("PATH isn't set", hint: nil) { EmptyView() }
            }
        }
    }

    private func variablesSection(_ variables: [EnvVariable]) -> some View {
        let shown = variables.filter { $0.matches(search) }

        return CardSection("Variables · \(variables.count)") {
            CardRow {
                TextField("Filter by name or value", text: $search)
                    .textFieldStyle(.roundedBorder)
            } trailing: {
                EmptyView()
            }
            ForEach(shown) { variable in
                VariableRow(variable: variable, isRevealed: revealed.contains(variable.name)) {
                    revealed.formSymmetricDifference([variable.name])
                }
            }
            if shown.isEmpty {
                CardRow("No matches", hint: nil) { EmptyView() }
            }
        }
    }

    private func title(for source: EnvSource) -> String {
        if case .shell(let url) = source, url == state.environment.loginShell {
            return "\(source.name) (login shell)"
        }
        return source.name
    }

    private func hint(for source: EnvSource) -> String {
        switch source {
        case .shell(let url):
            "A new \(source.name) as Terminal opens it, after your startup files run. From \(url.path)."
        case .apps:
            "What apps opened from the Dock or Finder get. They don't read shell startup files, so their PATH is shorter."
        }
    }
}

private struct VariableRow: View {
    let variable: EnvVariable
    let isRevealed: Bool
    let toggleReveal: () -> Void

    private var isHidden: Bool { variable.isSecret && !isRevealed }

    var body: some View {
        CardRow {
            VStack(alignment: .leading, spacing: 3) {
                Text(variable.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(isHidden ? String(repeating: "•", count: 12) : variable.value.isEmpty ? "(empty)" : variable.value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        } trailing: {
            HStack(spacing: 8) {
                if variable.isSecret {
                    Button(action: toggleReveal) {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .help(isRevealed ? "Hide" : "Show")
                }
                Button {
                    copy(variable.value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy value")
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Copy Value") { copy(variable.value) }
            Button("Copy Name") { copy(variable.name) }
            Button("Copy as export") { copy("export \(variable.name)=\(Command.shellQuoted(variable.value))") }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.copy(text, concealed: variable.isSecret)
    }
}
