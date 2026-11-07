import AppKit
import Observation

/// Keeps live copies of windows, or parts of them, floating above everything else.
///
/// macOS only lets an app raise its own windows above others, so a pin is a copy of the window
/// streamed into a panel of this app's. Double-clicking it swaps in the real window: with Accessibility,
/// the window moves under the pin and comes forward while the pin hides, until another app does.
@Observable
final class PinCropController {
    struct Pin: Identifiable {
        let id = UUID()
        let selection: WindowSelection

        var appName: String { selection.window.appName }

        /// The window's title, and the size of the part shown when cropped.
        var detail: String {
            let title = selection.window.title.isEmpty ? "Untitled window" : selection.window.title
            guard let crop = selection.crop else { return title }
            return "\(title) · \(Int(crop.width)) × \(Int(crop.height)) crop"
        }
    }

    private(set) var pins: [Pin] = []
    private(set) var isPicking = false

    /// Unset until assigned, as every shortcut in the app starts out.
    static let pinShortcut = ShortcutDefinition(id: "pinCrop.pin", module: .pinCrop, title: "Pin or crop a window", defaultHotKey: nil)

    @ObservationIgnored private let picker: any WindowPicker
    @ObservationIgnored private let presenter: any PinPresenting
    @ObservationIgnored private let raiser: any SourceWindowRaising
    @ObservationIgnored private let access: ScreenAccess
    @ObservationIgnored private let alert: () -> Void
    @ObservationIgnored private let activate: (pid_t) -> Void
    @ObservationIgnored private var windows: [UUID: any PinWindow] = [:]
    /// The pin hidden while its window is in front in its place, and that window's app.
    @ObservationIgnored private var swapped: (pin: UUID, pid: pid_t)?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    init(
        picker: any WindowPicker = LiveWindowPicker(),
        presenter: any PinPresenting = LivePinPresenter(),
        raiser: any SourceWindowRaising = LiveSourceWindowRaiser(),
        access: ScreenAccess,
        alert: @escaping () -> Void = { NSSound.beep() },
        activate: @escaping (pid_t) -> Void = { NSRunningApplication(processIdentifier: $0)?.activate() }
    ) {
        self.picker = picker
        self.presenter = presenter
        self.raiser = raiser
        self.access = access
        self.alert = alert
        self.activate = activate
    }

    isolated deinit {
        observeActivation(false)
    }

    /// Shows the picker and pins what's picked. Returns nil when cancelled, when the window
    /// can't be captured (with an alert sound), or without Screen Recording access, which is asked for.
    @discardableResult
    func pick() async -> Pin? {
        guard !isPicking else { return nil }
        guard access.check() else { return nil }
        isPicking = true
        let selection = await picker.pick()
        isPicking = false
        guard let selection else { return nil }
        return await pin(selection)
    }

    @discardableResult
    func pin(_ selection: WindowSelection) async -> Pin? {
        let pin = Pin(selection: selection)
        let window = await presenter.present(
            selection,
            onShowSource: { [weak self] in self?.showSource(of: pin) },
            onClose: { [weak self] in self?.forget(pin.id) }
        )
        guard let window else {
            alert()
            return nil
        }
        windows[pin.id] = window
        pins.append(pin)
        return pin
    }

    /// Puts the real window where the pin is and brings it forward, hiding the pin until another
    /// app comes forward. Without Accessibility, only brings the app forward.
    func showSource(of pin: Pin) {
        restoreSwappedPin()
        let pid = pin.selection.window.pid
        guard let window = windows[pin.id], raiser.raise(pin.selection, showingAt: window.frame.origin) else {
            activate(pid)
            return
        }
        window.setHidden(true)
        swapped = (pin.id, pid)
        observeActivation(true)
    }

    /// Another app came forward, so the swapped-in window's pin goes back on top of it.
    func appDidActivate(_ pid: pid_t) {
        guard let swapped, swapped.pid != pid else { return }
        restoreSwappedPin()
    }

    func close(_ pin: Pin) {
        windows[pin.id]?.close()
        forget(pin.id)
    }

    func closeAll() {
        for pin in pins { close(pin) }
    }

    /// The module was turned off: closes the picker, which then pins nothing, and every pin.
    func stop() {
        picker.cancel()
        closeAll()
    }

    private func restoreSwappedPin() {
        guard let swapped else { return }
        self.swapped = nil
        observeActivation(false)
        windows[swapped.pin]?.setHidden(false)
    }

    /// Watched only while a window is swapped in.
    private func observeActivation(_ observe: Bool) {
        let center = NSWorkspace.shared.notificationCenter
        if let activationObserver { center.removeObserver(activationObserver) }
        activationObserver = nil
        guard observe else { return }
        activationObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.appDidActivate(pid) }
        }
    }

    private func forget(_ id: UUID) {
        if swapped?.pin == id {
            swapped = nil
            observeActivation(false)
        }
        windows[id] = nil
        pins.removeAll { $0.id == id }
    }
}
