import AppKit
import Observation

/// Shows the ruler over the screen; a protocol so tests don't show it.
protocol RulerPresenting {
    /// What was measured, or nil when cancelled with Esc or `cancel()`.
    func measure(unit: RulerUnit, tolerance: Int) async -> RulerMeasurement?
    func cancel()
}

/// Freezes the screen to measure the space between edges or an area dragged over, and copies the size.
@Observable
final class ScreenRulerController {
    private(set) var isMeasuring = false
    private(set) var latest: RulerMeasurement?

    var unit: RulerUnit {
        didSet { defaults.set(unit.rawValue, forKey: Self.unitKey) }
    }

    /// How far a color can be from the one under the pointer, from 0 to 255 per channel, and
    /// still count as the same surface rather than an edge.
    var tolerance: Int {
        didSet {
            guard Self.toleranceRange.contains(tolerance) else {
                tolerance = Self.clamped(tolerance)
                return
            }
            defaults.set(tolerance, forKey: Self.toleranceKey)
        }
    }

    /// Unset until assigned, as every shortcut in the app starts out.
    static let measureShortcut = ShortcutDefinition(
        id: "screenRuler.measure", module: .screenRuler, title: "Measure the screen", defaultHotKey: nil)

    static let toleranceRange = 0...64
    static let unitKey = "screenRuler.unit"
    static let toleranceKey = "screenRuler.tolerance"

    private let defaults: UserDefaults
    @ObservationIgnored private let presenter: any RulerPresenting
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let access: ScreenAccess

    init(
        defaults: UserDefaults = .standard,
        presenter: any RulerPresenting = LiveRulerPresenter(),
        pasteboard: NSPasteboard = .general,
        access: ScreenAccess
    ) {
        self.defaults = defaults
        self.presenter = presenter
        self.pasteboard = pasteboard
        self.access = access
        defaults.register(defaults: [Self.toleranceKey: 16])
        unit = defaults.string(forKey: Self.unitKey).flatMap(RulerUnit.init(rawValue:)) ?? .points
        tolerance = Self.clamped(defaults.integer(forKey: Self.toleranceKey))
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, toleranceRange.lowerBound), toleranceRange.upperBound)
    }

    /// Shows the ruler and copies what's measured. Returns nil when cancelled, or without
    /// Screen Recording access, which is asked for.
    @discardableResult
    func measure() async -> RulerMeasurement? {
        guard !isMeasuring else { return nil }
        guard access.check() else { return nil }
        isMeasuring = true
        defer { isMeasuring = false }
        guard let measurement = await presenter.measure(unit: unit, tolerance: tolerance) else { return nil }
        latest = measurement
        copy(measurement)
        return measurement
    }

    func copy(_ measurement: RulerMeasurement) {
        pasteboard.copy(measurement.text(in: unit))
    }

    /// Closes the ruler, as when the module is turned off.
    func cancel() {
        presenter.cancel()
    }
}
