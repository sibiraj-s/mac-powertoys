import Foundation
import Testing

@testable import PowerToys

struct PaneTests {
    @Test(arguments: [Pane.overview, .permissions] + ModuleID.allCases.map(Pane.module))
    func storageValueRoundTrips(pane: Pane) {
        #expect(Pane(storageValue: pane.storageValue) == pane)
    }

    @Test func unknownStorageValueIsRejected() {
        #expect(Pane(storageValue: "module.removedModule") == nil)
        #expect(Pane(storageValue: "") == nil)
    }

    @Test func opensOnOverviewWithNothingSaved() {
        let test = TestDefaults()
        #expect(Pane.initial(defaults: test.defaults) == .overview)
    }

    @Test func reopensLastPaneByDefault() {
        let test = TestDefaults()
        test.defaults.set(Pane.module(.zones).storageValue, forKey: Pane.lastKey)
        #expect(Pane.initial(defaults: test.defaults) == .module(.zones))
    }

    @Test func opensOnOverviewWhenTurnedOff() {
        let test = TestDefaults()
        test.defaults.set(Pane.module(.zones).storageValue, forKey: Pane.lastKey)
        test.defaults.set(false, forKey: Pane.reopensLastKey)
        #expect(Pane.initial(defaults: test.defaults) == .overview)
    }

    @Test func opensOnOverviewWhenSavedModuleIsGone() {
        let test = TestDefaults()
        test.defaults.set("module.removedModule", forKey: Pane.lastKey)
        #expect(Pane.initial(defaults: test.defaults) == .overview)
    }
}
