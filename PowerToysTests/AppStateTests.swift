import Testing
@testable import PowerToys

struct AppStateTests {
    private let store = TestDefaults()

    @Test func firstLaunchEnablesOnlyModulesThatNeedNoPermission() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        #expect(state.enabledModules == [.awake, .portsProcesses])
    }

    @Test func enabledModulesPersistAcrossLaunches() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        state.setEnabled(.batchRename, true)
        state.setEnabled(.awake, false)
        state.setEnabled(.portsProcesses, false)

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

    @Test func bindingReadsAndWritesEnabledState() {
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        let binding = state.binding(for: .batchRename)
        #expect(!binding.wrappedValue)

        binding.wrappedValue = true
        #expect(state.isEnabled(.batchRename))
        #expect(state.enabledCount == 3)
    }
}
