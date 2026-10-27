import SwiftUI

struct PermissionsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Page {
            PageHeader(
                symbol: "lock",
                title: "Permissions",
                summary: "\(AppInfo.name) asks for each permission only when a module that needs it is turned on."
            )

            CardSection("System access") {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, status: state.permissions.status(permission))
                }
            }
        }
        .task { state.permissions.refresh() }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus

    @Environment(AppState.self) private var state

    private var usedBy: [ModuleDescriptor] {
        ModuleCatalog.all.filter { $0.permissions.contains(permission) }
    }

    var body: some View {
        CardRow {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: permission.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(permission.title).font(.system(size: 13))
                        PermissionBadge(permission: permission, status: status, includesName: false)
                    }
                    Text(permission.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !usedBy.isEmpty {
                        Text("Used by \(usedBy.map(\.name).formatted(.list(type: .and)))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } trailing: {
            if status != .granted, permission.settingsURL != nil {
                Button(status == .denied ? "Grant…" : "Open Settings") {
                    state.permissions.request(permission)
                }
            }
        }
    }
}
