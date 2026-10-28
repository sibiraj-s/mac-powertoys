import Testing
@testable import PowerToys

struct ModuleCatalogTests {
    @Test func everyModuleIDHasExactlyOneDescriptor() {
        let ids = ModuleCatalog.all.map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(Set(ids) == Set(ModuleID.allCases))
    }

    @Test func tiersMatchTheFeatureMap() {
        let counts = Dictionary(grouping: ModuleCatalog.all, by: \.tier).mapValues(\.count)
        #expect(counts[.mvp] == 8)
        #expect(counts[.utilities] == 7)
        #expect(counts[.pro] == 7)
    }

    @Test func everyCategoryHasModules() {
        for category in ModuleCategory.allCases {
            #expect(!ModuleCatalog.modules(in: category).isEmpty, "\(category.rawValue) is empty")
        }
    }

    @Test func descriptorsHaveCopyAndSymbols() {
        for module in ModuleCatalog.all {
            #expect(!module.name.isEmpty)
            #expect(!module.summary.isEmpty)
            #expect(!module.symbol.isEmpty)
            #expect(!module.replaces.isEmpty)
        }
    }

    @Test(arguments: ModuleID.allCases)
    func lookupReturnsMatchingDescriptor(id: ModuleID) {
        #expect(ModuleCatalog.descriptor(id).id == id)
    }

    @Test func implementedModules() {
        let implemented = Set(ModuleCatalog.all.filter(\.isImplemented).map(\.id))
        #expect(implemented == [.zones, .clipboard, .awake, .systemToggles, .hostsEnv, .portsProcesses, .launchAgents, .colorPicker])
    }
}
