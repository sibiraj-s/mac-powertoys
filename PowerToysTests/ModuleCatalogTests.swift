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
        #expect(counts[.mvp] == 7)
        #expect(counts[.utilities] == 9)
        #expect(counts[.pro] == 5)
    }

    @Test func everyCategoryHasModules() {
        for category in ModuleCategory.allCases {
            #expect(!ModuleCatalog.modules(in: category).isEmpty, "\(category.rawValue) is empty")
        }
    }

    @Test func modulesInCategoryAreSortedByName() {
        for category in ModuleCategory.allCases {
            let names = ModuleCatalog.modules(in: category).map(\.name)
            #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
        #expect(
            ModuleCatalog.modules(in: .windowsInput).map(\.name) == ["Keys", "Pin & Crop", "Scroll & Mouse", "Window Switcher", "Zones"])
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
        #expect(
            implemented == [
                .zones, .clipboard, .awake, .systemToggles, .hostsEnv, .portsProcesses, .launchAgents, .colorPicker, .textExtractor,
                .defaultsBrowser, .scrollMouse, .cleaner, .apps, .pinCrop, .keys, .windowSwitcher, .displaysAudio, .batchRename,
                .fileLocksmith, .finderExtras, .screenRuler,
            ])
    }
}
