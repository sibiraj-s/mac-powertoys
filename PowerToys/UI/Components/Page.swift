import SwiftUI

/// Colors from the design, with dark variants.
enum Palette {
    static let sidebar = dynamic(light: 0xF2F2F4, dark: 0x262628)
    static let content = dynamic(light: 0xFFFFFF, dark: 0x1E1E1F)
    static let border = dynamic(light: 0xE3E3E8, dark: 0x3A3A3D)
    static let divider = dynamic(light: 0xEDEDF0, dark: 0x333336)
    static let secondaryText = dynamic(light: 0x6E6E73, dark: 0x98989D)
    static let on = Color(hex: 0x34A853)
    static let off = dynamic(light: 0xC7C7CC, dark: 0x5A5A5E)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

/// The scrolling content column of the main window.
struct Page<Content: View>: View {
    /// Space between a page's sections.
    static var sectionSpacing: CGFloat { 28 }

    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                content
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .thinScrollers()
        }
        .background(Palette.content)
    }
}

/// Icon tile, title and description at the top of a page, with optional badges and a trailing control.
struct PageHeader<Badges: View, Trailing: View>: View {
    let symbol: String
    let title: String
    let summary: String
    @ViewBuilder var badges: Badges
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) { badges }
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
    }
}

extension PageHeader where Badges == EmptyView {
    init(symbol: String, title: String, summary: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(symbol: symbol, title: title, summary: summary, badges: { EmptyView() }, trailing: trailing)
    }
}

extension PageHeader where Badges == EmptyView, Trailing == EmptyView {
    init(symbol: String, title: String, summary: String) {
        self.init(symbol: symbol, title: title, summary: summary, badges: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// A titled, bordered card holding `CardRow`s.
struct CardSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                SectionTitle(title)
            }
            VStack(spacing: 0) {
                content
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.content))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
        }
    }
}

/// The small grey label above a card.
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.secondaryText)
            .padding(.leading, 2)
    }
}

/// A label with an optional hint on the left and a control on the right.
struct CardRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider).frame(height: 1)
        }
    }
}

extension CardRow where Leading == RowLabel {
    init(_ title: String, hint: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(leading: { RowLabel(title: title, hint: hint) }, trailing: trailing)
    }
}

struct RowLabel: View {
    let title: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13))
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A switch with its label hidden, for the trailing side of a row.
struct RowSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
    }
}

/// Keyboard shortcut keys drawn as keycaps.
struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11))
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, key.count > 1 ? 5 : 0)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Palette.content))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.border))
                    .shadow(color: .black.opacity(0.06), radius: 0, y: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Green "granted", orange "needed" or neutral pill for a permission.
struct PermissionBadge: View {
    let permission: Permission
    let status: PermissionStatus
    /// Leave out the permission's name when it's already shown beside the badge.
    var includesName = true

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var text: String {
        switch status {
        case .granted: includesName ? "\(permission.title) granted" : "Granted"
        case .denied: includesName ? "\(permission.title) needed" : "Needed"
        case .unknown: permission.title
        }
    }

    private var icon: String {
        switch status {
        case .granted: "checkmark"
        case .denied: "exclamationmark.triangle"
        case .unknown: permission.symbol
        }
    }

    private var tint: Color {
        switch status {
        case .granted: .green
        case .denied: .orange
        case .unknown: .secondary
        }
    }
}
