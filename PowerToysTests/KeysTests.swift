import AppKit
import Carbon.HIToolbox
import Testing

@testable import PowerToys

/// Keeps the key mapping in memory, so tests never change the real keyboard.
final class FakeKeyMappingStore: KeyMappingStore {
    var entries: [[String: UInt64]] = []
    var writes = 0
    var capsLockTurnedOff = 0

    func userKeyMapping() -> [[String: UInt64]] { entries }

    func setUserKeyMapping(_ entries: [[String: UInt64]]) {
        self.entries = entries
        writes += 1
    }

    func turnOffCapsLock() {
        capsLockTurnedOff += 1
    }

    var capsLockDestination: UInt64? {
        entries.first { $0[HIDUsage.sourceKey] == HIDUsage.capsLock }?[HIDUsage.destinationKey]
    }
}

struct HIDMappingTests {
    private let other: [String: UInt64] = [HIDUsage.sourceKey: 0x7_0000_0064, HIDUsage.destinationKey: 0x7_0000_0035]

    @Test func mapsCapsLockAndKeepsOtherKeys() {
        let result = HIDUsage.mapping([other], capsLockTo: HIDUsage.escape)
        #expect(result == [other, [HIDUsage.sourceKey: HIDUsage.capsLock, HIDUsage.destinationKey: HIDUsage.escape]])
    }

    @Test func replacesAnEarlierCapsLockMapping() {
        let first = HIDUsage.mapping([other], capsLockTo: HIDUsage.escape)
        let result = HIDUsage.mapping(first, capsLockTo: HIDUsage.f18)
        #expect(result.count == 2)
        #expect(result.last?[HIDUsage.destinationKey] == HIDUsage.f18)
    }

    @Test func nilRemovesOnlyCapsLock() {
        let mapped = HIDUsage.mapping([other], capsLockTo: HIDUsage.leftControl)
        #expect(HIDUsage.mapping(mapped, capsLockTo: nil) == [other])
    }

    @Test func eachModeMapsCapsLockSomewhere() {
        #expect(CapsLockMode.standard.hidDestination == nil)
        #expect(CapsLockMode.escape.hidDestination == HIDUsage.escape)
        #expect(CapsLockMode.control.hidDestination == HIDUsage.leftControl)
        #expect(CapsLockMode.hyper.hidDestination == HIDUsage.f18)
        #expect(CapsLockMode.hyperOrEscape.hidDestination == HIDUsage.f18)
        #expect(CapsLockMode.allCases.filter(\.usesHyper) == [.hyper, .hyperOrEscape])
    }
}

struct HyperKeyStateTests {
    @Test func tappedAloneCounts() {
        var hyper = HyperKeyState()
        hyper.press()
        #expect(hyper.isHeld)
        let tapped = hyper.release()
        #expect(tapped)
        #expect(!hyper.isHeld)
    }

    @Test func usedWithAnotherKeyIsNotATap() {
        var hyper = HyperKeyState()
        hyper.press()
        hyper.interrupt()
        let tapped = hyper.release()
        #expect(!tapped)
    }

    @Test func keyRepeatDoesNotResetIt() {
        var hyper = HyperKeyState()
        hyper.press()
        hyper.interrupt()
        hyper.press()
        let tapped = hyper.release()
        #expect(!tapped)
    }

    @Test func releaseWithoutPressIsNotATap() {
        var hyper = HyperKeyState()
        let tapped = hyper.release()
        #expect(!tapped)
    }
}

struct KeyRemapTests {
    private let hyperH = HotKey(keyCode: kVK_ANSI_H, modifiers: [.control, .option, .shift, .command], key: "H")
    private let left = HotKey(keyCode: kVK_LeftArrow, modifiers: [], key: "←")
    private let quit = HotKey(keyCode: kVK_ANSI_Q, modifiers: .command, key: "Q")
    private let safari = KeyRemap.App(bundleID: "com.apple.Safari", name: "Safari")

    private func output(_ keys: HotKey, app: String? = nil, in remaps: [KeyRemap]) -> KeyRemap.Output? {
        KeyRemap.output(for: keys.keyCode, modifiers: keys.modifiers, app: app, in: remaps)
    }

    @Test func matchesExactKeysAndModifiers() {
        let remaps = [KeyRemap(from: hyperH, output: .keys(left))]
        #expect(output(hyperH, in: remaps) == .keys(left))
        let fewerModifiers = HotKey(keyCode: kVK_ANSI_H, modifiers: [.control, .option], key: "H")
        #expect(output(fewerModifiers, in: remaps) == nil)
    }

    @Test func ignoresCapsLockAndFnFlags() {
        let remaps = [KeyRemap(from: quit, output: .nothing)]
        let modifiers: NSEvent.ModifierFlags = [.command, .capsLock, .function, .numericPad]
        #expect(KeyRemap.output(for: kVK_ANSI_Q, modifiers: modifiers, app: nil, in: remaps) == .nothing)
    }

    @Test func incompleteRemapsDoNothing() {
        let remaps = [KeyRemap(from: quit, output: .keys(nil)), KeyRemap(from: nil, output: .nothing)]
        #expect(remaps.allSatisfy { !$0.isActive })
        #expect(output(quit, in: remaps) == nil)
    }

    @Test func appRemapWinsOverEveryApp() {
        let remaps = [
            KeyRemap(from: quit, output: .keys(left)),
            KeyRemap(from: quit, output: .nothing, app: safari),
        ]
        #expect(output(quit, app: "com.apple.Safari", in: remaps) == .nothing)
        #expect(output(quit, app: "com.apple.finder", in: remaps) == .keys(left))
        #expect(output(quit, app: nil, in: remaps) == .keys(left))
    }

    @Test func appRemapOnlyAppliesInItsApp() {
        let remaps = [KeyRemap(from: quit, output: .nothing, app: safari)]
        #expect(output(quit, app: "com.apple.finder", in: remaps) == nil)
    }

    @Test func looksUpTheAppOnlyForAnAppRemap() {
        var lookups = 0
        func frontmost() -> String? {
            lookups += 1
            return "com.apple.Safari"
        }
        let everywhere = [KeyRemap(from: quit, output: .nothing)]
        #expect(KeyRemap.output(for: kVK_ANSI_Q, modifiers: .command, app: frontmost(), in: everywhere) == .nothing)
        #expect(KeyRemap.output(for: kVK_ANSI_W, modifiers: .command, app: frontmost(), in: everywhere) == nil)
        #expect(lookups == 0)
        let inSafari = [KeyRemap(from: quit, output: .nothing, app: safari)]
        #expect(KeyRemap.output(for: kVK_ANSI_Q, modifiers: .command, app: frontmost(), in: inSafari) == .nothing)
        #expect(lookups == 1)
    }

    @Test(arguments: KeyRemap.Output.Kind.allCases)
    func outputKindRoundTrips(kind: KeyRemap.Output.Kind) {
        #expect(KeyRemap.Output(kind: kind).kind == kind)
    }
}

struct KeysControllerTests {
    @Test func startsWithNothingChanged() {
        let store = TestDefaults()
        let mapping = FakeKeyMappingStore()
        let controller = KeysController(defaults: store.defaults, mappingStore: mapping, isTrusted: { false })
        #expect(controller.capsLock == .standard)
        #expect(controller.remaps.isEmpty)
        controller.start()
        controller.stop()
        #expect(mapping.writes == 0)
    }

    @Test func remapsPersist() {
        let store = TestDefaults()
        let controller = KeysController(defaults: store.defaults, mappingStore: FakeKeyMappingStore(), isTrusted: { false })
        var remap = controller.addRemap()
        remap.from = HotKey(keyCode: kVK_ANSI_Q, modifiers: .command, key: "Q")
        remap.output = .nothing
        remap.app = KeyRemap.App(bundleID: "com.apple.Safari", name: "Safari")
        controller.update(remap)
        controller.addRemap()
        controller.capsLock = .control

        let reloaded = KeysController(defaults: store.defaults, mappingStore: FakeKeyMappingStore(), isTrusted: { false })
        #expect(reloaded.remaps.count == 2)
        #expect(reloaded.remaps.first == remap)
        #expect(reloaded.capsLock == .control)

        reloaded.remove(remap.id)
        #expect(reloaded.remaps.count == 1)
    }

    @Test func flagsKeysAlreadyRemappedInTheSameScope() {
        let store = TestDefaults()
        let controller = KeysController(defaults: store.defaults, mappingStore: FakeKeyMappingStore(), isTrusted: { false })
        let quit = HotKey(keyCode: kVK_ANSI_Q, modifiers: .command, key: "Q")
        var first = controller.addRemap()
        first.from = quit
        controller.update(first)
        var second = controller.addRemap()
        #expect(controller.problem(with: quit, from: second) != nil)
        #expect(controller.problem(with: quit, from: first) == nil)
        second.app = KeyRemap.App(bundleID: "com.apple.Safari", name: "Safari")
        #expect(controller.problem(with: quit, from: second) == nil)
        // The same app picked another way can carry another name.
        first.app = KeyRemap.App(bundleID: "com.apple.Safari", name: "Safari.app")
        controller.update(first)
        #expect(controller.problem(with: quit, from: second) != nil)
    }

    @Test func escapeAndControlMapWhileRunning() {
        let store = TestDefaults()
        let mapping = FakeKeyMappingStore()
        let controller = KeysController(defaults: store.defaults, mappingStore: mapping, isTrusted: { false })
        controller.capsLock = .escape
        #expect(mapping.capsLockDestination == nil)
        controller.start()
        #expect(mapping.capsLockDestination == HIDUsage.escape)
        controller.capsLock = .control
        #expect(mapping.capsLockDestination == HIDUsage.leftControl)
        controller.capsLock = .standard
        #expect(mapping.capsLockDestination == nil)
        controller.capsLock = .escape
        controller.stop()
        #expect(mapping.capsLockDestination == nil)
    }

    @Test func turnsCapsLockOffBeforeMappingIt() {
        let store = TestDefaults()
        let mapping = FakeKeyMappingStore()
        let controller = KeysController(defaults: store.defaults, mappingStore: mapping, isTrusted: { false })
        controller.capsLock = .escape
        controller.start()
        controller.capsLock = .control
        #expect(mapping.capsLockTurnedOff == 1)
        controller.stop()
        controller.start()
        #expect(mapping.capsLockTurnedOff == 2)
        controller.stop()
    }

    @Test func listensOnlyWhenHyperOrARemapNeedsIt() {
        let store = TestDefaults()
        var asked = 0
        let controller = KeysController(defaults: store.defaults, mappingStore: FakeKeyMappingStore()) {
            asked += 1
            return false
        }
        controller.capsLock = .escape
        controller.start()
        var remap = controller.addRemap()
        #expect(asked == 0)
        remap.from = HotKey(keyCode: kVK_ANSI_Q, modifiers: .command, key: "Q")
        remap.output = .nothing
        controller.update(remap)
        #expect(asked == 1)
        controller.remove(remap.id)
        controller.capsLock = .hyper
        #expect(asked == 2)
        controller.stop()
        #expect(!controller.isListening)
    }

    @Test func hyperWaitsForAccessibility() {
        let store = TestDefaults()
        let mapping = FakeKeyMappingStore()
        let controller = KeysController(defaults: store.defaults, mappingStore: mapping, isTrusted: { false })
        controller.capsLock = .hyper
        controller.start()
        // Without the tap, Caps Lock mapped to F18 would do nothing at all.
        #expect(mapping.capsLockDestination == nil)
        controller.stop()
    }

    @Test func undoesAMappingLeftByACrash() {
        let store = TestDefaults()
        let mapping = FakeKeyMappingStore()
        mapping.entries = HIDUsage.mapping([], capsLockTo: HIDUsage.escape)
        store.defaults.set(true, forKey: KeysController.mapsCapsLockKey)
        _ = KeysController(defaults: store.defaults, mappingStore: mapping, isTrusted: { false })
        #expect(mapping.capsLockDestination == nil)
        #expect(!store.defaults.bool(forKey: KeysController.mapsCapsLockKey))
    }

    @Test func leavesCapsLockMappedElsewhereAlone() {
        let store = TestDefaults()
        let mapping = FakeKeyMappingStore()
        mapping.entries = HIDUsage.mapping([], capsLockTo: HIDUsage.escape)
        let controller = KeysController(defaults: store.defaults, mappingStore: mapping, isTrusted: { false })
        controller.start()
        controller.stop()
        #expect(mapping.capsLockDestination == HIDUsage.escape)
        #expect(mapping.writes == 0)
    }

    @Test func moduleSwitchStartsAndStopsIt() {
        let store = TestDefaults()
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        state.setEnabled(.keys, true)
        #expect(state.keys.isRunning)
        state.setEnabled(.keys, false)
        #expect(!state.keys.isRunning)
    }
}
