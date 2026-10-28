import AppKit
import Testing
@testable import PowerToys

struct PickedColorTests {
    @Test func readsHex() {
        #expect(PickedColor(hex: "#1A2B3C")?.hex == "#1A2B3C")
        #expect(PickedColor(hex: "ff8800")?.hex == "#FF8800")
        #expect(PickedColor(hex: " #abc ")?.hex == "#AABBCC")
        #expect(PickedColor(hex: "#12345") == nil)
        #expect(PickedColor(hex: "#GGGGGG") == nil)
        #expect(PickedColor(hex: "") == nil)
    }

    @Test func clampsWideGamutComponents() {
        let color = PickedColor(red: 1.2, green: -0.1, blue: 0.5)
        #expect(color.red == 1)
        #expect(color.green == 0)
        #expect(color.hex == "#FF0080")
    }

    @Test func formats() throws {
        let color = try #require(PickedColor(hex: "#3399DB"))
        #expect(ColorFormat.hex.string(for: color) == "#3399DB")
        #expect(ColorFormat.rgb.string(for: color) == "rgb(51, 153, 219)")
        #expect(ColorFormat.hsl.string(for: color) == "hsl(204, 70%, 53%)")
        #expect(ColorFormat.hsb.string(for: color) == "hsb(204, 77%, 86%)")
        #expect(ColorFormat.swiftUI.string(for: color) == "Color(red: 0.2, green: 0.6, blue: 0.859)")
        #expect(ColorFormat.nsColor.string(for: color) == "NSColor(srgbRed: 0.2, green: 0.6, blue: 0.859, alpha: 1)")
        #expect(ColorFormat.uiColor.string(for: color) == "UIColor(red: 0.2, green: 0.6, blue: 0.859, alpha: 1)")
    }

    @Test func formatsGraysAndExtremes() throws {
        let white = try #require(PickedColor(hex: "#FFFFFF"))
        let black = try #require(PickedColor(hex: "#000000"))
        let gray = try #require(PickedColor(hex: "#808080"))
        #expect(ColorFormat.hsl.string(for: white) == "hsl(0, 0%, 100%)")
        #expect(ColorFormat.hsb.string(for: black) == "hsb(0, 0%, 0%)")
        #expect(ColorFormat.hsl.string(for: gray) == "hsl(0, 0%, 50%)")
        #expect(ColorFormat.swiftUI.string(for: white) == "Color(red: 1, green: 1, blue: 1)")
        #expect(ColorFormat.swiftUI.string(for: black) == "Color(red: 0, green: 0, blue: 0)")
    }

    @Test func huesAroundTheWheel() throws {
        func hue(_ hex: String) throws -> String {
            ColorFormat.hsl.string(for: try #require(PickedColor(hex: hex)))
        }
        #expect(try hue("#FF0000") == "hsl(0, 100%, 50%)")
        #expect(try hue("#00FF00") == "hsl(120, 100%, 50%)")
        #expect(try hue("#0000FF") == "hsl(240, 100%, 50%)")
        #expect(try hue("#FF00FF") == "hsl(300, 100%, 50%)")
        // Just short of red the other way round, which must not come out as 360.
        #expect(try hue("#FF0001") == "hsl(0, 100%, 50%)")
    }

    @Test func tellsLightFromDark() throws {
        #expect(try #require(PickedColor(hex: "#FFFFFF")).isLight)
        #expect(try #require(PickedColor(hex: "#FFEB3B")).isLight)
        #expect(try !#require(PickedColor(hex: "#000000")).isLight)
        #expect(try !#require(PickedColor(hex: "#1E40AF")).isLight)
    }
}

@MainActor
struct ColorPickerControllerTests {
    private let store = TestDefaults()
    private let pasteboard = NSPasteboard.withUniqueName()

    private func controller(_ sampler: FakeSampler = FakeSampler()) -> ColorPickerController {
        ColorPickerController(defaults: store.defaults, sampler: sampler, pasteboard: pasteboard)
    }

    private var copied: String? { pasteboard.string(forType: .string) }

    @Test func defaults() {
        let picker = controller()
        #expect(picker.format == .hex)
        #expect(picker.copiesOnPick)
        #expect(picker.history.isEmpty)
        #expect(picker.latest == nil)
    }

    @Test func pickingCopiesAndRemembers() async {
        let picker = controller(FakeSampler(colors: [PickedColor(hex: "#112233")]))
        let color = await picker.pick()
        #expect(color?.hex == "#112233")
        #expect(picker.latest?.hex == "#112233")
        #expect(copied == "#112233")
        #expect(!picker.isPicking)
    }

    @Test func copiesInTheChosenFormat() async {
        let picker = controller(FakeSampler(colors: [PickedColor(hex: "#112233")]))
        picker.format = .rgb
        await picker.pick()
        #expect(copied == "rgb(17, 34, 51)")
    }

    @Test func canPickWithoutCopying() async {
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let picker = controller(FakeSampler(colors: [PickedColor(hex: "#112233")]))
        picker.copiesOnPick = false
        await picker.pick()
        #expect(picker.latest?.hex == "#112233")
        #expect(copied == "before")
    }

    @Test func cancellingChangesNothing() async {
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let picker = controller(FakeSampler(colors: [nil]))
        #expect(await picker.pick() == nil)
        #expect(picker.history.isEmpty)
        #expect(copied == "before")
    }

    @Test func pickingAgainMovesAColorToTheTop() throws {
        let picker = controller()
        let first = try #require(PickedColor(hex: "#111111"))
        let second = try #require(PickedColor(hex: "#222222"))
        picker.add(first)
        picker.add(second)
        picker.add(first)
        #expect(picker.history.map(\.hex) == ["#111111", "#222222"])
    }

    @Test func keepsOnlyTheNewest() {
        let picker = controller()
        for value in 0..<(ColorPickerController.historyLimit + 5) {
            picker.add(PickedColor(red: Double(value) / 255, green: 0, blue: 0))
        }
        #expect(picker.history.count == ColorPickerController.historyLimit)
        #expect(picker.latest?.red8 == ColorPickerController.historyLimit + 4)
    }

    @Test func settingsAndHistoryPersist() throws {
        let picker = controller()
        picker.format = .swiftUI
        picker.copiesOnPick = false
        picker.add(try #require(PickedColor(hex: "#ABCDEF")))

        let relaunched = controller()
        #expect(relaunched.format == .swiftUI)
        #expect(!relaunched.copiesOnPick)
        #expect(relaunched.history.map(\.hex) == ["#ABCDEF"])
    }

    @Test func removesAndClears() throws {
        let picker = controller()
        let first = try #require(PickedColor(hex: "#111111"))
        picker.add(first)
        picker.add(try #require(PickedColor(hex: "#222222")))
        picker.remove(first)
        #expect(picker.history.map(\.hex) == ["#222222"])
        picker.clearHistory()
        #expect(picker.history.isEmpty)
        #expect(controller().history.isEmpty)
    }

    @Test func copiesAnyColorAsAnyFormat() throws {
        let picker = controller()
        picker.copy(try #require(PickedColor(hex: "#FF0000")), as: .hsl)
        #expect(copied == "hsl(0, 100%, 50%)")
    }

    @Test func ignoresAPickWhilePicking() async {
        let sampler = FakeSampler(colors: [PickedColor(hex: "#111111"), PickedColor(hex: "#222222")], waits: true)
        let picker = controller(sampler)
        let first = Task { await picker.pick() }
        await sampler.started()
        #expect(picker.isPicking)
        #expect(await picker.pick() == nil)
        sampler.finish()
        #expect(await first.value?.hex == "#111111")
        #expect(!picker.isPicking)
        #expect(picker.history.map(\.hex) == ["#111111"])
    }

    @Test func shortcutStartsOutUnset() {
        let shortcuts = Shortcuts(defaults: store.defaults, center: FakeHotKeys())
        #expect(shortcuts.hotKey(for: ColorPickerController.pickShortcut) == nil)
    }

    @Test func storedColorsAreClamped() throws {
        let stored = Data(#"[{"red": 1.2, "green": -0.5, "blue": 0.5}]"#.utf8)
        store.defaults.set(stored, forKey: ColorPickerController.historyKey)
        let color = try #require(controller().latest)
        #expect(color.red == 1)
        #expect(color.green == 0)
        #expect(color.hex == "#FF0080")
    }

    @Test func shortcutFollowsTheModuleSwitch() {
        let center = FakeHotKeys()
        let state = AppState.testing(defaults: store.defaults, hotKeys: center, system: FakeSystemSettings())
        #expect(state.isEnabled(.colorPicker))
        #expect(state.shortcuts.isActive(ColorPickerController.pickShortcut))
        state.setEnabled(.colorPicker, false)
        #expect(!state.shortcuts.isActive(ColorPickerController.pickShortcut))
    }
}

/// Returns the given colors in turn, nil meaning a cancelled pick. With `waits`, each sample
/// holds until `finish()`, like the magnifier waiting for a click.
final class FakeSampler: ColorSampling {
    private var colors: [PickedColor?]
    private let waits: Bool
    private var click: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(colors: [PickedColor?] = [], waits: Bool = false) {
        self.colors = colors
        self.waits = waits
    }

    func sample() async -> PickedColor? {
        if waits {
            await withCheckedContinuation { continuation in
                click = continuation
                startWaiters.forEach { $0.resume() }
                startWaiters.removeAll()
            }
        }
        return colors.isEmpty ? nil : colors.removeFirst()
    }

    /// Returns once a sample is waiting for its click.
    func started() async {
        guard click == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        click?.resume()
        click = nil
    }
}
