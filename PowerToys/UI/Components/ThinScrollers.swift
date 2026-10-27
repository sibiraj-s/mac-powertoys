import AppKit
import SwiftUI

extension View {
    /// Gives the scroll view this is inside thin scroll bars that show while scrolling, even when
    /// a mouse makes macOS use the wide, always-shown ones.
    func thinScrollers() -> some View {
        background(ThinScrollers())
    }
}

private struct ThinScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> FindingView { FindingView() }

    func updateNSView(_ view: FindingView, context: Context) {}

    final class FindingView: NSView {
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard observer == nil else { return }
            // The scroll view switches back when the system's preferred style changes.
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // After the scroll view has handled it.
                Task { @MainActor in self?.apply() }
            }
        }

        private func apply() {
            enclosingScrollView?.scrollerStyle = .overlay
        }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
