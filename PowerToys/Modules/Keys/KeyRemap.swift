import AppKit

/// Pressing some keys presses others instead, or nothing, everywhere or in one app.
struct KeyRemap: Identifiable, Hashable, Codable {
    var id = UUID()
    /// The keys pressed; nil until recorded, and until then the remap does nothing.
    var from: HotKey?
    var output: Output = .keys(nil)
    /// The one app it applies in, or nil for every app.
    var app: App?

    enum Output: Hashable, Codable {
        /// Press these keys instead; nil until recorded.
        case keys(HotKey?)
        /// Swallow the keys, such as ⌘Q you keep pressing by mistake.
        case nothing

        enum Kind: CaseIterable, Identifiable {
            case keys, nothing

            var id: Self { self }

            var title: String {
                switch self {
                case .keys: "Press keys"
                case .nothing: "Do nothing"
                }
            }
        }

        var kind: Kind {
            switch self {
            case .keys: .keys
            case .nothing: .nothing
            }
        }

        init(kind: Kind) {
            self = kind == .keys ? .keys(nil) : .nothing
        }
    }

    struct App: Hashable, Codable {
        let bundleID: String
        let name: String
    }

    /// Whether it's complete enough to change anything.
    var isActive: Bool {
        from != nil && output != .keys(nil)
    }

    /// What pressing these keys in this app does: a remap for the app wins over one for every app.
    /// Nil means the keys go through as they are. The app is only looked up when a remap for one
    /// app matches, since this runs on every key press.
    static func output(
        for keyCode: Int, modifiers: NSEvent.ModifierFlags, app bundleID: @autoclosure () -> String?, in remaps: [KeyRemap]
    ) -> Output? {
        let pressed = HotKey(keyCode: keyCode, modifiers: modifiers, key: "")
        let matches = remaps.filter { $0.isActive && $0.from == pressed }
        guard !matches.isEmpty else { return nil }
        let appMatches = matches.filter { $0.app != nil }
        let frontmost = appMatches.isEmpty ? nil : bundleID()
        let match = appMatches.first { $0.app?.bundleID == frontmost } ?? matches.first { $0.app == nil }
        return match?.output
    }
}
