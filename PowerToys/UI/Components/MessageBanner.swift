import SwiftUI

/// The last result or problem, with a close button when it's one that can be dismissed.
struct MessageBanner: View {
    let message: String
    let isError: Bool
    /// A link button after the message, such as Details.
    var action: (title: String, perform: () -> Void)?
    let dismiss: (() -> Void)?

    var body: some View {
        let tint = isError ? Color.orange : Palette.on
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.link)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.secondaryText)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
    }
}
