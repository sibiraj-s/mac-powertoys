import AppKit
import ApplicationServices

/// The windows Lanes arranges, each known by a number that lasts as long as the window does.
protocol LaneWindowSystem: AnyObject {
    /// Called when windows may have changed: one opened, closed, moved, was resized or took the
    /// keyboard, or a Space or display changed.
    var onChange: () -> Void { get set }
    /// Called when a window is gone for good.
    var onClose: (Int) -> Void { get set }

    /// Whether windows can be looked at and moved yet, which needs Accessibility.
    var isReady: Bool { get }

    func start()
    func stop()
    func snapshot() -> LaneSnapshot
    /// Where one window is now, without looking at the rest.
    func frame(of id: Int) -> CGRect?
    /// Gives apps that weren't answering another chance at once, for when every window has to be reached.
    func askAgain()
    /// When an app that isn't answering is next due to be asked, if any is being left alone.
    var askAgainAt: Date? { get }
    /// Moves a window. Returns where it ended up, which an app may make differ from what was
    /// asked; nil when it couldn't be moved, as when its app isn't answering.
    func apply(_ move: LaneMove) -> CGRect?
    /// Moves a window's top left without waiting to hear where it ended up, for a window on its
    /// way somewhere.
    func slide(_ id: Int, to origin: CGPoint)
    /// The process a window belongs to.
    func owner(of id: Int) -> pid_t?
    /// Whether a window can't be moved for now because its app isn't answering.
    func isHeldUp(_ id: Int) -> Bool
    func focus(_ id: Int)
    /// Leaves the focused window out of the lanes, or lets it back in. Returns its number when
    /// it's now left out.
    func toggleFloating() -> Int?
}

/// Other apps' windows through Accessibility, which also says when they change.
///
/// Every question put to another app waits for its answer on the main thread, so the looks are
/// kept cheap: only apps that said something changed are asked again, what doesn't change about
/// a window is asked once, and an app that doesn't answer is left alone for a while.
final class LiveLaneWindows: LaneWindowSystem {
    var onChange: () -> Void = {}
    var onClose: (Int) -> Void = { _ in }

    /// An Accessibility element as a dictionary key.
    private struct Element: Hashable {
        let element: AXUIElement

        static func == (a: Element, b: Element) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    private var ids: [Element: Int] = [:]
    private var windows: [Int: AXWindow] = [:]
    private var nextID = 1
    private var floating: Set<Int> = []
    /// Windows found not to be ones to arrange, such as dialogs and fixed-size windows, by app.
    /// A window can be given its kind a moment after it opens, so each is asked again after a
    /// second, then two, then four, and after that taken at its word.
    private var passedOver: [pid_t: [Element: (again: Date, checks: Int)]] = [:]
    /// Each app's windows at the last look, for when it doesn't answer.
    private var lastSeen: [pid_t: [LaneSnapshot.Window]] = [:]
    /// Apps that didn't answer, with how many times running and when to try each again. Until
    /// then they aren't asked anything: each question would wait half a second for nothing.
    private var silent: [pid_t: (times: Int, until: Date)] = [:]
    /// Apps whose windows may have changed since they were last asked, and whether any app's may have.
    private var stale: Set<pid_t> = []
    private var allStale = true
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private let isTrusted: () -> Bool
    private let now: () -> Date

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }, now: @escaping () -> Date = { .now }) {
        self.isTrusted = isTrusted
        self.now = now
    }

    isolated deinit {
        stop()
    }

    var isReady: Bool { isTrusted() }

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        // A change of Space or display changes which windows are on screen in any app.
        for (center, name) in [
            (workspace, NSWorkspace.activeSpaceDidChangeNotification), (.default, NSApplication.didChangeScreenParametersNotification),
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.allStale = true
                    self?.onChange()
                }
            }
            tokens.append((center, token))
        }
        // These are about one app. An app launched without coming to the front is only heard of by its launch.
        for name in [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
        ] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    if let pid { self?.stale.insert(pid) } else { self?.allStale = true }
                    self?.onChange()
                }
            }
            tokens.append((workspace, token))
        }
        allStale = true
        let token = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.appQuit(pid) }
            }
        }
        tokens.append((workspace, token))
    }

    func stop() {
        for (center, token) in tokens {
            center.removeObserver(token)
        }
        tokens = []
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers = [:]
        ids = [:]
        windows = [:]
        floating = []
        passedOver = [:]
        lastSeen = [:]
        silent = [:]
        stale = []
        allStale = true
    }

    // MARK: Windows

    func snapshot() -> LaneSnapshot {
        let own = ProcessInfo.processInfo.processIdentifier
        let now = now()
        var found: [LaneSnapshot.Window] = []
        var visited: Set<pid_t> = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && !app.isTerminated && app.processIdentifier != own {
            let pid = app.processIdentifier
            visited.insert(pid)
            // An app is asked when it said something changed, when a window of its is due
            // another look, or when it's never been asked. One that isn't answering is asked
            // only once its time is up. The rest keep the windows they had: an app that's quiet
            // or busy still has them.
            let asks: Bool
            if let quiet = silent[pid] {
                asks = quiet.until <= now
            } else {
                let isDue = passedOver[pid]?.values.contains { $0.again <= now } ?? false
                asks = allStale || stale.contains(pid) || isDue || lastSeen[pid] == nil
            }
            // Only apps that say when their windows close are arranged. One that has only just
            // launched may not answer yet either, and is tried again like any that doesn't.
            // Accessibility lists the windows on the Spaces showing now, minimized ones included.
            guard asks, observe(pid), let listed = AXWindow.answeredWindows(of: pid, timeout: Self.patience) else {
                if asks { fellSilent(pid) }
                found += (lastSeen[pid] ?? []).filter { !floating.contains($0.id) }
                continue
            }
            silent[pid] = nil
            var seen: [LaneSnapshot.Window] = []
            var stillPassedOver: [Element: (again: Date, checks: Int)] = [:]
            for window in listed {
                let key = Element(element: window.element)
                let before = passedOver[pid]?[key]
                if let before, before.again > now {
                    stillPassedOver[key] = before
                    continue
                }
                guard let id = id(for: window) else {
                    let checks = (before?.checks ?? 0) + 1
                    stillPassedOver[key] = (checks > 3 ? .distantFuture : now.addingTimeInterval(pow(2, Double(checks - 1))), checks)
                    continue
                }
                guard !floating.contains(id), !window.isMinimized, !window.isFullScreen, let frame = window.frame else { continue }
                seen.append(LaneSnapshot.Window(id: id, frame: frame))
            }
            passedOver[pid] = stillPassedOver
            lastSeen[pid] = seen
            found += seen
        }
        // An app no longer looked at, hidden for one, isn't waited on to answer, or to have
        // its windows looked at again.
        silent = silent.filter { visited.contains($0.key) }
        passedOver = passedOver.filter { visited.contains($0.key) }
        stale = []
        allStale = false
        return LaneSnapshot(
            displays: NSScreen.screens.map {
                LaneDisplay(key: Displays.key(for: $0), frame: Displays.flip($0.frame), area: Displays.usableArea(of: $0))
            },
            windows: found,
            focused: focusedID().flatMap { id in found.contains { $0.id == id } ? id : nil },
            mainDisplay: NSScreen.main.map { Displays.key(for: $0) },
            pointer: Displays.flip(NSEvent.mouseLocation))
    }

    /// How long to leave an app alone after it hasn't answered `times` times running: a second
    /// at first, doubling to half a minute.
    static func wait(afterSilences times: Int) -> TimeInterval {
        min(30, pow(2, Double(max(times, 1) - 1)))
    }

    /// The frontmost app's focused window, if it's a known one and its app is answering.
    private func focusedID() -> Int? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, silent[pid] == nil else { return nil }
        return AXWindow.focused(timeout: Self.patience).flatMap { ids[Element(element: $0.element)] }
    }

    func apply(_ move: LaneMove) -> CGRect? {
        guard let window = windows[move.id], silent[window.pid] == nil else { return nil }
        // Asked one thing first: an app that has hung since the last look would otherwise be
        // waited on for every part of the move in turn, and its other windows after it.
        guard window.isAnswering else {
            fellSilent(window.pid)
            return nil
        }
        if move.resizes {
            window.setFrame(move.frame, appTimeout: Self.patience)
        } else {
            window.move(to: move.frame.origin, appTimeout: Self.patience)
        }
        guard let frame = window.frame else {
            // Its app answers, so it's the window that's gone, without having said so.
            gone(move.id)
            return nil
        }
        remember(frame, of: move.id, in: window.pid)
        return frame
    }

    private func gone(_ id: Int) {
        guard let window = windows.removeValue(forKey: id) else { return }
        ids[Element(element: window.element)] = nil
        lastSeen[window.pid]?.removeAll { $0.id == id }
        close(id)
    }

    func frame(of id: Int) -> CGRect? {
        guard let window = windows[id], silent[window.pid] == nil, let frame = window.frame else { return nil }
        remember(frame, of: id, in: window.pid)
        return frame
    }

    func askAgain() {
        silent = [:]
        allStale = true
    }

    var askAgainAt: Date? {
        // An app that isn't answering is next asked when its own time is up, not when a window of its is due.
        let due = silent.values.map(\.until) + passedOver.filter { silent[$0.key] == nil }.values.flatMap { $0.values.map(\.again) }
        // Whatever was due by now was seen to at the last look; a time gone by is nothing to wait for.
        let now = now()
        return due.filter { $0 > now && $0 != .distantFuture }.min()
    }

    /// How long to wait on an app, in seconds: one that's hung stops holding things up after
    /// this, not the six seconds Accessibility waits by default.
    private static let patience: Float = 0.5

    /// Keeps what's known of a window's frame up with a move made here, which isn't looked into again.
    private func remember(_ frame: CGRect, of id: Int, in pid: pid_t) {
        guard let index = lastSeen[pid]?.firstIndex(where: { $0.id == id }) else { return }
        lastSeen[pid]?[index] = LaneSnapshot.Window(id: id, frame: frame)
    }

    private func fellSilent(_ pid: pid_t) {
        let times = (silent[pid]?.times ?? 0) + 1
        silent[pid] = (times, now().addingTimeInterval(Self.wait(afterSilences: times)))
    }

    func slide(_ id: Int, to origin: CGPoint) {
        guard let window = windows[id], silent[window.pid] == nil else { return }
        window.nudge(to: origin)
        // Nothing is heard back, so where it really ended up is asked at the next look.
        stale.insert(window.pid)
    }

    func owner(of id: Int) -> pid_t? {
        windows[id]?.pid
    }

    func isHeldUp(_ id: Int) -> Bool {
        windows[id].map { silent[$0.pid] != nil } ?? false
    }

    func focus(_ id: Int) {
        guard let window = windows[id], silent[window.pid] == nil else { return }
        window.raise(appTimeout: Self.patience)
    }

    func toggleFloating() -> Int? {
        guard let focused = AXWindow.focused(timeout: Self.patience), let id = id(for: focused) else { return nil }
        // In or out, its app's windows are counted afresh.
        stale.insert(focused.pid)
        if floating.remove(id) != nil { return nil }
        floating.insert(id)
        return id
    }

    /// The window's number, given the first time it's seen as one that can be arranged: an
    /// ordinary window that can be resized, not a dialog, panel or fixed-size window.
    private func id(for window: AXWindow) -> Int? {
        let key = Element(element: window.element)
        if let known = ids[key] { return known }
        guard window.isPlainWindow, window.isResizable, let observer = observers[window.pid] else { return nil }
        let id = nextID
        nextID += 1
        ids[key] = id
        windows[id] = window
        for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, window.element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        return id
    }

    // MARK: Changes

    /// Starts listening to an app's windows. Says whether it's being listened to.
    private func observe(_ pid: pid_t) -> Bool {
        if observers[pid] != nil { return true }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            let name = notification as String
            // Delivered on the main run loop, where the observer's source is added.
            MainActor.assumeIsolated {
                Unmanaged<LiveLaneWindows>.fromOpaque(context).takeUnretainedValue().changed(name, element)
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.patience)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, context) == .success else { return false }
        for name in [kAXFocusedWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, context)
        }
        // Common modes, so changes still arrive while a menu is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        return true
    }

    private func changed(_ notification: String, _ element: AXUIElement) {
        let key = Element(element: element)
        if notification == kAXUIElementDestroyedNotification, let id = ids[key] { gone(id) }
        // Moves made here are reported back like any other, and looked into like any other: an
        // app may have changed the window again by then, to a size of its own for one.
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success {
            stale.insert(pid)
            // A window passed over that now has something to say may have become one to arrange.
            passedOver[pid]?[key] = nil
        } else {
            allStale = true
        }
        onChange()
    }

    private func appQuit(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        lastSeen[pid] = nil
        passedOver[pid] = nil
        silent[pid] = nil
        let closed = windows.filter { $0.value.pid == pid }.map(\.key).sorted()
        ids = ids.filter { !closed.contains($0.value) }
        for id in closed {
            windows[id] = nil
            close(id)
        }
        onChange()
    }

    private func close(_ id: Int) {
        floating.remove(id)
        onClose(id)
    }
}
