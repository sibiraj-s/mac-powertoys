import SwiftUI

struct OverviewView: View {
    @Binding var selection: Pane

    @Environment(AppState.self) private var state
    @AppStorage("showsMenuBarIcon") private var showsMenuBarIcon = true

    var body: some View {
        @Bindable var state = state

        Page {
            PageHeader(
                symbol: "gearshape",
                title: "Overview",
                summary: "Each module turns on separately and asks for permissions only when you enable it."
            ) {
                Text("\(state.enabledCount) of \(ModuleCatalog.all.count) on")
                    .foregroundStyle(.secondary)
            }

            CardSection("General") {
                CardRow("Launch at login") {
                    RowSwitch(label: "Launch at login", isOn: $state.launchesAtLogin)
                }
                CardRow("Show in menu bar", hint: "Quick toggles for running modules.") {
                    RowSwitch(label: "Show in menu bar", isOn: $showsMenuBarIcon)
                }
            }

            UpdatesSection()

            ForEach(ModuleCategory.allCases) { category in
                CardSection(category.rawValue) {
                    ForEach(ModuleCatalog.modules(in: category)) { module in
                        CardRow {
                            Button {
                                selection = .module(module.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: module.symbol)
                                        .font(.system(size: 12))
                                        .frame(width: 18)
                                        .foregroundStyle(Color.accentColor)
                                    RowLabel(title: module.name)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } trailing: {
                            if module.isImplemented {
                                RowSwitch(label: module.name, isOn: state.binding(for: module.id))
                            } else {
                                Text("Soon")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.secondaryText)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct UpdatesSection: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        CardSection("Updates") {
            if updater.isEnabled {
                CardRow("Check for updates automatically", hint: "Looks once a day and asks before installing a new version.") {
                    RowSwitch(label: "Check for updates automatically", isOn: $updater.automaticallyChecks)
                }
            }
            CardRow(
                "Version \(updater.currentVersion)",
                hint: updater.isEnabled ? nil : "This build doesn't update itself; Check Now opens the releases page."
            ) {
                Button("Check Now") { updater.checkNow() }
                    .disabled(!updater.canCheckNow)
            }
        }
    }
}
