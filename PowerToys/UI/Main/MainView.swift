import SwiftUI

enum Pane: Hashable {
    case overview
    case permissions
    case module(ModuleID)
}

struct MainView: View {
    @Environment(AppState.self) private var state
    @State private var selection: Pane = .overview
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 232)
                .background(Palette.sidebar)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Palette.border).frame(width: 1)
                }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.content)
        }
        .ignoresSafeArea()
        .controlSize(.small)
        .frame(minWidth: 760, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Grants happen in System Settings; pick them up when the user comes back.
            state.permissions.refresh()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights, which sit over the sidebar.
            Color.clear.frame(height: 48)
            SearchField(text: $search)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if search.isEmpty {
                        SidebarGroup(label: "General") {
                            SidebarRow(title: "Overview", symbol: "slider.horizontal.3", isOn: nil, pane: .overview, selection: $selection)
                            SidebarRow(title: "Permissions", symbol: "lock", isOn: nil, pane: .permissions, selection: $selection)
                        }
                    }
                    ForEach(ModuleCategory.allCases) { category in
                        let modules = filteredModules(in: category)
                        if !modules.isEmpty {
                            SidebarGroup(label: category.rawValue) {
                                ForEach(modules) { module in
                                    SidebarRow(
                                        title: module.name, symbol: module.symbol, isOn: state.isEnabled(module.id),
                                        pane: .module(module.id), selection: $selection
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview:
            OverviewView(selection: $selection)
        case .permissions:
            PermissionsView()
        case .module(let id):
            ModuleDetailView(module: ModuleCatalog.descriptor(id))
                .id(id)
        }
    }

    private func filteredModules(in category: ModuleCategory) -> [ModuleDescriptor] {
        let modules = ModuleCatalog.modules(in: category)
        guard !search.isEmpty else { return modules }
        return modules.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search)
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        TextField("Search", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.content))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border))
    }
}

private struct SidebarGroup<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            content
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    /// `nil` for rows that aren't modules, which have no on/off dot.
    let isOn: Bool?
    let pane: Pane
    @Binding var selection: Pane

    private var isSelected: Bool { selection == pane }

    var body: some View {
        Button {
            selection = pane
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .symbolVariant(.none)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let isOn {
                    Circle()
                        .fill(isSelected ? Color.white : isOn ? Palette.on : Palette.off)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(isOn ? "On" : "Off")
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
