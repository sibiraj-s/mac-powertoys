import AppKit
import Carbon.HIToolbox
import Testing

@testable import PowerToys

struct TypingPlanTests {
    @Test func typesEachCharacterAsUnicode() {
        #expect(TypingPlan.steps(for: "aé", newline: .return) == [.text("a"), .text("é")])
    }

    @Test func keepsEmojiAndFlagsWhole() {
        #expect(TypingPlan.steps(for: "👩‍👩‍👧🇮🇳", newline: .return) == [.text("👩‍👩‍👧"), .text("🇮🇳")])
    }

    @Test func pressesReturnAndTabForLineBreaksAndTabs() {
        let steps = TypingPlan.steps(for: "a\r\nb\nc\td", newline: .return)
        #expect(
            steps == [
                .text("a"), .key(code: kVK_Return), .text("b"), .key(code: kVK_Return), .text("c"), .key(code: kVK_Tab), .text("d"),
            ])
    }

    @Test func lineBreaksCanPressShiftReturn() {
        #expect(TypingPlan.steps(for: "a\nb", newline: .shiftReturn) == [.text("a"), .key(code: kVK_Return, shift: true), .text("b")])
    }

    @Test func skipsOtherControlCharacters() {
        #expect(TypingPlan.steps(for: "a\u{0}\u{7}b", newline: .return) == [.text("a"), .text("b")])
    }

    @Test func formFeedAndVerticalTabDoNotPressReturn() {
        #expect(TypingPlan.steps(for: "a\u{B}\u{C}\u{85}b", newline: .return) == [.text("a"), .text("b")])
        #expect(
            TypingPlan.steps(for: "a\u{2028}b\u{2029}", newline: .return) == [
                .text("a"), .key(code: kVK_Return), .text("b"), .key(code: kVK_Return),
            ])
    }

    @Test func trimsOnlyTrailingLineBreaks() {
        #expect("abc\n\r\n".trimmingTrailingNewlines == "abc")
        #expect("abc \n".trimmingTrailingNewlines == "abc ")
        #expect("\na\nb".trimmingTrailingNewlines == "\na\nb")
        #expect("\n\n".trimmingTrailingNewlines == "")
    }

    @Test func longCharactersAreSplitBetweenScalars() {
        // "a" and 18 combining marks (19 units) then an emoji: cutting at 20 UTF-16 units would split the emoji's surrogate pair.
        let text = "a" + String(repeating: "\u{301}", count: 18) + "😀"
        let chunks = LiveKeystrokePoster.chunks(of: text)
        #expect(chunks.map(\.count) == [19, 2])
        #expect(chunks.allSatisfy { $0.count <= 20 })
        #expect(String(utf16CodeUnits: chunks.flatMap { $0 }, count: text.utf16.count) == text)
    }
}

/// A keyboard that records what's typed into it.
final class FakeTypingKeys {
    var posted: [TypingStep] = []
    var frontmost: pid_t? = 42
    var modifiersHeld = false
    var escapeDown = false
    /// How many times the typer has looked at Esc.
    var escapeChecks = 0
    var focused: pid_t? = 42
    /// Whether input is being watched, and what was done meanwhile.
    var isWatching = false
    var escapeCaught = false
    var interrupted = false
    var beeps = 0
    var afterPost: (Int) -> Void = { _ in }

    var keys: TypingKeys {
        TypingKeys(
            post: { [unowned self] step in
                posted.append(step)
                afterPost(posted.count)
            },
            frontmostApp: { [unowned self] in frontmost },
            focusedApp: { [unowned self] in focused },
            modifiersHeld: { [unowned self] in modifiersHeld },
            escapeDown: { [unowned self] in
                escapeChecks += 1
                return escapeDown
            },
            watchInput: { [unowned self] in
                isWatching = true
                return InputWatch(
                    escapePressed: { [unowned self] in escapeCaught }, interrupted: { [unowned self] in interrupted },
                    stop: { [unowned self] in isWatching = false })
            }
        )
    }
}

struct ClipboardTyperTests {
    private let store = TestDefaults()
    private let keyboard = FakeTypingKeys()

    private func typer(isTrusted: Bool = true) -> ClipboardTyper {
        let typer = ClipboardTyper(
            defaults: store.defaults, keys: keyboard.keys, isTrusted: { isTrusted }, settleDelay: .zero, showsStatus: false,
            beep: { [keyboard] in keyboard.beeps += 1 })
        typer.speed = .fast
        return typer
    }

    @Test func defaults() {
        let typer = ClipboardTyper(defaults: store.defaults, keys: keyboard.keys, showsStatus: false)
        #expect(typer.speed == .normal)
        #expect(typer.newline == .return)
        #expect(typer.trimsTrailingNewlines)
        #expect(!typer.isTyping)
    }

    @Test func settingsPersist() {
        let typer = typer()
        typer.speed = .slow
        typer.newline = .shiftReturn
        typer.trimsTrailingNewlines = false

        let relaunched = ClipboardTyper(defaults: store.defaults, keys: keyboard.keys, showsStatus: false)
        #expect(relaunched.speed == .slow)
        #expect(relaunched.newline == .shiftReturn)
        #expect(!relaunched.trimsTrailingNewlines)
    }

    @Test func typesTheTextWithoutTheTrailingLineBreak() async {
        let typer = typer()
        #expect(typer.type("hi\n"))
        #expect(typer.progress == .init(typed: 0, total: 2))
        await typer.waitUntilDone()
        #expect(keyboard.posted == [.text("h"), .text("i")])
        #expect(!typer.isTyping)
    }

    @Test func keepsTheTrailingLineBreakWhenAskedTo() async {
        let typer = typer()
        typer.trimsTrailingNewlines = false
        typer.type("hi\n")
        await typer.waitUntilDone()
        #expect(keyboard.posted == [.text("h"), .text("i"), .key(code: kVK_Return)])
    }

    @Test func stopsWhenAnotherAppComesForward() async {
        let typer = typer()
        keyboard.afterPost = { [keyboard] count in if count == 2 { keyboard.frontmost = 7 } }
        typer.type("abcdef")
        await typer.waitUntilDone()
        #expect(keyboard.posted == [.text("a"), .text("b")])
        #expect(!typer.isTyping)
    }

    @Test func capturesTheAppWhenAsked() async {
        let typer = typer()
        typer.type("abc")
        // Switched to another app while the clipboard panel was going away.
        keyboard.frontmost = 7
        await typer.waitUntilDone()
        #expect(keyboard.posted.isEmpty)
    }

    @Test func stopsWhenYouClickOrType() async {
        let typer = typer()
        keyboard.afterPost = { [keyboard] count in if count == 2 { keyboard.interrupted = true } }
        typer.type("abcdef")
        await typer.waitUntilDone()
        #expect(keyboard.posted == [.text("a"), .text("b")])
        #expect(keyboard.beeps == 1)
    }

    @Test func stopsWhenAnotherAppTakesTheKeyboard() async {
        let typer = typer()
        // Spotlight opened partway, without coming forward.
        keyboard.afterPost = { [keyboard] count in if count == 2 { keyboard.focused = 99 } }
        typer.type("abcdef")
        await typer.waitUntilDone()
        #expect(keyboard.posted == [.text("a"), .text("b")])
        #expect(keyboard.beeps == 1)
    }

    @Test func keepsTypingWhenTheAppIsSlowToSayWhereFocusIs() async {
        let typer = typer()
        keyboard.afterPost = { [keyboard] count in if count == 2 { keyboard.focused = nil } }
        typer.type("abcd")
        await typer.waitUntilDone()
        #expect(keyboard.posted.count == 4)
    }

    @Test func waitsForTheKeyboardToComeBackFromThePanel() async {
        let typer = typer()
        keyboard.focused = getpid()
        typer.type("ab")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(keyboard.posted.isEmpty)
        keyboard.focused = 42
        await typer.waitUntilDone()
        #expect(keyboard.posted == [.text("a"), .text("b")])
        #expect(keyboard.beeps == 0)
    }

    @Test func typesNothingWhenAPanelOfAnotherAppKeepsTheKeyboard() async {
        let typer = typer()
        keyboard.focused = 99
        typer.type("abc")
        await typer.waitUntilDone()
        #expect(keyboard.posted.isEmpty)
        #expect(keyboard.beeps == 1)
    }

    @Test func typesWhereAccessibilityCannotTellTheFocus() async {
        let typer = typer()
        keyboard.focused = nil
        typer.type("ab")
        await typer.waitUntilDone()
        #expect(keyboard.posted == [.text("a"), .text("b")])
    }

    @Test func saysWhenTheFirstKeyIsTyped() async {
        var starts = 0
        let typer = typer()
        typer.type("ab") { starts += 1 }
        await typer.waitUntilDone()
        #expect(starts == 1)

        keyboard.focused = 99
        typer.type("ab") { starts += 1 }
        await typer.waitUntilDone()
        #expect(starts == 1)
    }

    @Test func stopsWhenEscapeIsCaught() async {
        let typer = typer()
        keyboard.afterPost = { [keyboard] count in if count == 2 { keyboard.escapeCaught = true } }
        typer.type("abcdef")
        #expect(keyboard.isWatching)
        await typer.waitUntilDone()
        #expect(keyboard.posted.count == 2)
        // Esc goes back to apps once typing is over.
        #expect(!keyboard.isWatching)
        #expect(keyboard.beeps == 0)
    }

    @Test func escapePressedWhileWaitingStillStops() async {
        let typer = typer()
        keyboard.modifiersHeld = true
        typer.type("ab")
        keyboard.escapeCaught = true
        keyboard.modifiersHeld = false
        await typer.waitUntilDone()
        #expect(keyboard.posted.isEmpty)
    }

    @Test func aQuickEscapeIsRemembered() async {
        let typer = typer()
        keyboard.modifiersHeld = true
        typer.type("ab")
        keyboard.escapeDown = true
        let checks = keyboard.escapeChecks
        while keyboard.escapeChecks == checks { try? await Task.sleep(for: .milliseconds(5)) }
        keyboard.escapeDown = false
        keyboard.modifiersHeld = false
        await typer.waitUntilDone()
        #expect(keyboard.posted.isEmpty)
    }

    @Test func stopsWhenEscapeIsDown() async {
        let typer = typer()
        keyboard.afterPost = { [keyboard] count in if count == 3 { keyboard.escapeDown = true } }
        typer.type("abcdef")
        await typer.waitUntilDone()
        #expect(keyboard.posted.count == 3)
    }

    @Test func cancelStopsTyping() async {
        let typer = typer()
        keyboard.afterPost = { [weak typer] count in if count == 3 { typer?.cancel() } }
        typer.type("abcdef")
        await typer.waitUntilDone()
        #expect(keyboard.posted.count == 3)
        #expect(!typer.isTyping)
    }

    @Test func waitsForHeldModifiersToComeUp() async {
        let typer = typer()
        keyboard.modifiersHeld = true
        typer.type("ab")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(keyboard.posted.isEmpty)
        keyboard.modifiersHeld = false
        await typer.waitUntilDone()
        #expect(keyboard.posted == [.text("a"), .text("b")])
    }

    @Test func typesNothingWithoutPermissionOrText() {
        #expect(!typer(isTrusted: false).canType("secret"))
        #expect(!typer(isTrusted: false).type("secret"))
        #expect(!typer().type("\n\n"))
        #expect(!typer().type(""))
        #expect(keyboard.posted.isEmpty)
    }

    @Test func typesNothingWithNoAppInFront() {
        let typer = typer()
        keyboard.frontmost = nil
        #expect(!typer.canType("abc"))
        #expect(!typer.type("abc"))
        #expect(!keyboard.isWatching)
    }

    @Test func doesNotStartTwice() {
        let typer = typer()
        #expect(typer.type("abc"))
        #expect(!typer.canType("def"))
        #expect(!typer.type("def"))
        typer.cancel()
    }
}

struct ClipboardTypeCommandTests {
    @Test func typeIsOfferedForTextButNotImagesOrFiles() {
        let text = ClipItem(text: "hello", date: .now)
        #expect(ClipCommand.available(for: text) == [.paste(.original), .type, .copy, .togglePin, .delete])

        let files = ClipItem(text: "/tmp/a", fileURLs: [URL(filePath: "/tmp/a")], date: .now)
        #expect(!ClipCommand.available(for: files).contains(.type))
        let image = ClipItem(text: "words", image: .init(fileName: "a.png", width: 1, height: 1, byteCount: 1, digest: "d"), date: .now)
        #expect(!ClipCommand.available(for: image).contains(.type))
    }

    @Test func typeIsHiddenWhenThereIsNothingToType() {
        for text in ["", "   ", "\n\t\n", "\u{0}\u{7}"] {
            #expect(!ClipCommand.available(for: ClipItem(text: text, date: .now)).contains(.type), "\(text.debugDescription)")
        }
        #expect(ClipCommand.available(for: ClipItem(text: " a ", date: .now)).contains(.type))
        #expect(ClipCommand.available(for: ClipItem(text: "#FF8800", date: .now)).contains(.type))
    }

    @Test func typeIsHiddenForTextTooLongToType() {
        let longest = String(repeating: "a", count: ClipItem.maxTypedLength)
        #expect(ClipItem(text: longest, date: .now).typedText != nil)
        #expect(ClipItem(text: longest + "a", date: .now).typedText == nil)
    }

    @Test func onlyLaunchersOverTheAppInFrontAreClosed() {
        // Spotlight has the keyboard while Safari is in front.
        #expect(ClipboardPanel.launcher(focusedApp: 9, frontmostApp: 5, bundleID: "com.apple.Spotlight") == 9)
        #expect(ClipboardPanel.launcher(focusedApp: 9, frontmostApp: 5, bundleID: "com.raycast.macos") == 9)
        #expect(ClipboardPanel.launcher(focusedApp: 5, frontmostApp: 5, bundleID: "com.raycast.macos") == nil)
        #expect(ClipboardPanel.launcher(focusedApp: nil, frontmostApp: 5, bundleID: nil) == nil)
        #expect(ClipboardPanel.launcher(focusedApp: 9, frontmostApp: nil, bundleID: "com.apple.Spotlight") == nil)
        // Anything else with the keyboard, such as an app just switched to or a save panel, keeps it.
        #expect(ClipboardPanel.launcher(focusedApp: 9, frontmostApp: 5, bundleID: "com.apple.finder") == nil)
        #expect(ClipboardPanel.launcher(focusedApp: 9, frontmostApp: 5, bundleID: nil) == nil)
    }

    @Test func commandKeyTTypes() {
        #expect(ClipboardPanel.command(keyCode: kVK_ANSI_T, flags: .command) == .type)
        #expect(ClipCommand.type.keyCaps == ["⌘", "T"])
        #expect(ClipCommand.type.title(for: ClipItem(text: "x", date: .now)) == "Type")
    }
}
