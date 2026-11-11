import Testing

@testable import PowerToys

struct DockIconTests {
    @Test func shownWhileTheWindowIsOpen() {
        #expect(DockIcon.isShown(windowOpen: true, hidesOnClose: true, menuBarIconShown: true))
    }

    @Test func hiddenAfterClosingWhenKeptInMenuBar() {
        #expect(!DockIcon.isShown(windowOpen: false, hidesOnClose: true, menuBarIconShown: true))
    }

    @Test func shownAfterClosingWhenTheOptionIsOff() {
        #expect(DockIcon.isShown(windowOpen: false, hidesOnClose: false, menuBarIconShown: true))
    }

    /// Without the menu bar icon there'd be no way back to the window.
    @Test func shownWhenThereIsNoMenuBarIcon() {
        #expect(DockIcon.isShown(windowOpen: false, hidesOnClose: true, menuBarIconShown: false))
    }

    /// ⌘Q goes to the menu bar only with the option on and the icon there to quit from.
    @Test func keepsInMenuBarOnlyWithTheOptionAndIcon() {
        #expect(DockIcon.keepsInMenuBar(hidesOnClose: true, menuBarIconShown: true))
        #expect(!DockIcon.keepsInMenuBar(hidesOnClose: false, menuBarIconShown: true))
        #expect(!DockIcon.keepsInMenuBar(hidesOnClose: true, menuBarIconShown: false))
    }
}
