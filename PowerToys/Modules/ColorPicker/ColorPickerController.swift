import AppKit
import Observation

/// Shows the magnifier for picking a color off the screen; a protocol so tests don't show it.
protocol ColorSampling {
    /// The color clicked, or nil when picking was cancelled with Esc.
    func sample() async -> PickedColor?
}

/// The system's magnifier. It reads the screen itself, so no Screen Recording permission is needed.
struct LiveColorSampler: ColorSampling {
    func sample() async -> PickedColor? {
        let sampler = NSColorSampler()
        let color = await withCheckedContinuation { continuation in
            sampler.show { continuation.resume(returning: $0) }
        }
        // Kept alive until it answers; nothing else holds on to it.
        withExtendedLifetime(sampler) {}
        // Screens can be wider than sRGB; formats like HEX are sRGB, so convert to it.
        guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
        return PickedColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }
}

/// Picks colors off the screen, copies them in the chosen format and keeps the recent ones.
@Observable
final class ColorPickerController {
    private(set) var history: [PickedColor]
    private(set) var isPicking = false

    /// What a pick copies, and how the menu bar tile shows the latest color.
    var format: ColorFormat {
        didSet { defaults.set(format.rawValue, forKey: Self.formatKey) }
    }

    /// Copy each picked color straight away, in `format`.
    var copiesOnPick: Bool {
        didSet { defaults.set(copiesOnPick, forKey: Self.copiesOnPickKey) }
    }

    /// Unset until assigned: the module is on from the first launch, so it mustn't take keys
    /// other apps use without being asked.
    static let pickShortcut = ShortcutDefinition(id: "colorPicker.pick", module: .colorPicker, title: "Pick a color", defaultHotKey: nil)

    static let historyLimit = 24
    static let historyKey = "colorPicker.history"
    static let formatKey = "colorPicker.format"
    static let copiesOnPickKey = "colorPicker.copiesOnPick"

    private let defaults: UserDefaults
    @ObservationIgnored private let sampler: any ColorSampling
    @ObservationIgnored private let pasteboard: NSPasteboard

    init(defaults: UserDefaults = .standard, sampler: any ColorSampling = LiveColorSampler(), pasteboard: NSPasteboard = .general) {
        self.defaults = defaults
        self.sampler = sampler
        self.pasteboard = pasteboard
        defaults.register(defaults: [Self.copiesOnPickKey: true])
        format = defaults.string(forKey: Self.formatKey).flatMap(ColorFormat.init(rawValue:)) ?? .hex
        copiesOnPick = defaults.bool(forKey: Self.copiesOnPickKey)
        history = defaults.data(forKey: Self.historyKey)
            .flatMap { try? JSONDecoder().decode([PickedColor].self, from: $0) }
            ?? []
    }

    var latest: PickedColor? { history.first }

    /// Shows the magnifier; the color clicked goes to the top of the history, and is copied
    /// when `copiesOnPick` is on. Returns nil when cancelled.
    @discardableResult
    func pick() async -> PickedColor? {
        guard !isPicking else { return nil }
        isPicking = true
        defer { isPicking = false }
        guard let color = await sampler.sample() else { return nil }
        add(color)
        if copiesOnPick { copy(color) }
        return color
    }

    /// Puts the color at the top of the history, moving it there if it's already in it.
    func add(_ color: PickedColor) {
        history.removeAll { $0.id == color.id }
        history.insert(color, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        save()
    }

    func copy(_ color: PickedColor, as format: ColorFormat? = nil) {
        pasteboard.clearContents()
        pasteboard.setString((format ?? self.format).string(for: color), forType: .string)
    }

    func remove(_ color: PickedColor) {
        history.removeAll { $0.id == color.id }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(history), forKey: Self.historyKey)
    }
}
