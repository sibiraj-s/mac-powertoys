import CoreGraphics
import Foundation
import Testing

@testable import PowerToys

private let editor = PickableWindow(
    id: 7, pid: 100, appName: "Editor", title: "notes.txt", frame: CGRect(x: 100, y: 50, width: 800, height: 600))

struct WindowPickingTests {
    private func info(
        id: Int, pid: Int = 100, layer: Int = 0, alpha: Double = 1, frame: CGRect, owner: String = "Editor", name: String? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha, kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary,
        ]
        if let name { info[kCGWindowName as String] = name }
        return info
    }

    @Test func keepsOrdinaryWindowsInOrder() {
        let list = [
            info(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), name: "Front"),
            info(id: 2, pid: 200, frame: CGRect(x: 50, y: 50, width: 400, height: 300), owner: "Browser"),
        ]
        let windows = WindowPicking.windows(from: list, ownPID: 999)
        #expect(windows.map(\.id) == [1, 2])
        #expect(windows[0].title == "Front")
        #expect(windows[1].title.isEmpty)
        #expect(windows[1].appName == "Browser")
        #expect(windows[1].frame == CGRect(x: 50, y: 50, width: 400, height: 300))
    }

    @Test func skipsMenuBarFloatingHiddenAndTinyWindows() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let list = [
            info(id: 1, layer: 3, frame: frame),  // another app's floating panel
            info(id: 2, layer: 25, frame: frame),  // menu bar and status items
            info(id: 3, alpha: 0, frame: frame),  // invisible
            info(id: 4, frame: CGRect(x: 0, y: 0, width: 8, height: 8)),  // too small to pick
            info(id: 5, frame: frame),
        ]
        #expect(WindowPicking.windows(from: list, ownPID: 999).map(\.id) == [5])
    }

    @Test func ownWindowsHideWhatsBehindThem() {
        let pin = CGRect(x: 150, y: 80, width: 200, height: 150)
        let list = [
            info(id: 9, pid: 999, layer: 3, frame: pin),  // a pin
            info(id: 10, pid: 999, layer: 25, frame: pin),  // its menu bar item
            info(id: 7, frame: editor.frame),
        ]
        let windows = WindowPicking.windows(from: list, ownPID: 999)
        #expect(windows.map(\.id) == [9, 7])
        #expect(WindowPicking.window(at: CGPoint(x: 200, y: 100), in: windows, ownPID: 999) == nil)
        #expect(WindowPicking.window(at: CGPoint(x: 600, y: 400), in: windows, ownPID: 999)?.id == 7)
    }

    @Test func picksTheFrontmostWindowUnderThePoint() {
        let back = PickableWindow(id: 8, pid: 200, appName: "Browser", title: "", frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let windows = [editor, back]
        #expect(WindowPicking.window(at: CGPoint(x: 200, y: 100), in: windows, ownPID: 999) == editor)
        #expect(WindowPicking.window(at: CGPoint(x: 1000, y: 800), in: windows, ownPID: 999) == back)
        #expect(WindowPicking.window(at: CGPoint(x: 1500, y: 100), in: windows, ownPID: 999) == nil)
    }

    @Test func clickPinsTheWholeWindow() {
        let selection = WindowPicking.selection(of: editor, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 302, y: 301))
        #expect(selection == WindowSelection(window: editor, crop: nil))
        #expect(selection?.sourceRect == editor.frame)
    }

    @Test func dragCropsInTheWindowsOwnCoordinates() throws {
        // Dragged up and to the left; the crop is the same either way.
        let selection = try #require(WindowPicking.selection(of: editor, from: CGPoint(x: 400, y: 350), to: CGPoint(x: 200, y: 150)))
        #expect(selection.crop == CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(selection.sourceRect == CGRect(x: 200, y: 150, width: 200, height: 200))
    }

    @Test func windowGoesWhereItsPinnedPartLinesUpWithThePin() {
        let point = CGPoint(x: 500, y: 400)
        #expect(WindowSelection(window: editor, crop: nil).windowOrigin(showingAt: point) == point)
        let crop = WindowSelection(window: editor, crop: CGRect(x: 100, y: 60, width: 200, height: 200))
        #expect(crop.windowOrigin(showingAt: point) == CGPoint(x: 400, y: 340))
    }

    @Test func dragPastTheEdgeStopsAtTheWindow() {
        let selection = WindowPicking.selection(of: editor, from: CGPoint(x: 800, y: 500), to: CGPoint(x: 1200, y: 900))
        #expect(selection?.crop == CGRect(x: 700, y: 450, width: 100, height: 150))
    }

    @Test func dragCoveringTooLittleSelectsNothing() {
        // Mostly outside the window: only a 5-point sliver of it.
        #expect(WindowPicking.selection(of: editor, from: CGPoint(x: 895, y: 100), to: CGPoint(x: 1000, y: 300)) == nil)
    }
}

private final class FakePicker: WindowPicker {
    var selection: WindowSelection? = WindowSelection(window: editor, crop: nil)
    var picks = 0

    var cancels = 0

    func pick() async -> WindowSelection? {
        picks += 1
        return selection
    }

    func cancel() { cancels += 1 }
}

private final class FakePinWindow: PinWindow {
    var isClosed = false
    var isHidden = false
    let frame = CGRect(x: 40, y: 30, width: 320, height: 240)
    func setHidden(_ hidden: Bool) { isHidden = hidden }
    func close() { isClosed = true }
}

private final class FakeRaiser: SourceWindowRaising {
    var canRaise = true
    var raised: [(selection: WindowSelection, point: CGPoint)] = []

    func raise(_ selection: WindowSelection, showingAt point: CGPoint) -> Bool {
        guard canRaise else { return false }
        raised.append((selection, point))
        return true
    }
}

private final class FakePresenter: PinPresenting {
    var canCapture = true
    var presented: [(window: FakePinWindow, showSource: () -> Void, close: () -> Void)] = []

    func present(_ selection: WindowSelection, onShowSource: @escaping () -> Void, onClose: @escaping () -> Void) async -> (any PinWindow)?
    {
        guard canCapture else { return nil }
        let window = FakePinWindow()
        presented.append((window, onShowSource, onClose))
        return window
    }
}

@MainActor
struct PinCropControllerTests {
    final class Recorder {
        var count = 0
        var activated: [pid_t] = []
    }

    fileprivate let picker = FakePicker()
    fileprivate let presenter = FakePresenter()
    fileprivate let raiser = FakeRaiser()
    let alerts = Recorder()
    let requests = Recorder()
    let explanations = Recorder()
    let apps = Recorder()

    func makeController(hasAccess: Bool = true) -> PinCropController {
        let (alerts, requests, explanations, apps) = (alerts, requests, explanations, apps)
        return PinCropController(
            picker: picker, presenter: presenter, raiser: raiser,
            access: ScreenAccess(isGranted: { hasAccess }, request: { requests.count += 1 }, explain: { explanations.count += 1 }),
            alert: { alerts.count += 1 }, activate: { apps.activated.append($0) }
        )
    }

    @Test func pinsWhatIsPicked() async throws {
        let controller = makeController()
        let pin = try #require(await controller.pick())
        #expect(controller.pins.map(\.id) == [pin.id])
        #expect(pin.appName == "Editor")
        #expect(pin.detail == "notes.txt")
        #expect(!controller.isPicking)
    }

    @Test func describesCrops() async throws {
        picker.selection = WindowSelection(window: editor, crop: CGRect(x: 0, y: 0, width: 320, height: 180))
        let pin = try #require(await makeController().pick())
        #expect(pin.detail == "notes.txt · 320 × 180 crop")
    }

    @Test func cancellingPinsNothing() async {
        picker.selection = nil
        let controller = makeController()
        #expect(await controller.pick() == nil)
        #expect(controller.pins.isEmpty)
        #expect(alerts.count == 0)
    }

    @Test func windowThatCantBeCapturedAlerts() async {
        presenter.canCapture = false
        let controller = makeController()
        #expect(await controller.pick() == nil)
        #expect(controller.pins.isEmpty)
        #expect(alerts.count == 1)
    }

    @Test func asksForAccessOnceThenExplains() async {
        let controller = makeController(hasAccess: false)
        #expect(await controller.pick() == nil)
        #expect(await controller.pick() == nil)
        #expect(requests.count == 1)
        #expect(explanations.count == 1)
        #expect(picker.picks == 0)
    }

    @Test func closingAPinClosesItsWindow() async throws {
        let controller = makeController()
        let first = try #require(await controller.pick())
        let second = try #require(await controller.pick())

        controller.close(first)
        #expect(presenter.presented[0].window.isClosed)
        #expect(!presenter.presented[1].window.isClosed)
        #expect(controller.pins.map(\.id) == [second.id])

        controller.closeAll()
        #expect(presenter.presented[1].window.isClosed)
        #expect(controller.pins.isEmpty)
    }

    @Test func pinClosedOnItsOwnIsForgotten() async throws {
        let controller = makeController()
        _ = try #require(await controller.pick())
        // Closed from its panel, or its window closed.
        presenter.presented[0].close()
        #expect(controller.pins.isEmpty)
    }

    @Test func swapsInTheRealWindowUntilAnotherAppComesForward() async throws {
        let controller = makeController()
        _ = try #require(await controller.pick())
        presenter.presented[0].showSource()  // double-clicking the pin
        let pin = presenter.presented[0].window
        #expect(raiser.raised.map(\.point) == [pin.frame.origin])
        #expect(raiser.raised.first?.selection.window == editor)
        #expect(pin.isHidden)
        #expect(apps.activated.isEmpty)

        controller.appDidActivate(100)  // its own app coming forward
        #expect(pin.isHidden)
        controller.appDidActivate(200)
        #expect(!pin.isHidden)
    }

    @Test func swappingAnotherPinBringsTheFirstBack() async throws {
        let controller = makeController()
        let first = try #require(await controller.pick())
        let second = try #require(await controller.pick())
        controller.showSource(of: first)
        controller.showSource(of: second)
        #expect(!presenter.presented[0].window.isHidden)
        #expect(presenter.presented[1].window.isHidden)
    }

    @Test func withoutAccessibilityOnlyTheAppComesForward() async throws {
        raiser.canRaise = false
        let controller = makeController()
        let pin = try #require(await controller.pick())
        controller.showSource(of: pin)
        #expect(apps.activated == [100])
        #expect(!presenter.presented[0].window.isHidden)
    }

    @Test func closingTheSwappedPinEndsTheSwap() async throws {
        let controller = makeController()
        let pin = try #require(await controller.pick())
        controller.showSource(of: pin)
        controller.close(pin)
        controller.appDidActivate(200)
        #expect(presenter.presented[0].window.isHidden)  // stays closed, not shown again
    }

    @Test func turningTheModuleOffClosesPins() async throws {
        let store = TestDefaults()
        let controller = makeController()
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings(), pinCrop: controller)
        state.setEnabled(.pinCrop, true)
        _ = try #require(await controller.pick())

        state.setEnabled(.pinCrop, false)
        #expect(picker.cancels == 1)  // an open picker closes too
        #expect(controller.pins.isEmpty)
        #expect(presenter.presented[0].window.isClosed)
    }
}
