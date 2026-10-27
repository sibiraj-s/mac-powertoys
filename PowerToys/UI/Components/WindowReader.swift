import AppKit
import SwiftUI

/// Reports the window a view is in, to tell its notifications apart from other windows'.
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReportingView {
        ReportingView(onChange: onChange)
    }

    func updateNSView(_ view: ReportingView, context: Context) {}

    final class ReportingView: NSView {
        let onChange: (NSWindow?) -> Void

        init(onChange: @escaping (NSWindow?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            // Not during SwiftUI's update, which would change state mid-render.
            Task { @MainActor in self.onChange(window) }
        }
    }
}
