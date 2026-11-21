import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import Synchronization

/// Types a clipboard item into the focused field one key at a time, for fields that block pasting.
@Observable
final class ClipboardTyper {
    /// The pause between keys. Some web pages and remote sessions drop keys that come too fast.
    enum Speed: Int, CaseIterable, Identifiable {
        case fast = 4
        case normal = 12
        case slow = 40

        var id: Self { self }

        var title: String {
            switch self {
            case .fast: "Fast"
            case .normal: "Normal"
            case .slow: "Slow"
            }
        }

        var delay: Duration { .milliseconds(rawValue) }
    }

    struct Progress: Equatable {
        var typed: Int
        let total: Int
    }

    var speed: Speed {
        didSet { defaults.set(speed.rawValue, forKey: Self.speedKey) }
    }

    var newline: NewlineKey {
        didSet { defaults.set(newline.rawValue, forKey: Self.newlineKey) }
    }

    /// Leave out line breaks at the end, so a copied trailing newline doesn't submit a form.
    var trimsTrailingNewlines: Bool {
        didSet { defaults.set(trimsTrailingNewlines, forKey: Self.trimsTrailingNewlinesKey) }
    }

    /// How far typing has got; nil when nothing is being typed.
    private(set) var progress: Progress?

    var isTyping: Bool { progress != nil }

    static let speedKey = "clipboard.typeSpeed"
    static let newlineKey = "clipboard.typeNewline"
    static let trimsTrailingNewlinesKey = "clipboard.typeTrimsTrailingNewlines"

    private let defaults: UserDefaults
    @ObservationIgnored private let keys: TypingKeys
    @ObservationIgnored private let isTrusted: () -> Bool
    /// How long to wait for the clipboard panel to go and the field's window to take keys again.
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private let showsStatus: Bool
    @ObservationIgnored private let beep: () -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Set once Esc is pressed while typing, so a quick tap between two checks still counts.
    @ObservationIgnored private var escapePressed = false
    @ObservationIgnored private var watch: InputWatch?
    @ObservationIgnored private lazy var status = TypingStatusPanel(typer: self)

    /// How long the keyboard has to come back from the clipboard panel to the app.
    static let focusPatience: Duration = .milliseconds(500)

    /// With `showsStatus` off nothing is shown while typing, for tests.
    init(
        defaults: UserDefaults = .standard, keys: TypingKeys = .live, isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        settleDelay: Duration = .milliseconds(120), showsStatus: Bool = true, beep: @escaping () -> Void = { NSSound.beep() }
    ) {
        self.defaults = defaults
        self.keys = keys
        self.isTrusted = isTrusted
        self.settleDelay = settleDelay
        self.showsStatus = showsStatus
        self.beep = beep
        defaults.register(defaults: [Self.trimsTrailingNewlinesKey: true])
        speed = Speed(rawValue: defaults.integer(forKey: Self.speedKey)) ?? .normal
        newline = defaults.string(forKey: Self.newlineKey).flatMap(NewlineKey.init(rawValue:)) ?? .return
        trimsTrailingNewlines = defaults.bool(forKey: Self.trimsTrailingNewlinesKey)
    }

    /// The key presses `text` is typed with, as the settings are now.
    func steps(for text: String) -> [TypingStep] {
        TypingPlan.steps(for: trimsTrailingNewlines ? text.trimmingTrailingNewlines : text, newline: newline)
    }

    /// Whether `type` would start: there's something to type, an app in front to type into,
    /// nothing typing already, and Accessibility is allowed.
    func canType(_ text: String) -> Bool {
        !isTyping && isTrusted() && keys.frontmostApp() != nil && !steps(for: text).isEmpty
    }

    /// Types `text` into the frontmost app's focused field once the clipboard panel is gone,
    /// calling `onStart` once the first key is typed. The app is the one in front now, so
    /// switching apps while typing waits can't redirect it. It stops when Esc is pressed, you
    /// click or type, or another app comes forward or takes the keyboard. False when
    /// `canType` is.
    @discardableResult
    func type(_ text: String, onStart: @escaping () -> Void = {}) -> Bool {
        guard canType(text), let target = keys.frontmostApp() else { return false }
        let steps = steps(for: text)
        progress = Progress(typed: 0, total: steps.count)
        escapePressed = false
        watch = keys.watchInput()
        if showsStatus { status.show() }
        task = Task { [weak self] in
            await self?.run(steps, in: target, onStart: onStart)
            self?.finish()
        }
        return true
    }

    func cancel() {
        task?.cancel()
    }

    /// Returns once the current typing has finished or stopped.
    func waitUntilDone() async {
        await task?.value
    }

    /// Whether typing should stop quietly: it was cancelled or Esc was pressed. Esc is also read
    /// off the keyboard, since password fields hide key presses from the tap that catches it.
    private var isStopped: Bool {
        if keys.escapeDown() || watch?.escapePressed() == true { escapePressed = true }
        return Task.isCancelled || escapePressed
    }

    private func run(_ steps: [TypingStep], in target: pid_t, onStart: () -> Void) async {
        try? await Task.sleep(for: settleDelay)
        // Keys still held from ⌘T would turn typed keys into shortcuts, so wait for them to come up.
        let deadline = ContinuousClock.now + .seconds(2)
        while keys.modifiersHeld() {
            guard !isStopped else { return }
            guard ContinuousClock.now < deadline else {
                beep()
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The keyboard may still be with the clipboard panel; wait for it to come back to the app.
        // Panels such as Spotlight's take it without coming forward, and an app that doesn't say
        // where it is is taken to have it.
        let focusDeadline = ContinuousClock.now + Self.focusPatience
        while let focused = await keys.focusedApp(), focused != target {
            guard !isStopped else { return }
            guard ContinuousClock.now < focusDeadline else {
                beep()
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        for (index, step) in steps.enumerated() {
            let focused = await keys.focusedApp()
            guard !isStopped else { return }
            // Focus may move within the app, as a Tab or a code box that moves on after each digit
            // does, but you clicking or typing elsewhere, or another app, stops it partway, with
            // nothing else to say so.
            guard watch?.interrupted() != true, keys.frontmostApp() == target, focused == nil || focused == target else {
                beep()
                return
            }
            keys.post(step)
            if index == 0 { onStart() }
            progress?.typed = index + 1
            if index < steps.count - 1 {
                try? await Task.sleep(for: speed.delay)
            }
        }
    }

    private func finish() {
        task = nil
        watch?.stop()
        watch = nil
        progress = nil
        if showsStatus { status.hide() }
    }
}

/// What you do on the keyboard and mouse while typing runs. Esc is kept from apps.
struct InputWatch {
    var escapePressed: () -> Bool
    /// You clicked, or pressed a key other than Esc.
    var interrupted: () -> Bool
    var stop: () -> Void
}

/// The keyboard as the typer sees it; replaced in tests so they don't type.
struct TypingKeys {
    var post: (TypingStep) -> Void
    var frontmostApp: () -> pid_t?
    /// The app with the keyboard; nil where Accessibility can't tell.
    var focusedApp: () async -> pid_t?
    var modifiersHeld: () -> Bool
    var escapeDown: () -> Bool
    var watchInput: () -> InputWatch

    static var live: TypingKeys {
        let poster = LiveKeystrokePoster()
        return TypingKeys(
            post: { poster.post($0) },
            frontmostApp: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            // An app that has hung could take seconds to say; not knowing doesn't stop typing.
            focusedApp: { await KeyboardFocus.appPID(within: .milliseconds(200)) },
            modifiersHeld: {
                !CGEventSource.flagsState(.combinedSessionState)
                    .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]).isEmpty
            },
            escapeDown: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape)) },
            watchInput: {
                let listener = InputListener()
                // On a thread of its own, so every key pressed meanwhile doesn't wait on the main one.
                let tap = EventTap(
                    events: EventTap.mask(of: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]),
                    isTrusted: { AXIsProcessTrusted() },
                    handler: .onOwnThread(name: "PowerToys typing input") { type, event in listener.process(type, event) })
                tap.start()
                return InputWatch(
                    escapePressed: { listener.state.withLock { $0.escape } },
                    interrupted: { listener.state.withLock { $0.interrupted } },
                    stop: { tap.stop() })
            }
        )
    }
}

/// Watches input on the tap's thread, swallowing Esc.
private nonisolated final class InputListener: Sendable {
    let state = Mutex((escape: false, interrupted: false))

    func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .keyDown, .keyUp:
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
                if type == .keyDown { state.withLock { $0.escape = true } }
                // The app being typed into would act on it too, closing a dialog or clearing the field.
                return false
            }
            // The keys being typed, and a key still repeating from ⌘T, aren't you typing.
            if type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != LiveKeystrokePoster.marker,
                event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            {
                state.withLock { $0.interrupted = true }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            state.withLock { $0.interrupted = true }
        default:
            break
        }
        return true
    }
}

/// A small note at the bottom of the screen while typing, with how to stop it. It never takes
/// keys or clicks, so the field being typed into keeps them.
private final class TypingStatusPanel {
    private unowned let typer: ClipboardTyper
    private var panel: NSPanel?

    private static let size = CGSize(width: 260, height: 34)

    init(typer: ClipboardTyper) {
        self.typer = typer
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: TypingStatusView(typer: typer))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            let origin = CGPoint(x: area.midX - Self.size.width / 2, y: area.minY + 60)
            panel.setFrame(CGRect(origin: origin, size: Self.size), display: false)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}

private struct TypingStatusView: View {
    let typer: ClipboardTyper

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
            if let progress = typer.progress {
                Text("Typing \(progress.typed) of \(progress.total)")
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Text("esc to stop")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.border.opacity(0.6)))
    }
}
