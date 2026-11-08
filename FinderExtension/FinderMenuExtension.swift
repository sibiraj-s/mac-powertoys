import AppKit
import FinderSync
import UniformTypeIdentifiers

/// Adds Finder Extras to Finder's right-click menu. The extension is sandboxed, so it does no
/// work itself: it hands the action to PowerToys, which launches if it isn't running.
nonisolated final class FinderMenuExtension: FIFinderSync {
    /// Added to an item's tag when the menu is for empty space in a folder. Finder keeps only the
    /// tag of the items it copies into its menu, and sends their actions to this extension.
    private static let folderTag = 100

    override init() {
        super.init()
        // Every folder, so the menu shows everywhere, including other disks.
        FIFinderSyncController.default().directoryURLs = [URL(filePath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Menus are made on the main thread, wherever Finder asks from. The menu only passes
        // back to Finder, which shows it on the main thread too.
        nonisolated(unsafe) var menu: NSMenu?
        let make = { MainActor.assumeIsolated { menu = Self.makeMenu(for: menuKind) } }
        if Thread.isMainThread { make() } else { DispatchQueue.main.sync(execute: make) }
        return menu
    }

    @MainActor
    private static func makeMenu(for menuKind: FIMenuKind) -> NSMenu? {
        guard isModuleOn else { return nil }
        let actions: [FinderAction]
        switch menuKind {
        case .contextualMenuForItems:
            let hasImages = selection.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            actions = [.copyPath, .openInTerminal] + (hasImages ? [.resizeImages] : [])
        case .contextualMenuForContainer:
            actions = [.newFile, .copyPath, .openInTerminal]
        default:
            return nil
        }
        let isForFolder = menuKind == .contextualMenuForContainer

        let submenu = NSMenu(title: "PowerToys")
        for action in actions {
            let item = NSMenuItem(title: action.menuTitle, action: #selector(run(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.tag = (FinderAction.allCases.firstIndex(of: action) ?? 0) + (isForFolder ? folderTag : 0)
            submenu.addItem(item)
        }
        let menu = NSMenu(title: "")
        let parent = NSMenuItem(title: "PowerToys", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    @MainActor @objc private func run(_ sender: NSMenuItem) {
        let isForFolder = sender.tag >= Self.folderTag
        let index = sender.tag % Self.folderTag
        guard FinderAction.allCases.indices.contains(index), let folder = FIFinderSyncController.default().targetedURL() else {
            return
        }
        // On empty space in a folder, the action is about the folder, not what's selected in it.
        let request = FinderMenuRequest(
            action: FinderAction.allCases[index], selection: isForFolder ? [] : Self.selection, folder: folder)
        // PowerToys accepts requests only from this extension, which it checks by who sent
        // them, so it's started first rather than launched by the request itself. Both go to
        // the copy holding this extension, not another copy, such as a build from Xcode.
        let hostApp = Self.hostApp
        let isRunning = NSRunningApplication.runningApplications(withBundleIdentifier: FinderMenuRequest.appBundleID)
            .contains { $0.bundleURL?.standardizedFileURL == hostApp.standardizedFileURL }
        guard !isRunning else {
            Self.send(request, to: hostApp)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: hostApp, configuration: configuration) { app, _ in
            guard app != nil else { return }
            DispatchQueue.main.async { Self.send(request, to: hostApp) }
        }
    }

    @MainActor
    private static func send(_ request: FinderMenuRequest, to app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([request.url], withApplicationAt: app, configuration: configuration)
    }

    /// PowerToys.app, from PowerToys.app/Contents/PlugIns/FinderExtension.appex.
    private static var hostApp: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var selection: [URL] {
        FIFinderSyncController.default().selectedItemURLs() ?? []
    }

    /// Whether Finder Extras is on in PowerToys, read from its preferences, which the extension
    /// may read but not change.
    private static var isModuleOn: Bool {
        let enabled = UserDefaults(suiteName: FinderMenuRequest.appBundleID)?
            .stringArray(forKey: FinderMenuRequest.enabledModulesKey)
        return enabled?.contains(FinderMenuRequest.moduleID) ?? false
    }
}
