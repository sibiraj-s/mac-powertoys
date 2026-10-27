import AppKit
import Carbon.HIToolbox
import Testing
@testable import PowerToys

/// Records registrations instead of taking real system-wide shortcuts. Keys in `taken` act as if
/// another app holds them.
final class FakeHotKeys: HotKeyRegistering {
    var taken: Set<HotKey> = []
    private(set) var registered: [HotKeyCenter.Registration: (hotKey: HotKey, action: () -> Void)] = [:]
    private var nextID: UInt32 = 1

    var hotKeys: Set<HotKey> { Set(registered.values.map(\.hotKey)) }

    func register(_ hotKey: HotKey, action: @escaping () -> Void) -> HotKeyCenter.Registration? {
        guard !taken.contains(hotKey) else { return nil }
        let registration = HotKeyCenter.Registration(id: nextID)
        nextID += 1
        registered[registration] = (hotKey, action)
        return registration
    }

    func unregister(_ registration: HotKeyCenter.Registration) {
        registered[registration] = nil
    }

    func press(_ hotKey: HotKey) {
        registered.values.first { $0.hotKey == hotKey }?.action()
    }
}

private let ctrlOptA = HotKey(keyCode: kVK_ANSI_A, modifiers: [.control, .option], key: "A")
private let ctrlOptB = HotKey(keyCode: kVK_ANSI_B, modifiers: [.control, .option], key: "B")
private let ctrlOptC = HotKey(keyCode: kVK_ANSI_C, modifiers: [.control, .option], key: "C")

private let first = ShortcutDefinition(id: "test.first", module: .zones, title: "First", defaultHotKey: ctrlOptA)
private let second = ShortcutDefinition(id: "test.second", module: .clipboard, title: "Second", defaultHotKey: ctrlOptB)
private let unset = ShortcutDefinition(id: "test.unset", module: .awake, title: "Unset", defaultHotKey: nil)

struct ShortcutsTests {
    private let store = TestDefaults()
    private let center = FakeHotKeys()

    private func shortcuts() -> Shortcuts {
        Shortcuts(defaults: store.defaults, catalog: [first, second, unset], center: center)
    }

    @Test func defaultsUntilCustomized() {
        let shortcuts = shortcuts()
        #expect(shortcuts.hotKey(for: first) == ctrlOptA)
        #expect(shortcuts.hotKey(for: unset) == nil)
        #expect(!shortcuts.isCustomized(first))
    }

    @Test func customKeysPersistAndReset() {
        let shortcuts = shortcuts()
        shortcuts.set(ctrlOptC, for: first)
        shortcuts.set(nil, for: second)
        shortcuts.set(ctrlOptB, for: unset)

        let reloaded = self.shortcuts()
        #expect(reloaded.hotKey(for: first) == ctrlOptC)
        #expect(reloaded.hotKey(for: second) == nil)   // turned off, not back to its default
        #expect(reloaded.isCustomized(second))
        #expect(reloaded.hotKey(for: unset) == ctrlOptB)

        reloaded.reset(first)
        reloaded.set(ctrlOptB, for: second)   // same as the default: no longer customized
        #expect(reloaded.hotKey(for: first) == ctrlOptA)
        #expect(!reloaded.isCustomized(first))
        #expect(!reloaded.isCustomized(second))
    }

    @Test func activeShortcutsFollowChanges() {
        let shortcuts = shortcuts()
        var presses = 0
        shortcuts.activate(first) { presses += 1 }
        #expect(center.hotKeys == [ctrlOptA])

        center.press(ctrlOptA)
        #expect(presses == 1)

        shortcuts.set(ctrlOptC, for: first)
        #expect(center.hotKeys == [ctrlOptC])
        center.press(ctrlOptC)
        #expect(presses == 2)

        shortcuts.set(nil, for: first)
        #expect(center.hotKeys.isEmpty)

        shortcuts.reset(first)
        #expect(center.hotKeys == [ctrlOptA])

        shortcuts.deactivate(first)
        #expect(center.hotKeys.isEmpty)
        #expect(!shortcuts.isActive(first))
    }

    @Test func inactiveShortcutsAreNotRegistered() {
        let shortcuts = shortcuts()
        shortcuts.set(ctrlOptC, for: first)
        #expect(center.hotKeys.isEmpty)
        shortcuts.activate(unset) {}
        #expect(center.hotKeys.isEmpty)   // no keys yet
    }

    @Test func takenKeysAreReportedAndRetried() {
        center.taken = [ctrlOptA]
        let shortcuts = shortcuts()
        shortcuts.activate(first) {}
        #expect(shortcuts.unavailable == ["test.first"])

        shortcuts.set(ctrlOptC, for: first)
        #expect(shortcuts.unavailable.isEmpty)
        #expect(center.hotKeys == [ctrlOptC])

        shortcuts.reset(first)
        #expect(shortcuts.unavailable == ["test.first"])
        shortcuts.deactivate(first)
        #expect(shortcuts.unavailable.isEmpty)
    }

    @Test func suspendingReleasesEverythingUntilResumed() {
        let shortcuts = shortcuts()
        shortcuts.activate(first) {}
        shortcuts.activate(second) {}
        shortcuts.suspend()
        #expect(center.hotKeys.isEmpty)

        // Changes while suspended wait for resume.
        shortcuts.set(ctrlOptC, for: first)
        #expect(center.hotKeys.isEmpty)

        shortcuts.resume()
        #expect(center.hotKeys == [ctrlOptC, ctrlOptB])
    }

    @Test func problems() {
        let shortcuts = shortcuts()
        #expect(shortcuts.problem(with: ctrlOptC, for: first) == nil)
        #expect(shortcuts.problem(with: ctrlOptA, for: first) == nil)   // its own keys

        #expect(shortcuts.problem(with: ctrlOptB, for: first) == "Already used for “Second” in Clipboard.")
        #expect(shortcuts.problem(with: HotKey(keyCode: kVK_ANSI_A, modifiers: [], key: "A"), for: first)?.hasPrefix("Add ⌘, ⌃ or ⌥") == true)
        #expect(shortcuts.problem(with: HotKey(keyCode: kVK_ANSI_A, modifiers: .shift, key: "A"), for: first) != nil)
        #expect(shortcuts.problem(with: HotKey(keyCode: kVK_ANSI_A, modifiers: .command, key: "A"), for: first)?.hasPrefix("Apps use ⌘") == true)
        #expect(shortcuts.problem(with: HotKey(keyCode: kVK_Space, modifiers: .command, key: "Space"), for: first) == "macOS uses this for Spotlight.")

        // Function keys work alone, and ⌘⇧ combinations are fine.
        #expect(shortcuts.problem(with: HotKey(keyCode: kVK_F5, modifiers: [], key: "F5"), for: first) == nil)
        #expect(shortcuts.problem(with: HotKey(keyCode: kVK_ANSI_V, modifiers: [.command, .shift], key: "V"), for: first) == nil)

        // A shortcut that was turned off frees its keys.
        shortcuts.set(nil, for: second)
        #expect(shortcuts.problem(with: ctrlOptB, for: first) == nil)
    }

    @Test func everyShortcutInTheAppIsDistinctAndUsable() {
        let catalog = ShortcutCatalog.all
        #expect(Set(catalog.map(\.id)).count == catalog.count)
        let keys = catalog.compactMap(\.defaultHotKey)
        #expect(Set(keys).count == keys.count)

        let shortcuts = Shortcuts(defaults: store.defaults, center: center)
        for definition in catalog {
            if let hotKey = definition.defaultHotKey {
                #expect(shortcuts.problem(with: hotKey, for: definition) == nil, "\(definition.id)")
            }
        }
    }
}

struct HotKeyTests {
    @Test func keyNames() {
        #expect(HotKey.keyName(keyCode: kVK_ANSI_V, characters: "v") == "V")
        #expect(HotKey.keyName(keyCode: kVK_ANSI_1, characters: "1") == "1")
        #expect(HotKey.keyName(keyCode: kVK_LeftArrow, characters: "\u{F702}") == "←")
        #expect(HotKey.keyName(keyCode: kVK_Space, characters: " ") == "Space")
        #expect(HotKey.keyName(keyCode: kVK_F12, characters: "\u{F70F}") == "F12")
        #expect(HotKey.keyName(keyCode: kVK_F1, characters: nil) == "F1")
        #expect(HotKey.keyName(keyCode: 0xFF, characters: nil) == nil)
    }

    @Test func modifiersAreLimitedAndOrdered() {
        let hotKey = HotKey(keyCode: kVK_ANSI_K, modifiers: [.command, .shift, .option, .control, .capsLock, .function], key: "K")
        #expect(hotKey.keyCaps == ["⌃", "⌥", "⇧", "⌘", "K"])
        #expect(HotKey.modifierSymbols([.command, .control]) == "⌃⌘")
    }

    @Test func roundTripsThroughJSON() throws {
        let hotKey = HotKey(keyCode: kVK_RightArrow, modifiers: [.control, .option, .command], key: "→")
        let decoded = try JSONDecoder().decode(HotKey.self, from: JSONEncoder().encode(hotKey))
        #expect(decoded == hotKey)
        #expect(decoded.key == "→")
        #expect(decoded.keyCaps == hotKey.keyCaps)
    }
}

struct KeyRecorderTests {
    @Test func keyPressesBecomeResults() {
        #expect(KeyRecorder.result(keyCode: kVK_ANSI_V, modifiers: [.control, .option], characters: "v")
            == .keys(HotKey(keyCode: kVK_ANSI_V, modifiers: [.control, .option], key: "V")))
        #expect(KeyRecorder.result(keyCode: kVK_Escape, modifiers: [], characters: "\u{1B}") == .cancelled)
        #expect(KeyRecorder.result(keyCode: kVK_Delete, modifiers: [], characters: "\u{7F}") == .cleared)
        // With modifiers, ⎋ and ⌫ are ordinary keys.
        #expect(KeyRecorder.result(keyCode: kVK_Delete, modifiers: [.control, .option], characters: "\u{7F}")
            == .keys(HotKey(keyCode: kVK_Delete, modifiers: [.control, .option], key: "⌫")))
        #expect(KeyRecorder.result(keyCode: 0xFF, modifiers: [.command], characters: nil) == nil)
    }

    @Test func recordsUntilStopped() {
        let recorder = KeyRecorder()
        var results: [KeyRecorder.Result] = []
        #expect(!recorder.handle(type: .keyDown, keyCode: kVK_ANSI_A, modifiers: .command, characters: "a"))

        recorder.start { results.append($0) }
        #expect(recorder.isRecording)
        #expect(!recorder.handle(type: .flagsChanged, keyCode: 0, modifiers: [.control, .option], characters: nil))
        #expect(recorder.heldModifiers == [.control, .option])
        #expect(recorder.handle(type: .keyDown, keyCode: kVK_ANSI_A, modifiers: [.control, .option], characters: "a"))
        #expect(results == [.keys(HotKey(keyCode: kVK_ANSI_A, modifiers: [.control, .option], key: "A"))])

        recorder.stop()
        #expect(!recorder.isRecording)
        #expect(recorder.heldModifiers.isEmpty)
    }
}

struct AppShortcutTests {
    private let store = TestDefaults()

    @Test func moduleShortcutsFollowTheirSwitch() throws {
        let center = FakeHotKeys()
        let state = AppState(defaults: store.defaults, clipboardStore: nil, hotKeys: center)
        let darkMode = try #require(SystemToggles.darkModeShortcut.defaultHotKey)
        #expect(!center.hotKeys.contains(darkMode))

        state.setEnabled(.systemToggles, true)
        #expect(center.hotKeys.contains(darkMode))
        state.setEnabled(.systemToggles, false)
        #expect(!center.hotKeys.contains(darkMode))

        // Awake's toggle starts unset, then works once keys are picked.
        let keys = HotKey(keyCode: kVK_ANSI_A, modifiers: [.control, .option, .command], key: "A")
        state.shortcuts.set(keys, for: AwakeController.toggleShortcut)
        #expect(center.hotKeys.contains(keys))
        center.press(keys)
        #expect(state.awake.isActive)
        center.press(keys)
        #expect(!state.awake.isActive)
    }

    @Test func zonesAndClipboardRegisterWhileOn() {
        let center = FakeHotKeys()
        let state = AppState(defaults: store.defaults, clipboardStore: nil, hotKeys: center)
        state.setEnabled(.clipboard, true)
        let clipboardKeys = Set(ClipboardController.Action.allCases.compactMap(\.shortcut.defaultHotKey))
        #expect(clipboardKeys.isSubset(of: center.hotKeys))
        state.setEnabled(.clipboard, false)
        #expect(center.hotKeys.isDisjoint(with: clipboardKeys))
    }
}
