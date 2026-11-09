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
}
