import Testing

@testable import PowerToys

struct AppStateTests {
    private let store = TestDefaults()

    @Test func firstLaunchEnablesOnlyModulesThatNeedNoPermission() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        #expect(state.enabledModules == [.awake, .portsProcesses, .colorPicker, .displaysAudio, .apps])
    }

    @Test func enabledModulesPersistAcrossLaunches() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        state.setEnabled(.batchRename, true)
        state.setEnabled(.awake, false)
        state.setEnabled(.portsProcesses, false)
        state.setEnabled(.colorPicker, false)
        state.setEnabled(.displaysAudio, false)
        state.setEnabled(.apps, false)

        let relaunched = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        #expect(relaunched.enabledModules == [.batchRename])
        #expect(store.defaults.stringArray(forKey: AppState.enabledModulesKey) == ["batchRename"])
    }

    @Test func storedUnknownModulesAreIgnored() {
        store.defaults.set(["awake", "removedModule"], forKey: AppState.enabledModulesKey)
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        #expect(state.enabledModules == [.awake])
    }

    @Test func turningAwakeOffReleasesTheAssertion() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        state.awake.start(.indefinitely)
        #expect(state.awake.isActive)

        state.setEnabled(.awake, false)
        #expect(!state.awake.isActive)
    }

    @Test func turningLanesOnTurnsZonesOff() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        state.setEnabled(.zones, true)
        #expect(state.zones.isRunning)

        state.setEnabled(.lanes, true)
        #expect(state.isEnabled(.lanes))
        #expect(!state.isEnabled(.zones))
        #expect(!state.zones.isRunning)
        #expect(store.defaults.stringArray(forKey: AppState.enabledModulesKey)?.contains("zones") == false)
        state.setEnabled(.lanes, false)
    }

    @Test func turningZonesOnTurnsLanesOff() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        state.setEnabled(.lanes, true)

        state.setEnabled(.zones, true)
        #expect(state.isEnabled(.zones))
        #expect(!state.isEnabled(.lanes))
        #expect(!state.lanes.isRunning)
        state.setEnabled(.zones, false)
    }

    @Test func turningOneOffLeavesTheOtherOff() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        state.setEnabled(.zones, true)
        state.setEnabled(.lanes, true)
        state.setEnabled(.lanes, false)
        #expect(!state.isEnabled(.zones))
        #expect(!state.zones.isRunning)
        #expect(!state.isEnabled(.lanes))
    }

    @Test func bothStoredOnKeepsOnlyLanes() {
        store.defaults.set(["lanes", "zones"], forKey: AppState.enabledModulesKey)
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        #expect(state.enabledModules == [.lanes])
        #expect(!state.zones.isRunning)
        #expect(store.defaults.stringArray(forKey: AppState.enabledModulesKey) == ["lanes"])
        state.setEnabled(.lanes, false)
    }

    @Test func onlyZonesAndLanesAreRivals() {
        #expect(AppState.rival(of: .zones) == .lanes)
        #expect(AppState.rival(of: .lanes) == .zones)
        #expect(ModuleID.allCases.filter { AppState.rival(of: $0) != nil } == [.zones, .lanes])
    }

    @Test func bindingReadsAndWritesEnabledState() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        let binding = state.binding(for: .batchRename)
        #expect(!binding.wrappedValue)

        binding.wrappedValue = true
        #expect(state.isEnabled(.batchRename))
        #expect(state.enabledCount == 6)
    }
}
