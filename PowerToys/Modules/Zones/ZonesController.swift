import AppKit
import Carbon.HIToolbox
import Observation

@Observable
final class ZonesController {
    enum Action: CaseIterable, Identifiable {
        case nextZone, previousZone, fillDisplay, nextDisplay, nextLayout, restore

        var id: Self { self }

        var title: String {
            switch self {
            case .nextZone: "Move to next zone"
            case .previousZone: "Move to previous zone"
            case .fillDisplay: "Fill display"
            case .nextDisplay: "Move to next display"
            case .nextLayout: "Switch to next layout"
            case .restore: "Restore original size"
            }
        }

        var hotKey: HotKey {
            switch self {
            case .nextZone: HotKey(keyCode: kVK_RightArrow, modifiers: [.control, .option], key: "→")
            case .previousZone: HotKey(keyCode: kVK_LeftArrow, modifiers: [.control, .option], key: "←")
            case .fillDisplay: HotKey(keyCode: kVK_Return, modifiers: [.control, .option], key: "↩")
            case .nextDisplay: HotKey(keyCode: kVK_RightArrow, modifiers: [.control, .option, .command], key: "→")
            case .nextLayout: HotKey(keyCode: kVK_ANSI_Z, modifiers: [.control, .option], key: "Z")
            case .restore: HotKey(keyCode: kVK_Delete, modifiers: [.control, .option], key: "⌫")
            }
        }
    }

    /// Hold ⇧ while dragging a window to show zones and drop it into one.
    var snapsWhileDragging: Bool {
        didSet { defaults.set(snapsWhileDragging, forKey: Self.snapsWhileDraggingKey) }
    }

    /// While snapping by drag, also hold ⌥ to cover every zone between the first and current one.
    var spansWithOption: Bool {
        didSet { defaults.set(spansWithOption, forKey: Self.spansWithOptionKey) }
    }

    /// Dragging a snapped window out of its zone gives it back the size it had before snapping.
    var restoresSizeOnUnsnap: Bool {
        didSet { defaults.set(restoresSizeOnUnsnap, forKey: Self.restoresSizeOnUnsnapKey) }
    }

    /// Layout IDs by display key.
    private(set) var layoutIDs: [String: String]

    /// Shortcuts another app already holds.
    private(set) var unavailableActions: Set<Action> = []

    private(set) var isRunning = false

    static let snapsWhileDraggingKey = "zones.snapsWhileDragging"
    static let spansWithOptionKey = "zones.spansWithOption"
    static let restoresSizeOnUnsnapKey = "zones.restoresSizeOnUnsnap"
    static let layoutsKey = "zones.layouts"

    private let defaults: UserDefaults

    @ObservationIgnored private var registrations: [HotKeyCenter.Registration] = []
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private let overlay = ZoneOverlay()
    @ObservationIgnored private var snaps: [Snap] = []
    @ObservationIgnored private var drag: Drag?

    /// A window this controller snapped, and where it was before.
    private struct Snap {
        let window: AXWindow
        let frame: CGRect
        let originalFrame: CGRect
    }

    private struct Drag {
        let window: AXWindow
        let startFrame: CGRect
        /// The frame to restore later if this drag ends in a zone.
        var originalFrame: CGRect
        var isMoving = false
        var spanAnchor: CGRect?
        var target: CGRect?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Self.snapsWhileDraggingKey: true,
            Self.spansWithOptionKey: true,
            Self.restoresSizeOnUnsnapKey: false,
        ])
        snapsWhileDragging = defaults.bool(forKey: Self.snapsWhileDraggingKey)
        spansWithOption = defaults.bool(forKey: Self.spansWithOptionKey)
        restoresSizeOnUnsnap = defaults.bool(forKey: Self.restoresSizeOnUnsnapKey)
        layoutIDs = defaults.dictionary(forKey: Self.layoutsKey) as? [String: String] ?? [:]
    }

    // MARK: Layouts

    func layout(forDisplay key: String) -> ZoneLayout {
        layoutIDs[key].flatMap(ZoneLayout.layout(id:)) ?? .defaultLayout
    }

    func setLayout(_ layout: ZoneLayout, forDisplay key: String) {
        layoutIDs[key] = layout.id
        defaults.set(layoutIDs, forKey: Self.layoutsKey)
    }

    private func zones(on screen: NSScreen) -> [CGRect] {
        layout(forDisplay: Displays.key(for: screen)).frames(in: Displays.usableArea(of: screen))
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        var unavailable: Set<Action> = []
        for action in Action.allCases {
            if let registration = HotKeyCenter.shared.register(action.hotKey, action: { [weak self] in self?.perform(action) }) {
                registrations.append(registration)
            } else {
                unavailable.insert(action)
            }
        }
        unavailableActions = unavailable
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]) { [weak self] event in
            // Global monitors are called on the main thread.
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        registrations.forEach(HotKeyCenter.shared.unregister)
        registrations = []
        unavailableActions = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        drag = nil
        overlay.hide()
    }

    // MARK: Shortcuts

    func perform(_ action: Action) {
        let window = AXWindow.focused()
        let frame = window?.frame
        let screen = frame.flatMap(Displays.screen(for:)) ?? NSScreen.main

        if action == .nextLayout {
            guard let screen else { return }
            let key = Displays.key(for: screen)
            let layouts = ZoneLayout.all
            let current = layouts.firstIndex(of: layout(forDisplay: key)) ?? 0
            let next = layouts[(current + 1) % layouts.count]
            setLayout(next, forDisplay: key)
            overlay.flash(on: screen, zones: zones(on: screen), title: next.name)
            return
        }

        guard let window, let frame, let screen else {
            NSSound.beep()
            return
        }
        let area = Displays.usableArea(of: screen)
        let zones = zones(on: screen)

        switch action {
        case .nextZone, .previousZone:
            guard let index = ZoneMath.target(from: frame, in: zones, step: action == .nextZone ? 1 : -1) else { return }
            snap(window, to: zones[index], originalFrame: originalFrame(of: window, current: frame))
        case .fillDisplay:
            snap(window, to: area, originalFrame: originalFrame(of: window, current: frame))
        case .nextDisplay:
            let screens = Displays.ordered
            guard screens.count > 1, let index = screens.firstIndex(of: screen) else {
                NSSound.beep()
                return
            }
            let destination = Displays.usableArea(of: screens[(index + 1) % screens.count])
            let moved = ZoneMath.move(frame, from: area, to: destination)
            if let snap = snap(for: window) {
                self.snap(window, to: moved, originalFrame: snap.originalFrame)
            } else {
                window.setFrame(moved)
            }
        case .restore:
            guard let snap = snap(for: window) else {
                NSSound.beep()
                return
            }
            forget(window)
            window.setFrame(snap.originalFrame)
        case .nextLayout:
            break
        }
    }

    // MARK: Snapping

    private func snap(_ window: AXWindow, to frame: CGRect, originalFrame: CGRect) {
        forget(window)
        window.setFrame(frame)
        snaps.append(Snap(window: window, frame: frame, originalFrame: originalFrame))
        if snaps.count > 100 { snaps.removeFirst(snaps.count - 100) }
    }

    private func snap(for window: AXWindow) -> Snap? {
        snaps.last { $0.window.isSame(as: window) }
    }

    private func forget(_ window: AXWindow) {
        snaps.removeAll { $0.window.isSame(as: window) }
    }

    /// Where a window should go back to: its pre-snap frame if it's still where it was snapped.
    private func originalFrame(of window: AXWindow, current: CGRect) -> CGRect {
        guard let snap = snap(for: window), ZoneMath.snappedIndex(of: current, in: [snap.frame]) != nil else { return current }
        return snap.originalFrame
    }

    // MARK: Dragging

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            drag = nil
            guard snapsWhileDragging || restoresSizeOnUnsnap,
                  let window = AXWindow.at(Displays.flip(NSEvent.mouseLocation)),
                  let frame = window.frame
            else { return }
            drag = Drag(window: window, startFrame: frame, originalFrame: originalFrame(of: window, current: frame))

        case .leftMouseDragged:
            guard var drag else { return }
            if !drag.isMoving {
                // Only a moving window counts; a changed size means it's being resized.
                guard let frame = drag.window.frame, frame.origin != drag.startFrame.origin, frame.size == drag.startFrame.size else { return }
                drag.isMoving = true
                if restoresSizeOnUnsnap, let snap = snap(for: drag.window),
                   ZoneMath.snappedIndex(of: drag.startFrame, in: [snap.frame]) != nil {
                    forget(drag.window)
                    drag.window.setSize(snap.originalFrame.size)
                    drag.originalFrame = snap.originalFrame
                }
            }
            self.drag = drag
            updateTarget(flags: event.modifierFlags)

        case .flagsChanged:
            if drag?.isMoving == true { updateTarget(flags: event.modifierFlags) }

        case .leftMouseUp:
            let finished = drag
            drag = nil
            overlay.hide()
            guard let finished, finished.isMoving, let target = finished.target else { return }
            // Let the window server finish the move before resizing, or it can put the window back.
            Task {
                try? await Task.sleep(for: .milliseconds(40))
                snap(finished.window, to: target, originalFrame: finished.originalFrame)
            }

        default:
            break
        }
    }

    private func updateTarget(flags: NSEvent.ModifierFlags) {
        guard var drag, drag.isMoving else { return }
        defer { self.drag = drag }
        let point = Displays.flip(NSEvent.mouseLocation)
        guard snapsWhileDragging, flags.contains(.shift), let screen = Displays.screen(at: point) else {
            drag.target = nil
            drag.spanAnchor = nil
            overlay.hide()
            return
        }
        let zones = zones(on: screen)
        var target = ZoneMath.index(at: point, in: zones).map { zones[$0] }
        if spansWithOption, flags.contains(.option), let hovered = target {
            if let anchor = drag.spanAnchor, zones.contains(anchor) {
                target = ZoneMath.span(anchor, hovered)
            } else {
                drag.spanAnchor = hovered
            }
        } else {
            drag.spanAnchor = nil
        }
        drag.target = target
        overlay.show(on: screen, zones: zones, highlight: target)
    }
}
