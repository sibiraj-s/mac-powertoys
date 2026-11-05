import AppKit
import Carbon.HIToolbox
import Testing

@testable import PowerToys

struct ScrollSmootherTests {
    private func drain(_ smoother: inout ScrollSmoother) -> (x: Int, y: Int, frames: Int) {
        var x = 0
        var y = 0
        var frames = 0
        while !smoother.isIdle && frames < 1000 {
            let step = smoother.step()
            x += Int(step.x)
            y += Int(step.y)
            frames += 1
        }
        return (x, y, frames)
    }

    @Test func scrollsTheWholeDistanceOverSeveralFrames() {
        var smoother = ScrollSmoother()
        smoother.add(pointsX: 0, pointsY: 30)
        let result = drain(&smoother)
        #expect(result.y == 30)
        #expect(result.x == 0)
        #expect(result.frames > 5)
        #expect(result.frames < 1000)
    }

    @Test func easesOut() {
        var smoother = ScrollSmoother()
        smoother.add(pointsX: 0, pointsY: -40)
        let first = smoother.step().y
        _ = drain(&smoother)
        #expect(first < -1)
        smoother.add(pointsX: 0, pointsY: -40)
        var last: Int32 = 0
        while !smoother.isIdle { last = smoother.step().y }
        #expect(abs(last) < abs(first))
    }

    @Test func notchesInTheSameDirectionAddUp() {
        var smoother = ScrollSmoother()
        smoother.add(pointsX: 10, pointsY: 0)
        var total = Int(smoother.step().x)
        smoother.add(pointsX: 10, pointsY: 0)
        smoother.add(pointsX: 0, pointsY: 0)
        total += drain(&smoother).x
        #expect(total == 20)
    }

    @Test func turningTheWheelBackDropsWhatWasLeft() {
        var smoother = ScrollSmoother()
        smoother.add(pointsX: 0, pointsY: 50)
        _ = smoother.step()
        smoother.add(pointsX: 0, pointsY: -10)
        #expect(smoother.remainingY == -10)
    }

    @Test func aSinglePixelStillMoves() {
        var smoother = ScrollSmoother()
        smoother.add(pointsX: 0, pointsY: 1)
        #expect(drain(&smoother).y == 1)
    }

    @Test func stopClearsEverything() {
        var smoother = ScrollSmoother()
        smoother.add(pointsX: 20, pointsY: 20)
        smoother.stop()
        #expect(smoother.isIdle)
        #expect(smoother.step() == (0, 0))
    }
}

struct ScrollMouseControllerTests {
    @Test func startsWithEverythingOff() {
        let store = TestDefaults()
        let controller = ScrollMouseController(defaults: store.defaults)
        #expect(!controller.reversesMouse)
        #expect(!controller.reversesTrackpad)
        #expect(!controller.smoothsWheel)
        for button in MouseButton.allCases {
            #expect(controller.action(for: button) == .standard)
        }
    }

    @Test func settingsPersist() {
        let store = TestDefaults()
        let controller = ScrollMouseController(defaults: store.defaults)
        controller.reversesMouse = true
        controller.smoothsWheel = true
        let keys = HotKey(keyCode: kVK_UpArrow, modifiers: .control, key: "↑")
        controller.setAction(.back, for: .back)
        controller.setAction(.keys(keys), for: .middle)
        controller.setAction(.keys(nil), for: .forward)

        let reloaded = ScrollMouseController(defaults: store.defaults)
        #expect(reloaded.reversesMouse)
        #expect(!reloaded.reversesTrackpad)
        #expect(reloaded.smoothsWheel)
        #expect(reloaded.action(for: .back) == .back)
        #expect(reloaded.action(for: .middle) == .keys(keys))
        #expect(reloaded.action(for: .forward) == .keys(nil))
    }

    @Test func settingStandardForgetsTheButton() {
        let store = TestDefaults()
        let controller = ScrollMouseController(defaults: store.defaults)
        controller.setAction(.forward, for: .forward)
        controller.setAction(.standard, for: .forward)
        #expect(controller.buttonActions.isEmpty)
    }

    @Test func reversesEachDeviceSeparately() {
        let store = TestDefaults()
        let controller = ScrollMouseController(defaults: store.defaults)
        controller.reversesMouse = true
        #expect(controller.reverses(isContinuous: false))
        #expect(!controller.reverses(isContinuous: true))
        controller.reversesMouse = false
        controller.reversesTrackpad = true
        #expect(!controller.reverses(isContinuous: false))
        #expect(controller.reverses(isContinuous: true))
    }

    @Test func smoothsOnlyUnmodifiedWheelNotches() {
        let store = TestDefaults()
        let controller = ScrollMouseController(defaults: store.defaults)
        #expect(!controller.smooths(isContinuous: false, flags: []))
        controller.smoothsWheel = true
        #expect(controller.smooths(isContinuous: false, flags: []))
        #expect(controller.smooths(isContinuous: false, flags: .maskAlphaShift))
        #expect(!controller.smooths(isContinuous: true, flags: []))
        #expect(!controller.smooths(isContinuous: false, flags: .maskCommand))
        #expect(!controller.smooths(isContinuous: false, flags: .maskAlternate))
    }

    @Test func waitsForAccessibilityBeforeListening() {
        let store = TestDefaults()
        var asked = 0
        let controller = ScrollMouseController(defaults: store.defaults) {
            asked += 1
            return false
        }
        controller.start()
        #expect(controller.isRunning)
        #expect(asked == 1)
        controller.stop()
        #expect(!controller.isRunning)
    }

    @Test func moduleSwitchStartsAndStopsIt() {
        let store = TestDefaults()
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        state.setEnabled(.scrollMouse, true)
        #expect(state.scrollMouse.isRunning)
        state.setEnabled(.scrollMouse, false)
        #expect(!state.scrollMouse.isRunning)
    }
}

struct ButtonActionTests {
    @Test func backAndForwardPressBrackets() {
        #expect(ButtonAction.back.hotKey == HotKey(keyCode: kVK_ANSI_LeftBracket, modifiers: .command, key: "["))
        #expect(ButtonAction.forward.hotKey == HotKey(keyCode: kVK_ANSI_RightBracket, modifiers: .command, key: "]"))
        #expect(ButtonAction.standard.hotKey == nil)
        #expect(ButtonAction.keys(nil).hotKey == nil)
    }

    @Test(arguments: ButtonAction.Kind.allCases)
    func kindRoundTrips(kind: ButtonAction.Kind) {
        #expect(ButtonAction(kind: kind).kind == kind)
    }

    @Test func buttonNumbersMatchCGEvent() {
        #expect(MouseButton.allCases.map(\.rawValue) == [2, 3, 4])
    }

    @Test func eventFlagsCarryModifiers() {
        let hotKey = HotKey(keyCode: kVK_ANSI_K, modifiers: [.command, .shift], key: "K")
        #expect(hotKey.eventFlags == [.maskCommand, .maskShift])
    }

    @Test func arrowKeysCarryFnAndKeypadFlags() {
        let hotKey = HotKey(keyCode: kVK_UpArrow, modifiers: .control, key: "↑")
        #expect(hotKey.eventFlags == [.maskControl, .maskSecondaryFn, .maskNumericPad])
    }

    @Test func functionKeysCarryFn() {
        let hotKey = HotKey(keyCode: kVK_F3, modifiers: [], key: "F3")
        #expect(hotKey.eventFlags == .maskSecondaryFn)
    }
}
