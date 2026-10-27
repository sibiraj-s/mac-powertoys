import Testing
@testable import PowerToys

struct AppStateTests {
    private let store = TestDefaults()

    @Test func firstLaunchEnablesOnlyModulesThatNeedNoPermission() {
        let state = AppState(defaults: store.defaults, clipboardStore: nil)
        #expect(state.enabledModules == [.awake])
    }

    @Test func enabledModulesPersistAcrossLaunches() {
        let state = AppState(defaults: store.defaults, clipboardStore: nil)
        state.setEnabled(.batchRename, true)
        state.setEnabled(.awake, false)

        let relaunched = AppState(defaults: store.defaults, clipboardStore: nil)
        #expect(relaunched.enabledModules == [.batchRename])
        #expect(store.defaults.stringArray(forKey: AppState.enabledModulesKey) == ["batchRename"])
    }

    @Test func storedUnknownModulesAreIgnored() {
        store.defaults.set(["awake", "removedModule"], forKey: AppState.enabledModulesKey)
        let state = AppState(defaults: store.defaults, clipboardStore: nil)
        #expect(state.enabledModules == [.awake])
    }

    @Test func turningAwakeOffReleasesTheAssertion() {
        let state = AppState(defaults: store.defaults, clipboardStore: nil)
        state.awake.start(.indefinitely)
        #expect(state.awake.isActive)

        state.setEnabled(.awake, false)
        #expect(!state.awake.isActive)
    }

    @Test func bindingReadsAndWritesEnabledState() {
        let state = AppState(defaults: store.defaults, clipboardStore: nil)
        let binding = state.binding(for: .portsProcesses)
        #expect(!binding.wrappedValue)

        binding.wrappedValue = true
        #expect(state.isEnabled(.portsProcesses))
        #expect(state.enabledCount == 2)
    }
}
