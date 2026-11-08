import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Testing

@testable import PowerToys

/// A stand-in Accessibility element; nothing is asked of it in these tests. Elements are told apart
/// by `element`, as each window's own would be.
private func axWindow(_ pid: pid_t, element: pid_t? = nil) -> AXWindow {
    AXWindow(element: AXUIElementCreateApplication(element ?? pid), pid: pid)
}

private var nextElement: pid_t = 10_000

private func entry(_ title: String, pid: pid_t, frame: CGRect?, minimized: Bool = false, standard: Bool = true) -> AppWindows.Entry {
    nextElement += 1
    return AppWindows.Entry(
        window: axWindow(pid, element: nextElement), title: title, frame: frame, isMinimized: minimized, isStandard: standard)
}

struct WindowSwitchingTests {
    let editorFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let browserFrame = CGRect(x: 100, y: 100, width: 1000, height: 700)

    @Test func onScreenWindowsComeFirstFrontToBackThenMinimizedAndHidden() {
        let onScreen = [
            PickableWindow(id: 2, pid: 200, appName: "Browser", title: "", frame: browserFrame),
            PickableWindow(id: 1, pid: 100, appName: "Editor", title: "", frame: editorFrame),
        ]
        let apps = [
            AppWindows(
                pid: 100, appName: "Editor", isHidden: false,
                windows: [
                    entry("notes.txt", pid: 100, frame: editorFrame),
                    entry("old.txt", pid: 100, frame: editorFrame, minimized: true),
                ]),
            AppWindows(pid: 200, appName: "Browser", isHidden: false, windows: [entry("Docs", pid: 200, frame: browserFrame)]),
            AppWindows(pid: 300, appName: "Mail", isHidden: true, windows: [entry("Inbox", pid: 300, frame: editorFrame)]),
        ]
        let windows = WindowSwitching.windows(onScreen: onScreen, apps: apps)
        #expect(windows.map(\.title) == ["Docs", "notes.txt", "old.txt", "Inbox"])
        #expect(windows.map(\.state) == [.onScreen, .onScreen, .minimized, .hidden])
        #expect(windows.map(\.windowID) == [2, 1, nil, nil])
        #expect(windows[3].appName == "Mail")
    }

    @Test func listedWindowsWithoutAnAccessibilityWindowAreLeftOut() {
        let onScreen = [
            PickableWindow(id: 5, pid: 100, appName: "Editor", title: "", frame: CGRect(x: 0, y: 0, width: 300, height: 40)),  // an overlay
            PickableWindow(id: 1, pid: 100, appName: "Editor", title: "", frame: editorFrame),
            PickableWindow(id: 9, pid: 400, appName: "Helper", title: "", frame: editorFrame),  // no Accessibility windows at all
        ]
        let apps = [AppWindows(pid: 100, appName: "Editor", isHidden: false, windows: [entry("notes.txt", pid: 100, frame: editorFrame)])]
        #expect(WindowSwitching.windows(onScreen: onScreen, apps: apps).map(\.windowID) == [1])
    }

    @Test func sameSizedWindowsOfOneAppEachMatchOnce() {
        let onScreen = [
            PickableWindow(id: 1, pid: 100, appName: "Editor", title: "", frame: editorFrame),
            PickableWindow(id: 2, pid: 100, appName: "Editor", title: "", frame: editorFrame),
        ]
        let apps = [
            AppWindows(
                pid: 100, appName: "Editor", isHidden: false,
                windows: [entry("a", pid: 100, frame: editorFrame), entry("b", pid: 100, frame: editorFrame)])
        ]
        #expect(WindowSwitching.windows(onScreen: onScreen, apps: apps).map(\.title) == ["a", "b"])
    }

    @Test func windowsInTheSamePlaceAreToldApartByTitle() {
        // Front to back, b is in front of a, while Accessibility lists a first.
        let onScreen = [
            PickableWindow(id: 2, pid: 100, appName: "Editor", title: "b", frame: editorFrame),
            PickableWindow(id: 1, pid: 100, appName: "Editor", title: "a", frame: editorFrame),
        ]
        let apps = [
            AppWindows(
                pid: 100, appName: "Editor", isHidden: false,
                windows: [entry("a", pid: 100, frame: editorFrame), entry("b", pid: 100, frame: editorFrame)])
        ]
        let windows = WindowSwitching.windows(onScreen: onScreen, apps: apps)
        #expect(windows.map(\.title) == ["b", "a"])
        #expect(windows.map(\.windowID) == [2, 1])
    }

    @Test func floatingPanelsOnScreenAreLeftOut() {
        let inspector = CGRect(x: 900, y: 0, width: 250, height: 400)
        let onScreen = [
            PickableWindow(id: 3, pid: 100, appName: "Editor", title: "", frame: inspector),
            PickableWindow(id: 1, pid: 100, appName: "Editor", title: "", frame: editorFrame),
        ]
        let apps = [
            AppWindows(
                pid: 100, appName: "Editor", isHidden: false,
                windows: [
                    entry("Inspector", pid: 100, frame: inspector, standard: false), entry("notes.txt", pid: 100, frame: editorFrame),
                ])
        ]
        #expect(WindowSwitching.windows(onScreen: onScreen, apps: apps).map(\.title) == ["notes.txt"])
    }

    @Test func minimizedPanelsAreLeftOut() {
        let apps = [
            AppWindows(
                pid: 100, appName: "Editor", isHidden: false,
                windows: [entry("Inspector", pid: 100, frame: nil, minimized: true, standard: false)])
        ]
        #expect(WindowSwitching.windows(onScreen: [], apps: apps).isEmpty)
    }
}

struct SwitcherLayoutTests {
    @Test func fewWindowsMakeOneRow() {
        let grid = SwitcherLayout.grid(count: 3, in: CGSize(width: 1440, height: 900))
        #expect(grid.columns == 3)
        #expect(grid.size == CGSize(width: 3 * 180 + 2 * 10 + 32, height: 150 + 32 + 28))
    }

    @Test func manyWindowsWrapAndScrollPastMostOfTheDisplay() {
        let area = CGSize(width: 1000, height: 400)
        let grid = SwitcherLayout.grid(count: 40, in: area)
        // (900 - 32 + 10) / 190 fits 4 columns.
        #expect(grid.columns == 4)
        #expect(grid.size.width == CGFloat(4 * 180 + 3 * 10 + 32))
        #expect(grid.size.height == area.height * 0.85)
    }

    @Test func stackDepthCountsOnFromTheSelectedWindowAndWraps() {
        #expect((0..<4).map { SwitcherLayout.depth(of: $0, selected: 2, count: 4) } == [2, 3, 0, 1])
        #expect(SwitcherLayout.depth(of: 0, selected: 0, count: 0) == 0)
        #expect(SwitcherLayout.wrapped(-1, count: 3) == 2)
    }

    @Test func aNarrowDisplayStillGetsOneColumn() {
        #expect(SwitcherLayout.grid(count: 2, in: CGSize(width: 100, height: 800)).columns == 1)
    }
}

private final class FakeLister: WindowListing {
    var list: [SwitcherWindow] = []
    func windows() -> [SwitcherWindow] { list }
}

private final class FakePresenter: SwitcherPresenting {
    private(set) var isShown = false
    private(set) var showCount = 0
    func show(_ controller: WindowSwitcherController) {
        isShown = true
        showCount += 1
    }
    func hide() { isShown = false }
    private(set) var refocusCount = 0
    func refocus() { refocusCount += 1 }
}

/// Hands back the capture callbacks, so a test can deliver previews whenever it likes.
private final class HeldPreviews: WindowPreviewing {
    var pending: [(CGWindowID, CGImage) -> Void] = []
    var sizes: [CGSize] = []
    func capture(_ ids: [CGWindowID], maxPixels: CGSize, each: @escaping (CGWindowID, CGImage) -> Void) async {
        sizes.append(maxPixels)
        pending.append(each)
    }
}

private func window(_ title: String, pid: pid_t, windowID: CGWindowID) -> SwitcherWindow {
    nextElement += 1
    return SwitcherWindow(
        windowID: windowID, pid: pid, appName: "App", title: title, state: .onScreen,
        frame: CGRect(x: 0, y: 0, width: 400, height: 300), window: axWindow(pid, element: nextElement))
}

@MainActor
struct WindowSwitcherControllerTests {
    let defaults = TestDefaults()
    fileprivate let lister = FakeLister()
    fileprivate let presenter = FakePresenter()
    fileprivate let previews = HeldPreviews()
    let optionTab = HotKey(keyCode: kVK_Tab, modifiers: .option, key: "⇥")

    private final class Log {
        var activated: [String] = []
        var acted: [(WindowSwitcherController.Action, String)] = []
        var alerts = 0
        var modifiers: NSEvent.ModifierFlags = [.option]
        /// When set, the app ignores the action, as when it asks to save first or won't quit.
        var appRefuses = false
        var frontmostPID: pid_t? = 100
        /// Work the app's response waits for, run by `respond()`; nil runs it straight away.
        var delayed: [() -> Void]?

        func respond() {
            let work = delayed ?? []
            delayed = []
            for job in work { job() }
        }
    }

    private let log = Log()

    private func makeController(hotKey: HotKey?) -> WindowSwitcherController {
        let shortcuts = Shortcuts(defaults: defaults.defaults, center: FakeHotKeys())
        shortcuts.set(hotKey, for: WindowSwitcherController.switchShortcut)
        // w0 and w1 are Editor's, w2 is Browser's.
        lister.list = [
            window("w0", pid: 100, windowID: 1), window("w1", pid: 100, windowID: 2), window("w2", pid: 200, windowID: 3),
        ]
        let log = log
        let lister = lister
        return WindowSwitcherController(
            defaults: defaults.defaults, shortcuts: shortcuts, lister: lister, previewer: previews, presenter: presenter,
            currentModifiers: { log.modifiers }, frontmostPID: { log.frontmostPID }, activate: { log.activated.append($0.title) },
            act: { action, target in
                log.acted.append((action, target.title))
                guard !log.appRefuses else { return }
                // What the app does, which the next listing shows.
                switch action {
                case .close: lister.list.removeAll { $0.id == target.id }
                case .quitApp: lister.list.removeAll { $0.pid == target.pid }
                case .minimize:
                    for index in lister.list.indices where lister.list[index].id == target.id {
                        lister.list[index].state = .minimized
                        lister.list[index].frame = nil
                    }
                case .hideApp:
                    for index in lister.list.indices where lister.list[index].pid == target.pid {
                        lister.list[index].state = .hidden
                        lister.list[index].frame = nil
                    }
                }
            },
            // The app responds straight away here.
            schedule: { _, work in
                if log.delayed != nil { log.delayed?.append(work) } else { work() }
            },
            alert: { log.alerts += 1 })
    }

    @Test func pressingOpensOnThePreviousWindowAndPressingAgainStepsOn() {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        #expect(presenter.isShown)
        #expect(controller.selected?.title == "w1")
        #expect(controller.stepKeyCode == kVK_Tab)
        controller.trigger()
        controller.trigger()
        #expect(controller.selectedIndex == 0)  // wrapped around
        #expect(presenter.showCount == 1)
    }

    @Test func opensOnTheFirstWindowWhenTheAppInFrontHasNoneListed() {
        let controller = makeController(hotKey: optionTab)
        log.frontmostPID = 999  // say, this app's own settings window
        log.modifiers = []
        controller.trigger()
        #expect(log.activated == ["w0"])
    }

    @Test func anActionOnTheShortcutsOwnKeyIsntOffered() {
        let controller = makeController(hotKey: HotKey(keyCode: kVK_ANSI_Q, modifiers: [.control, .option], key: "Q"))
        controller.trigger()
        #expect(controller.availableActions == [.close, .minimize, .hideApp])
        controller.cancel()
        let tab = makeController(hotKey: optionTab)
        tab.trigger()
        #expect(tab.availableActions == WindowSwitcherController.Action.allCases)
    }

    @Test func upAndDownMoveARowWithoutWrapping() {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()  // w1
        controller.moveRow(by: -2)
        #expect(controller.selectedIndex == 1)  // no row above
        controller.moveRow(by: 1)
        #expect(controller.selectedIndex == 2)
        controller.moveRow(by: 1)
        #expect(controller.selectedIndex == 2)
    }

    @Test func losingTheKeysClosesUnlessAnActionIsUnderway() {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        log.delayed = []
        controller.perform(.hideApp)  // Editor was in front; another app comes forward
        controller.lostFocus()
        #expect(controller.isShowing)
        log.respond()
        #expect(presenter.refocusCount == 2)
        #expect(controller.selected?.state == .hidden)
        controller.lostFocus()
        #expect(!controller.isShowing)
    }

    @Test func gridPreviewsAreSmallerThanStackOnes() async {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        controller.cancel()
        controller.style = .stack
        controller.trigger()
        while previews.sizes.count < 2 { await Task.yield() }
        #expect(previews.sizes == [SwitcherLayout.tilePreviewPixels, SwitcherLayout.cardPreviewPixels])
    }

    @Test func lettingGoOfTheModifiersSwitches() {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        controller.trigger()
        controller.modifiersChanged([.option, .shift])  // ⇧ added to step back: still holding
        #expect(log.activated.isEmpty)
        controller.modifiersChanged([])
        #expect(log.activated == ["w2"])
        #expect(!presenter.isShown)
        #expect(!controller.isShowing)
        #expect(controller.windows.isEmpty)
    }

    @Test func aQuickPressSwitchesStraightToThePreviousWindow() {
        let controller = makeController(hotKey: optionTab)
        log.modifiers = []
        controller.trigger()
        #expect(log.activated == ["w1"])
        #expect(presenter.showCount == 0)
    }

    @Test func aShortcutWithoutModifiersStaysOpenUntilChosen() {
        let controller = makeController(hotKey: HotKey(keyCode: kVK_F13, modifiers: [], key: "F13"))
        log.modifiers = []
        controller.trigger()
        controller.modifiersChanged([])
        #expect(controller.isShowing)
        controller.step(by: -2)
        #expect(controller.selectedIndex == 2)
        controller.commit()
        #expect(log.activated == ["w2"])
    }

    @Test func cancellingSwitchesNowhere() {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        controller.cancel()
        controller.modifiersChanged([])
        #expect(log.activated.isEmpty)
        #expect(!presenter.isShown)
    }

    @Test func nothingToSwitchToAlerts() {
        let controller = makeController(hotKey: optionTab)
        lister.list = []
        controller.trigger()
        #expect(log.alerts == 1)
        #expect(!controller.isShowing)
    }

    @Test func closingAWindowTakesItOutOfTheList() {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        controller.perform(.close)
        #expect(log.acted.map(\.1) == ["w1"])
        #expect(controller.windows.map(\.title) == ["w0", "w2"])
        #expect(controller.selected?.title == "w2")
        #expect(controller.isShowing)
    }

    @Test func aWindowThatDoesntCloseStaysListed() {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        log.appRefuses = true
        controller.perform(.close)
        controller.perform(.quitApp)
        #expect(controller.windows.map(\.title) == ["w0", "w1", "w2"])
        #expect(controller.selected?.title == "w1")
    }

    @Test func theSelectionFollowsItsWindowWhenTheListChanges() {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        controller.step(by: 1)  // w2
        controller.step(by: -2)  // w0
        controller.step(by: 2)  // w2
        lister.list.removeFirst()  // w0 closes on its own; w2 moves up
        controller.perform(.minimize)
        #expect(controller.windows.map(\.title) == ["w1", "w2"])
        #expect(controller.selected?.title == "w2")
        #expect(controller.selected?.state == .minimized)
    }

    @Test func minimizingAndHidingKeepWindowsListed() {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        controller.perform(.minimize)
        #expect(controller.windows[1].state == .minimized)
        controller.step(by: 1)
        controller.perform(.hideApp)
        #expect(controller.windows.map(\.state) == [.onScreen, .minimized, .hidden])
    }

    @Test func quittingAnAppTakesAllItsWindowsAndClosesWhenNothingIsLeft() {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        controller.perform(.quitApp)
        #expect(controller.windows.map(\.title) == ["w2"])
        #expect(controller.selectedIndex == 0)
        controller.perform(.quitApp)
        #expect(!controller.isShowing)
        #expect(!presenter.isShown)
        #expect(log.activated.isEmpty)
    }

    @Test func previewsFromAnEarlierShowingAreDropped() async throws {
        let controller = makeController(hotKey: optionTab)
        controller.trigger()
        controller.cancel()
        controller.trigger()
        // Let both capture tasks start.
        while previews.pending.count < 2 { await Task.yield() }
        let image = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage())
        previews.pending[0](1, image)
        #expect(controller.previews.isEmpty)
        previews.pending[1](1, image)
        #expect(controller.previews[1] != nil)
    }

    @Test func styleAndPeekAreRemembered() {
        let controller = makeController(hotKey: optionTab)
        #expect(controller.style == .grid)
        #expect(controller.peeks)
        #expect(controller.showsPeek)
        controller.style = .stack
        #expect(!controller.showsPeek)  // the stack never peeks
        controller.peeks = false
        let shortcuts = Shortcuts(defaults: defaults.defaults, center: FakeHotKeys())
        let reopened = WindowSwitcherController(defaults: defaults.defaults, shortcuts: shortcuts, presenter: presenter)
        #expect(reopened.style == .stack)
        #expect(!reopened.peeks)
    }

    @Test func turningTheModuleOffClosesTheSwitcher() {
        let hotKeys = FakeHotKeys()
        let state = AppState.testing(defaults: defaults.defaults, hotKeys: hotKeys, system: FakeSystemSettings())
        state.shortcuts.set(optionTab, for: WindowSwitcherController.switchShortcut)
        state.setEnabled(.windowSwitcher, true)
        #expect(hotKeys.hotKeys.contains(optionTab))
        state.setEnabled(.windowSwitcher, false)
        #expect(!hotKeys.hotKeys.contains(optionTab))
    }
}

struct WindowSwitcherModuleTests {
    /// Previews are optional, so turning the module on only asks for what it needs.
    @Test func onlyAccessibilityIsAskedForWhenTurnedOn() {
        #expect(ModuleCatalog.descriptor(.windowSwitcher).permissions == [.accessibility])
    }
}
