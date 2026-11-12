import AppKit

/// An event tap, which sees input before apps do and can keep it from them. Tapping needs
/// Accessibility: this installs the tap once that's allowed, trying again every two seconds
/// until it is, and turns the tap back on when macOS turns it off for being slow to answer.
final class EventTap {
    /// Where the tap's handler runs. It returns whether the event goes on to apps, and also
    /// gets the two events that say the tap had been turned off, after it's back on.
    enum Handler {
        /// On the main thread, for taps that change the app's own state. Every tapped event
        /// waits on the main thread.
        case onMain(@MainActor (CGEventType, CGEvent) -> Bool)
        /// On a thread of the tap's own, so events never wait on the main thread.
        case onOwnThread(name: String, @Sendable (CGEventType, CGEvent) -> Bool)
    }

    private let location: CGEventTapLocation
    private let placement: CGEventTapPlacement
    private let events: CGEventMask
    private let isTrusted: () -> Bool
    private let handler: Handler
    private let onInstall: () -> Void
    private var port: EventTapPort?
    private var retryTimer: Timer?

    /// - Parameter onInstall: Called once the tap is in, which may be long after `start`.
    init(
        at location: CGEventTapLocation = .cgSessionEventTap, placement: CGEventTapPlacement = .headInsertEventTap,
        events: CGEventMask, isTrusted: @escaping () -> Bool, handler: Handler, onInstall: @escaping () -> Void = {}
    ) {
        self.location = location
        self.placement = placement
        self.events = events
        self.isTrusted = isTrusted
        self.handler = handler
        self.onInstall = onInstall
    }

    isolated deinit {
        stop()
    }

    static func mask(of types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }

    /// Whether the tap is in and seeing events.
    var isInstalled: Bool { port != nil }
    /// Whether it's installed or still waiting for Accessibility.
    var isRunning: Bool { port != nil || retryTimer != nil }

    func start() {
        guard !isRunning else { return }
        install()
        guard port == nil else { return }
        // Accessibility may be allowed later, in System Settings; keep trying until it is.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.install() }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        port?.stop()
        port = nil
    }

    private func install() {
        guard port == nil, isTrusted() else { return }
        let made: EventTapPort?
        switch handler {
        case .onMain(let handle):
            // The tap's source is on the main run loop, so its handler runs on the main thread.
            made = EventTapPort.make(at: location, placement: placement, events: events, threadName: nil) { type, event in
                // Only this thread has the event: it's handed over for the length of the call.
                nonisolated(unsafe) let event = event
                return MainActor.assumeIsolated { handle(type, event) }
            }
        case .onOwnThread(let name, let handle):
            made = EventTapPort.make(at: location, placement: placement, events: events, threadName: name, handle: handle)
        }
        guard let made else { return }
        port = made
        retryTimer?.invalidate()
        retryTimer = nil
        onInstall()
    }
}

/// The tap itself and the run loop it's on: the main one, or that of a thread of its own.
private nonisolated final class EventTapPort: @unchecked Sendable {
    private let handle: @Sendable (CGEventType, CGEvent) -> Bool
    // Only touched on the tap's run loop once it runs.
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The tap's own thread's run loop, set before `make` returns; nil for a tap on the main one.
    private var ownRunLoop: CFRunLoop?

    private init(handle: @escaping @Sendable (CGEventType, CGEvent) -> Bool) {
        self.handle = handle
    }

    static func make(
        at location: CGEventTapLocation, placement: CGEventTapPlacement, events: CGEventMask, threadName: String?,
        handle: @escaping @Sendable (CGEventType, CGEvent) -> Bool
    ) -> EventTapPort? {
        let port = EventTapPort(handle: handle)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let port = Unmanaged<EventTapPort>.fromOpaque(refcon).takeUnretainedValue()
            return port.process(type, event) ? Unmanaged.passUnretained(event) : nil
        }
        // The tap calls back with an unretained pointer to the port, which is kept until `stop`.
        guard
            let tap = CGEvent.tapCreate(
                tap: location, place: placement, options: .defaultTap, eventsOfInterest: events, callback: callback,
                userInfo: Unmanaged.passUnretained(port).toOpaque())
        else { return nil }
        port.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        port.source = source
        guard let threadName else {
            // Common modes, so events still come while a menu is open or a drag tracks the mouse.
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return port
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            guard let tap = port.tap, let source = port.source else {
                ready.signal()
                return
            }
            port.ownRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = threadName
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return port
    }

    func stop() {
        guard let ownRunLoop else {
            end()
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            source = nil
            return
        }
        // Ended on its own thread, which may be using it at that moment.
        self.ownRunLoop = nil
        CFRunLoopPerformBlock(ownRunLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            end()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(ownRunLoop)
    }

    private func end() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns off a tap that's slow to answer; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            _ = handle(type, event)
            return true
        }
        return handle(type, event)
    }
}
