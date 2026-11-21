import AppKit
import Carbon.HIToolbox

/// One key press while typing text out.
enum TypingStep: Equatable {
    /// A character sent as Unicode, so it comes out right whatever the keyboard layout.
    case text(String)
    /// A key pressed by its code, for keys apps act on rather than insert, like Return and Tab.
    case key(code: Int, shift: Bool = false)
}

/// What a line break in the text is typed as.
enum NewlineKey: String, CaseIterable, Identifiable {
    case `return`, shiftReturn

    var id: Self { self }

    var title: String {
        switch self {
        case .return: "Return"
        case .shiftReturn: "⇧ Return"
        }
    }

    var hint: String {
        switch self {
        case .return: "Each line break presses Return, as in most text boxes."
        case .shiftReturn: "For chat apps where Return sends the message."
        }
    }
}

/// Turns text into the key presses that type it.
enum TypingPlan {
    /// What presses Return. Other characters Swift counts as newlines, such as form feed and
    /// vertical tab, are control characters and type nothing.
    static let lineBreaks: Set<Character> = ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"]

    static func steps(for text: String, newline: NewlineKey) -> [TypingStep] {
        var steps: [TypingStep] = []
        for character in text {
            if lineBreaks.contains(character) {
                steps.append(.key(code: kVK_Return, shift: newline == .shiftReturn))
            } else if character == "\t" {
                steps.append(.key(code: kVK_Tab))
            } else if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                // Other control characters type nothing an app would show.
                continue
            } else {
                steps.append(.text(String(character)))
            }
        }
        return steps
    }
}

extension String {
    /// Without the line breaks at the end, which would submit a form when typed.
    var trimmingTrailingNewlines: String {
        var text = Substring(self)
        while text.last?.isNewline == true { text.removeLast() }
        return String(text)
    }
}

/// Sends key presses to whatever has keyboard focus.
final class LiveKeystrokePoster {
    /// Its own key state, so modifiers held on the keyboard don't join the typed keys.
    private let source = CGEventSource(stateID: .privateState)

    /// The most UTF-16 units one key event carries.
    private static let maxUnits = 20

    /// Marks the keys it sends, so watching for your own typing can tell them apart.
    nonisolated static let marker: Int64 = 0x5054_5459  // "PTTY"

    func post(_ step: TypingStep) {
        switch step {
        case .text(let text):
            for chunk in Self.chunks(of: text) {
                for isDown in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                    event.flags = []
                    event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                    event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event.post(tap: .cgSessionEventTap)
                }
            }
        case .key(let code, let shift):
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: isDown) else { continue }
                event.flags = shift ? .maskShift : []
                event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// `text` as UTF-16 in pieces one key event can carry, split between Unicode scalars so a
    /// surrogate pair is never cut in half.
    static func chunks(of text: String) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if current.count + units.count > maxUnits {
                chunks.append(current)
                current = []
            }
            current += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
