import AppKit
import Carbon.HIToolbox
import Observation
import ScreenCaptureKit

/// Switches between windows rather than apps.
///
/// Its shortcut works like ⌘⇥: holding the shortcut's modifier keys, pressing its key opens the
/// switcher on the previous window and each further press steps on; letting go of the modifiers
/// switches to the selected window. A shortcut without modifiers, such as F13, keeps the switcher
/// open until Return or a click.
@Observable
final class WindowSwitcherController {
    enum Style: String, CaseIterable, Identifiable {
        /// Every window as a tile.
        case grid
        /// The selected window as a card in front, the next ones stacked behind it.
        case stack

        var id: Self { self }
        var title: String { self == .grid ? "Grid" : "Stack" }
    }

    /// Done to the selected window from the switcher, which stays open.
    enum Action: CaseIterable, Identifiable {
        case close, minimize, hideApp, quitApp

        var id: Self { self }
        var keyCode: Int {
            switch self {
            case .close: kVK_ANSI_W
            case .minimize: kVK_ANSI_M
            case .hideApp: kVK_ANSI_H
            case .quitApp: kVK_ANSI_Q
            }
        }
        var key: String {
            switch self {
            case .close: "W"
            case .minimize: "M"
            case .hideApp: "H"
            case .quitApp: "Q"
            }
        }
        var title: String {
            switch self {
            case .close: "Close"
            case .minimize: "Minimize"
            case .hideApp: "Hide app"
            case .quitApp: "Quit app"
            }
        }
    }

    static let styleKey = "windowSwitcher.style"
    static let peekKey = "windowSwitcher.peek"

    /// Unset until assigned, as every shortcut in the app starts out.
    static let switchShortcut = ShortcutDefinition(
        id: "windowSwitcher.switch", module: .windowSwitcher, title: "Switch windows", defaultHotKey: nil)

    private(set) var windows: [SwitcherWindow] = []
    private(set) var selectedIndex = 0
    private(set) var previews: [CGWindowID: CGImage] = [:]
    private(set) var isShowing = false

    var style: Style {
        didSet { defaults.set(style.rawValue, forKey: Self.styleKey) }
    }
    /// Dims the screen around the selected window while switching.
    var peeks: Bool {
        didSet { defaults.set(peeks, forKey: Self.peekKey) }
    }

    /// Only the grid peeks: the stack's front card is already a large view of the window.
    var showsPeek: Bool { peeks && style == .grid }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let shortcuts: Shortcuts
    @ObservationIgnored private let lister: any WindowListing
    @ObservationIgnored private let previewer: any WindowPreviewing
    @ObservationIgnored private let presenter: any SwitcherPresenting
    @ObservationIgnored private let currentModifiers: () -> NSEvent.ModifierFlags
    @ObservationIgnored private let frontmostPID: () -> pid_t?
    @ObservationIgnored private let activate: (SwitcherWindow) -> Void
    @ObservationIgnored private let act: (Action, SwitcherWindow) -> Void
    @ObservationIgnored private let schedule: (Duration, @escaping @MainActor () -> Void) -> Void
    @ObservationIgnored private let alert: () -> Void
    /// The shortcut's modifiers, held while the switcher is open; letting go of them switches.
    @ObservationIgnored private var holdModifiers: NSEvent.ModifierFlags = []
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// Counts showings, so a capture still finishing from an earlier one is dropped.
    @ObservationIgnored private var showing = 0
    /// The shortcut's own key: with ⇧ added, it steps back.
    @ObservationIgnored private(set) var stepKeyCode: Int?

    init(
        defaults: UserDefaults = .standard,
        shortcuts: Shortcuts,
        lister: any WindowListing = LiveWindowLister(),
        previewer: any WindowPreviewing = LiveWindowPreviewer(),
        presenter: any SwitcherPresenting = WindowSwitcherPanel(),
        currentModifiers: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
        frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        activate: @escaping (SwitcherWindow) -> Void = { WindowSwitcherController.bringForward($0) },
        act: @escaping (Action, SwitcherWindow) -> Void = { WindowSwitcherController.perform($0, on: $1) },
        schedule: @escaping (Duration, @escaping @MainActor () -> Void) -> Void = { delay, work in
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                work()
            }
        },
        alert: @escaping () -> Void = { NSSound.beep() }
    ) {
        self.defaults = defaults
        style = defaults.string(forKey: Self.styleKey).flatMap(Style.init(rawValue:)) ?? .grid
        peeks = defaults.object(forKey: Self.peekKey) as? Bool ?? true
        self.shortcuts = shortcuts
        self.lister = lister
        self.previewer = previewer
        self.presenter = presenter
        self.currentModifiers = currentModifiers
        self.frontmostPID = frontmostPID
        self.activate = activate
        self.act = act
        self.schedule = schedule
        self.alert = alert
    }

    var selected: SwitcherWindow? {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
    }

    /// The shortcut was pressed: opens the switcher on the previous window, or steps on when open.
    func trigger() {
        if isShowing {
            step(by: 1)
            return
        }
        let windows = lister.windows()
        guard !windows.isEmpty else {
            alert()
            return
        }
        self.windows = windows
        // When the first is the window in front now, the one behind it is where you most likely want
        // to go. When the app in front has no window listed (this app's own, or Finder with only the
        // desktop), the first is the window you were last in.
        selectedIndex = windows[0].pid == frontmostPID() ? min(1, windows.count - 1) : 0
        let hotKey = shortcuts.hotKey(for: Self.switchShortcut)
        holdModifiers = hotKey?.modifiers ?? []
        stepKeyCode = hotKey?.keyCode
        // Let go before the switcher could show: a quick press goes straight to the previous window.
        if !holdModifiers.isEmpty && !currentModifiers().isSuperset(of: holdModifiers) {
            commit()
            return
        }
        isShowing = true
        showing += 1
        presenter.show(self)
        let ids = windows.compactMap(\.windowID)
        let current = showing
        // Grid tiles are small; only the stack's cards need large previews.
        let size = style == .grid ? SwitcherLayout.tilePreviewPixels : SwitcherLayout.cardPreviewPixels
        previewTask = Task { [weak self, previewer] in
            await previewer.capture(ids, maxPixels: size) { id, image in
                guard let self, self.isShowing, self.showing == current else { return }
                self.previews[id] = image
            }
        }
    }

    /// Moves the selection, wrapping around at either end.
    func step(by offset: Int) {
        guard !windows.isEmpty else { return }
        selectedIndex = SwitcherLayout.wrapped(selectedIndex + offset, count: windows.count)
    }

    /// Moves the selection a whole row in the grid, staying put at the top or bottom.
    func moveRow(by offset: Int) {
        guard windows.indices.contains(selectedIndex + offset) else { return }
        selectedIndex += offset
    }

    func select(_ window: SwitcherWindow) {
        guard let index = windows.firstIndex(where: { $0.id == window.id }) else { return }
        selectedIndex = index
    }

    /// Switches once the shortcut's modifiers are let go of.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard isShowing, !holdModifiers.isEmpty, !flags.isSuperset(of: holdModifiers) else { return }
        commit()
    }

    /// Does `action` to the selected window, then lists the windows again once the app has had
    /// time to respond. An app may not do it at all, as when it asks to save first or won't quit,
    /// so the list follows what happened rather than what was asked for.
    func perform(_ action: Action) {
        guard isShowing, let window = selected else { return }
        // Hiding or quitting the app in front brings another forward, which takes the keys from the
        // switcher; that mustn't close it, and the keys come back to it after.
        actionsInProgress += 1
        act(action, window)
        let current = showing
        // Quitting can take a while; the second look catches slower apps.
        for delay in [Duration.milliseconds(300), .seconds(1)] {
            schedule(delay) { [weak self] in
                guard let self else { return }
                if delay == .seconds(1) { self.actionsInProgress -= 1 }
                guard self.isShowing, self.showing == current else { return }
                self.refresh()
                self.presenter.refocus()
            }
        }
    }

    /// Actions whose app may still be responding; while there are any, losing the keys doesn't close the switcher.
    @ObservationIgnored private(set) var actionsInProgress = 0

    /// Actions whose key isn't the shortcut's own: holding its modifiers, that key steps instead.
    var availableActions: [Action] {
        Action.allCases.filter { $0.keyCode != stepKeyCode }
    }

    /// The switcher lost the keys, as when another app came forward or was clicked.
    func lostFocus() {
        guard actionsInProgress == 0 else { return }
        cancel()
    }

    /// Lists the windows again, keeping the same window selected while it's still there.
    private func refresh() {
        let selectedID = selected?.id
        let windows = lister.windows()
        guard !windows.isEmpty else {
            cancel()
            return
        }
        self.windows = windows
        selectedIndex = windows.firstIndex { $0.id == selectedID } ?? min(selectedIndex, windows.count - 1)
    }

    /// Closes the switcher and brings the selected window forward.
    func commit() {
        let window = selected
        close()
        if let window { activate(window) }
    }

    /// Closes the switcher without switching, as with Esc or when the module is turned off.
    func cancel() {
        close()
    }

    private func close() {
        if isShowing { presenter.hide() }
        isShowing = false
        previewTask?.cancel()
        previewTask = nil
        windows = []
        previews = [:]
        selectedIndex = 0
    }

    static func perform(_ action: Action, on window: SwitcherWindow) {
        window.window.useDefaultTimeout()
        switch action {
        case .close: window.window.close()
        case .minimize: window.window.minimize()
        case .hideApp: NSRunningApplication(processIdentifier: window.pid)?.hide()
        case .quitApp: NSRunningApplication(processIdentifier: window.pid)?.terminate()
        }
    }

    /// Shows a hidden app, restores a minimized window, and raises the window with its app.
    static func bringForward(_ window: SwitcherWindow) {
        // Listing gave up quickly on hung apps; raising waits as long as usual.
        window.window.useDefaultTimeout()
        if let app = NSRunningApplication(processIdentifier: window.pid), app.isHidden {
            app.unhide()
        }
        window.window.raise()
    }
}

/// Shows the switcher; a protocol so tests don't show it.
protocol SwitcherPresenting: AnyObject {
    func show(_ controller: WindowSwitcherController)
    func hide()
    /// Takes the keys back after an action brought another app forward.
    func refocus()
}

/// Captures window previews; a protocol so tests don't capture the screen.
protocol WindowPreviewing {
    /// Captures each window in turn, handing each image over as it arrives. Captures nothing
    /// without Screen Recording access, which it never asks for.
    func capture(_ ids: [CGWindowID], maxPixels: CGSize, each: @escaping (CGWindowID, CGImage) -> Void) async
}

struct LiveWindowPreviewer: WindowPreviewing {
    func capture(_ ids: [CGWindowID], maxPixels: CGSize, each: @escaping (CGWindowID, CGImage) -> Void) async {
        guard CGPreflightScreenCaptureAccess(),
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let windows = ids.compactMap { byID[$0] }.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        // All at once, so the last tiles don't wait on the first.
        await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for window in windows {
                // An SCWindow is a description of the window that never changes, so it's safe to hand over.
                nonisolated(unsafe) let window = window
                group.addTask { (window.windowID, await Self.capture(window, maxPixels: maxPixels)) }
            }
            for await (id, image) in group {
                guard !Task.isCancelled else { return }
                if let image { each(id, image) }
            }
        }
    }

    nonisolated private static func capture(_ window: SCWindow, maxPixels: CGSize) async -> CGImage? {
        let scale = min(maxPixels.width / window.frame.width, maxPixels.height / window.frame.height, 2)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
