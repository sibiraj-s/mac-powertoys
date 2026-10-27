import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// A settings row for one shortcut: its keys, which you click to record new ones, plus a reset
/// button once they differ from the default.
struct ShortcutRow: View {
    let definition: ShortcutDefinition

    @Environment(AppState.self) private var state
    @State private var problem: String?

    var body: some View {
        let shortcuts = state.shortcuts
        CardRow(definition.title, hint: hint) {
            HStack(spacing: 6) {
                if shortcuts.isCustomized(definition) {
                    Button {
                        problem = nil
                        shortcuts.reset(definition)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(resetHelp)
                }
                ShortcutRecorder(
                    hotKey: shortcuts.hotKey(for: definition),
                    isUnavailable: shortcuts.unavailable.contains(definition.id),
                    validate: { shortcuts.problem(with: $0, for: definition) },
                    onProblem: { problem = $0 },
                    onChange: { shortcuts.set($0, for: definition) },
                    onRecordingChange: { $0 ? shortcuts.suspend() : shortcuts.resume() }
                )
            }
        }
    }

    private var hint: String? {
        if let problem { return problem }
        if state.shortcuts.unavailable.contains(definition.id) { return "Another app is using this shortcut." }
        return nil
    }

    private var resetHelp: String {
        guard let original = definition.defaultHotKey else { return "Remove shortcut" }
        return "Reset to \(original.keyCaps.joined())"
    }
}

/// Shows a shortcut as keycaps; click it, then press new keys. ⎋ cancels and ⌫ removes the shortcut.
struct ShortcutRecorder: View {
    let hotKey: HotKey?
    var isUnavailable = false
    /// Why keys can't be used, shown while recording continues.
    let validate: (HotKey) -> String?
    let onProblem: (String?) -> Void
    let onChange: (HotKey?) -> Void
    let onRecordingChange: (Bool) -> Void

    @State private var recorder = KeyRecorder()

    var body: some View {
        Button {
            recorder.isRecording ? stop() : start()
        } label: {
            label
                .padding(.horizontal, 4)
                .frame(minWidth: 96, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(recorder.isRecording ? Color.accentColor : .clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recorder.isRecording ? "Press keys. ⎋ cancels, ⌫ removes the shortcut." : "Click to change")
        .accessibilityLabel(hotKey.map { "Shortcut \($0.keyCaps.joined())" } ?? "No shortcut")
        .accessibilityHint("Click, then press the new keys")
        .onDisappear { stop() }
    }

    @ViewBuilder
    private var label: some View {
        if recorder.isRecording {
            Text(recorder.heldModifiers.isEmpty ? "Press keys…" : HotKey.modifierSymbols(recorder.heldModifiers) + "…")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
        } else if let hotKey {
            KeyCaps(keys: hotKey.keyCaps)
                .opacity(isUnavailable ? 0.5 : 1)
        } else {
            Text("Record shortcut")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private func start() {
        onProblem(nil)
        onRecordingChange(true)
        recorder.start { result in
            switch result {
            case .cancelled:
                stop()
            case .cleared:
                onChange(nil)
                stop()
            case .keys(let keys):
                if let problem = validate(keys) {
                    onProblem(problem)
                    NSSound.beep()
                } else {
                    onChange(keys)
                    stop()
                }
            }
        }
    }

    private func stop() {
        guard recorder.isRecording else { return }
        recorder.stop()
        onRecordingChange(false)
    }
}

/// Watches key presses in the app while recording.
@Observable
final class KeyRecorder {
    enum Result: Equatable {
        case keys(HotKey)
        case cancelled
        case cleared
    }

    private(set) var isRecording = false
    private(set) var heldModifiers: NSEvent.ModifierFlags = []

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var handler: ((Result) -> Void)?

    func start(_ handler: @escaping (Result) -> Void) {
        stop()
        self.handler = handler
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Local monitors run on the main thread. Only a Bool crosses back, since NSEvent isn't Sendable.
            let isHandled = MainActor.assumeIsolated {
                self?.handle(type: event.type, keyCode: Int(event.keyCode), modifiers: event.modifierFlags,
                             characters: event.characters(byApplyingModifiers: [])) ?? false
            }
            return isHandled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        handler = nil
        isRecording = false
        heldModifiers = []
    }

    /// Returns whether the event was used.
    @discardableResult
    func handle(type: NSEvent.EventType, keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard isRecording else { return false }
        let modifiers = modifiers.intersection(HotKey.supportedModifiers)
        if type == .flagsChanged {
            heldModifiers = modifiers
            return false
        }
        if let result = Self.result(keyCode: keyCode, modifiers: modifiers, characters: characters) {
            handler?(result)
        } else {
            NSSound.beep()
        }
        return true
    }

    /// What a key press means while recording; nil for keys that can't be a shortcut.
    static func result(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> Result? {
        if modifiers.isEmpty {
            if keyCode == kVK_Escape { return .cancelled }
            if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete { return .cleared }
        }
        guard let key = HotKey.keyName(keyCode: keyCode, characters: characters) else { return nil }
        return .keys(HotKey(keyCode: keyCode, modifiers: modifiers, key: key))
    }
}

extension HotKey {
    /// "⌃⌥" and so on, in the order macOS draws them.
    static func modifierSymbols(_ modifiers: NSEvent.ModifierFlags) -> String {
        HotKey(keyCode: 0, modifiers: modifiers, key: "").keyCaps.dropLast().joined()
    }
}
