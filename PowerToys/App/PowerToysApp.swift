import SwiftUI

@main
enum Launcher {
    static func main() {
        // Unit tests run inside the app. Start an empty one for them, hidden from the Dock, so a
        // test run never starts modules, registers shortcuts or checks for updates.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApplication.shared.run()
        } else {
            PowerToysApp.main()
        }
    }
}

struct PowerToysApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @AppStorage(DockIcon.showsMenuBarIconKey) private var showsMenuBarIcon = DockIcon.showsMenuBarIconDefault
    @AppStorage(DockIcon.hidesOnCloseKey) private var hidesDockIconOnClose = false

    var body: some Scene {
        Window(AppInfo.name, id: MainWindow.id) {
            MainView()
                .environment(appDelegate.state)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }
            // The main window is where everything is configured, so ⌘, opens it.
            CommandGroup(replacing: .appSettings) {
                OpenMainWindowButton(title: "Settings…")
                    .keyboardShortcut(",", modifiers: .command)
            }
            // Only the menu's Quit is replaced: logout, relaunch and updates still quit the app.
            CommandGroup(replacing: .appTermination) {
                if DockIcon.keepsInMenuBar(hidesOnClose: hidesDockIconOnClose, menuBarIconShown: showsMenuBarIcon) {
                    Button("Quit to Menu Bar") { MainWindow.closeAll() }
                        .keyboardShortcut("q", modifiers: .command)
                    Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
                        .keyboardShortcut("q", modifiers: [.command, .option])
                } else {
                    Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                }
            }
        }

        MenuBarExtra(isInserted: $showsMenuBarIcon) {
            MenuBarView()
                .environment(appDelegate.state)
        } label: {
            MenuBarIcon.image
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Made here rather than in a view, so requests from Finder's menu that launch the app have
    /// somewhere to go before any window opens.
    let state = AppState()

    /// Closing the window keeps modules running; the app quits only from the menu or ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Lanes keeps other apps' windows in rows, some of them off the edge of the display; they
    /// go back where they were before the app leaves.
    func applicationWillTerminate(_ notification: Notification) {
        state.lanes.stop()
    }

    // Installed before launch finishes, so a request that launched the app isn't missed, and
    // again after, in case SwiftUI installed its own handler in between.
    func applicationWillFinishLaunching(_ notification: Notification) {
        installURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installURLHandler()
        installStatusItemMenu()
        DockIcon.start()
        Updater.shared.start()
    }

    /// MenuBarExtra opens its window on any click and offers no other menu, so a right-click
    /// (or Control-click) on the menu bar icon is caught here and shows Quit instead.
    private func installStatusItemMenu() {
        // Lives as long as the app, so the token isn't kept for removal.
        _ = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                let window = event.window, window.className.contains("StatusBarWindow"),
                let view = window.contentView
            else { return event }
            let menu = NSMenu()
            let quit = menu.addItem(
                withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY : 0), in: view)
            return nil
        }
    }

    /// Replaces SwiftUI's handler, which would open a window for every URL.
    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Runs an action chosen in Finder's menu. Any app or web page can open the app's URLs, so
    /// only those sent by its own bundled extension are acted on.
    @objc private func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text),
            let request = FinderMenuRequest(url: url)
        else { return }
        let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
        let sender = pid > 0 ? ProcessDetails.executablePath(pid) : nil
        guard FinderMenuSender.isOwnExtension(executablePath: sender, appBundle: Bundle.main.bundleURL) else {
            NSLog("Ignored a Finder menu request from \(sender ?? "an unknown sender")")
            return
        }
        state.handleFinderMenu(request)
    }
}

enum MenuBarIcon {
    /// One icon whatever the modules are doing: a changing icon reads as a different app.
    static let symbol = "wrench.and.screwdriver"

    /// Debug builds add a dot in the corner, so they can be told apart from the installed app
    /// in the menu bar, where icons are drawn in one colour.
    static var image: Image {
        #if DEBUG
            Image(nsImage: dottedSymbol)
        #else
            Image(systemName: symbol)
        #endif
    }

    #if DEBUG
        private static let dottedSymbol = dotted(symbol)
    #endif

    /// The symbol with a dot at its lower right, cut out of the symbol so it stays visible.
    static func dotted(_ name: String) -> NSImage {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: AppInfo.name)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))!
        let dot: CGFloat = 6
        let gap: CGFloat = 1.5
        let size = NSSize(width: symbol.size.width + dot / 3, height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            let spot = NSRect(x: size.width - dot, y: 0, width: dot, height: dot)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: spot.insetBy(dx: -gap, dy: -gap)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: spot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

nonisolated enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as! String
}

enum MainWindow {
    static let id = "main"

    /// Closes the app's windows, leaving its modules running from the menu bar. Goes through
    /// the close button's path, so a window can still refuse or tidy up first.
    @MainActor static func closeAll() {
        for window in NSApp.windows where DockIcon.isAppWindow(window) {
            window.performClose(nil)
        }
    }
}

/// With the option on, the app keeps running in the menu bar alone while none of its windows
/// are open, with no Dock icon or app switcher entry.
@MainActor enum DockIcon {
    static let hidesOnCloseKey = "hidesDockIconOnClose"
    static let showsMenuBarIconKey = "showsMenuBarIcon"
    static let showsMenuBarIconDefault = true

    /// Closing the window and ⌘Q leave the app in the menu bar, but only while the menu bar
    /// icon is there to bring the window back or quit from.
    nonisolated static func keepsInMenuBar(hidesOnClose: Bool, menuBarIconShown: Bool) -> Bool {
        hidesOnClose && menuBarIconShown
    }

    nonisolated static func isShown(windowOpen: Bool, hidesOnClose: Bool, menuBarIconShown: Bool) -> Bool {
        windowOpen || !keepsInMenuBar(hidesOnClose: hidesOnClose, menuBarIconShown: menuBarIconShown)
    }

    /// Follows the app's windows opening, closing and minimizing, and both settings changing.
    static func start() {
        let names = [
            NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, UserDefaults.didChangeNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                // Still visible while it closes, so it's left out by hand.
                let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                MainActor.assumeIsolated { update(closing: closing) }
            }
        }
        // After SwiftUI has had a turn to open any window it restores at launch.
        DispatchQueue.main.async { update(closing: nil) }
    }

    private static func update(closing: NSWindow?) {
        let defaults = UserDefaults.standard
        let shown = isShown(
            windowOpen: NSApp.windows.contains { $0 !== closing && isAppWindow($0) },
            hidesOnClose: defaults.bool(forKey: hidesOnCloseKey),
            menuBarIconShown: defaults.object(forKey: showsMenuBarIconKey) as? Bool ?? showsMenuBarIconDefault)
        let policy: NSApplication.ActivationPolicy = shown ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// The main window, the update window and the like, minimized ones included; not the
    /// menu bar panel, pins or overlays, which float above normal windows.
    static func isAppWindow(_ window: NSWindow) -> Bool {
        window.level == .normal && window.canBecomeMain && (window.isVisible || window.isMiniaturized)
    }
}

struct OpenMainWindowButton: View {
    let title: String

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
    }
}
